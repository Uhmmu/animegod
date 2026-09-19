import SwiftUI

/// The one surface every overlay in the player uses (badges, OSD, panels,
/// loading, errors, diagnostics): translucent dark material, a darkening
/// layer so white text holds over bright frames, and a hairline edge.
struct PlayerSurface<S: Shape>: View {
    let shape: S

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.45))
            shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        }
    }
}

extension View {
    func playerSurface(cornerRadius: CGFloat = PlayerChrome.panelRadius) -> some View {
        background(PlayerSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func playerCapsuleSurface() -> some View {
        background(PlayerSurface(shape: Capsule()))
    }
}

/// Short-lived feedback for keyboard and scroll actions ("+10 s", "Volume
/// 80%", "Danmaku off"). One slot: a new message replaces the old one.
/// Its own object, so a message appearing doesn't depend on the player's
/// re-render and doesn't trigger one.
@MainActor
final class PlayerOSD: ObservableObject {
    struct Message: Equatable {
        let symbol: String
        let text: String
        /// 0…1 draws a level bar (volume).
        var level: Double?
        /// Changes on every `show`, so repeating the same text still counts
        /// as new (and restarts the fade timer).
        let id = UUID()
    }

    @Published private(set) var message: Message?
    private var hideTask: Task<Void, Never>?

    func show(_ symbol: String, _ text: String, level: Double? = nil) {
        message = Message(symbol: symbol, text: text, level: level)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

struct PlayerOSDView: View {
    @ObservedObject var osd: PlayerOSD

    var body: some View {
        ZStack {
            if let message = osd.message {
                HStack(spacing: 10) {
                    Image(systemName: message.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolVariant(.fill)
                        .frame(width: 22)
                    Text(message.text)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    if let level = message.level {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 90, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: 90 * min(max(level, 0), 1), height: 4)
                            }
                    }
                }
                .foregroundStyle(PlayerChrome.foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .playerCapsuleSurface()
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .id(message.text + message.symbol)
            }
        }
        .animation(.easeOut(duration: 0.16), value: osd.message)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 72)
        .allowsHitTesting(false)
    }
}

/// The large icon that blooms in the middle of the picture and fades when
/// playback is paused or resumed from the keyboard or the bar.
struct PlayPauseFlash: View {
    /// Incremented for every toggle; each change runs the animation once.
    let trigger: Int
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.fill" : "play.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(PlayerChrome.foreground)
            .frame(width: 84, height: 84)
            .background(PlayerSurface(shape: Circle()))
            .phaseAnimator([FlashPhase.hidden, .shown, .gone], trigger: trigger) { content, phase in
                content
                    .scaleEffect(phase.scale)
                    .opacity(phase.opacity)
            } animation: { phase in
                switch phase {
                case .hidden: nil
                case .shown: .easeOut(duration: 0.12)
                case .gone: .easeIn(duration: 0.45)
                }
            }
            .allowsHitTesting(false)
    }

    private enum FlashPhase {
        case hidden, shown, gone

        var scale: CGFloat {
            switch self {
            case .hidden: 0.8
            case .shown: 1
            case .gone: 1.35
            }
        }

        var opacity: Double { self == .shown ? 1 : 0 }
    }
}
