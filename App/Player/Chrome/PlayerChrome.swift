import SwiftUI

/// Shared look of everything drawn over the video. The player window is
/// always dark (see `AnimeGodApp`), so these are fixed light-on-dark values
/// rather than semantic colors.
enum PlayerChrome {
    static let symbolSize: CGFloat = 18
    static let hitSize: CGFloat = 36
    static let cornerRadius: CGFloat = 8
    /// Text in the bar (time, speed) matches the symbols' visual weight.
    static let labelFont = Font.system(size: 14, weight: .semibold).monospacedDigit()
    static let panelRadius: CGFloat = 12

    static let foreground = Color.white
    static let secondary = Color.white.opacity(0.7)
    static let hoverFill = Color.white.opacity(0.14)
    static let pressedFill = Color.white.opacity(0.24)
    static let activeFill = Color.white.opacity(0.2)

    /// Behind the bottom controls and the top header: dark enough to keep
    /// white glyphs readable over a white frame, clear toward the picture.
    static func scrim(from edge: VerticalEdge) -> LinearGradient {
        let colors: [Color] = [.black.opacity(0.72), .black.opacity(0.35), .clear]
        return LinearGradient(
            colors: edge == .bottom ? colors.reversed() : colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Flat icon button for the player bar: no bezel, a rounded highlight on
/// hover, a slight press-in. Also used for menu labels via
/// `PlayerMenuStyle`, so every control in the bar looks the same.
struct PlayerIconButtonStyle: ButtonStyle {
    var symbolSize: CGFloat = PlayerChrome.symbolSize
    var hitSize: CGFloat = PlayerChrome.hitSize
    /// Draws the pressed fill permanently, for toggles that are on.
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        PlayerIconButtonBody(configuration: configuration, symbolSize: symbolSize, hitSize: hitSize, isActive: isActive)
    }
}

private struct PlayerIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let symbolSize: CGFloat
    let hitSize: CGFloat
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: symbolSize, weight: .semibold))
            // One style for every glyph: filled where a fill exists, single
            // color, so the bar doesn't mix outline and solid icons.
            .symbolVariant(.fill)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(PlayerChrome.foreground)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: hitSize, minHeight: hitSize)
            .background(
                RoundedRectangle(cornerRadius: PlayerChrome.cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var fill: Color {
        if configuration.isPressed { return PlayerChrome.pressedFill }
        if isActive { return PlayerChrome.activeFill }
        if isHovering && isEnabled { return PlayerChrome.hoverFill }
        return .clear
    }
}

/// Menus in the bar render as plain icon buttons: no bezel, no disclosure
/// arrow. A click opens the menu.
struct PlayerMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.button)
            .buttonStyle(PlayerIconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// Speaker button that mutes and restores, with the level slider sliding
/// out while the pointer is over it. Its hover state is its own, so the
/// player's frequent re-renders don't collapse it.
struct PlayerVolumeControl: View {
    let volume: Double
    let setVolume: (Double) -> Void
    @State private var isHovering = false
    @State private var volumeBeforeMute: Double = 100

    var body: some View {
        HStack(spacing: 2) {
            Button {
                if volume > 0 {
                    volumeBeforeMute = volume
                    setVolume(0)
                } else {
                    setVolume(max(volumeBeforeMute, 10))
                }
            } label: {
                Image(systemName: symbol)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 26, alignment: .leading)
            }
            .buttonStyle(PlayerIconButtonStyle())
            .help(volume > 0 ? "Mute" : "Unmute")

            if isHovering {
                Slider(value: Binding(get: { volume }, set: { setVolume($0) }), in: 0...130)
                    .controlSize(.small)
                    .frame(width: 84)
                    .padding(.trailing, 6)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .help("Volume \(Int(volume.rounded()))%")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
    }

    private var symbol: String {
        switch volume {
        case ..<0.5: "speaker.slash"
        case ..<34: "speaker.wave.1"
        case ..<67: "speaker.wave.2"
        default: "speaker.wave.3"
        }
    }
}
