import SwiftUI

/// The control-bar panels. They replace `Menu`s: an `NSMenu` can't be
/// animated or styled, and it closed whenever the player re-rendered. A
/// panel is ordinary SwiftUI drawn above the video, so it can grow out of
/// its button like a speech bubble and stays open through re-renders.
enum PlayerPanel: Hashable {
    case version
    case speed
    case audio
    case danmaku
    case subtitles

    var width: CGFloat {
        switch self {
        case .speed: 150
        case .version: 260
        case .audio: 280
        case .danmaku: 300
        case .subtitles: 330
        }
    }
}

/// Each panel button publishes its frame so the open panel can sit above
/// it with its tail pointing at it.
struct PlayerPanelAnchorKey: PreferenceKey {
    static let defaultValue: [PlayerPanel: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PlayerPanel: Anchor<CGRect>], nextValue: () -> [PlayerPanel: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A control-bar button that opens `panel`, shown pressed while it is open.
struct PlayerPanelButton<Label: View>: View {
    let panel: PlayerPanel
    let openPanel: PlayerPanel?
    var symbolSize: CGFloat = PlayerChrome.symbolSize
    let toggle: (PlayerPanel) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { toggle(panel) } label: { label() }
            .buttonStyle(PlayerIconButtonStyle(symbolSize: symbolSize, isActive: openPanel == panel))
            .anchorPreference(key: PlayerPanelAnchorKey.self, value: .bounds) { [panel: $0] }
    }
}

/// Rounded body with a small tail at the bottom, pointing down at the
/// button that opened it.
struct PlayerBubbleShape: Shape {
    var tailX: CGFloat
    static let tailHeight: CGFloat = 9
    private static let tailHalfWidth: CGFloat = 10
    private static let radius: CGFloat = PlayerChrome.panelRadius

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - Self.tailHeight)
        var path = Path(roundedRect: body, cornerRadius: Self.radius, style: .continuous)
        let inset = Self.radius + Self.tailHalfWidth
        let x = min(max(tailX, inset), max(rect.width - inset, inset))
        path.move(to: CGPoint(x: x - Self.tailHalfWidth, y: body.maxY - 0.5))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x + Self.tailHalfWidth, y: body.maxY - 0.5))
        path.closeSubpath()
        return path
    }
}

/// The bubble around a panel's content. `isShown` drives the grow-up
/// animation from the tail, so the bubble appears out of its button.
struct PlayerBubble<Content: View>: View {
    let width: CGFloat
    let tailX: CGFloat
    let isShown: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        // NSScrollView paints its own background over the bubble otherwise.
        .scrollContentBackground(.hidden)
        .frame(width: width)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, PlayerBubbleShape.tailHeight)
        .background {
            PlayerSurface(shape: PlayerBubbleShape(tailX: tailX))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        }
        .foregroundStyle(PlayerChrome.foreground)
        .scaleEffect(isShown ? 1 : 0.3, anchor: UnitPoint(x: min(max(tailX / width, 0), 1), y: 1))
        .opacity(isShown ? 1 : 0)
    }
}

// MARK: - Rows

struct PlayerPanelSection: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PlayerChrome.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlayerPanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
    }
}

/// Explanatory or status text inside a panel.
struct PlayerPanelNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(PlayerChrome.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A selectable row with a checkmark column, or an action row with an icon.
struct PlayerPanelRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var isSelected = false
    var isDestructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : (systemImage ?? "checkmark"))
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 14)
                    .opacity(isSelected || systemImage != nil ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(PlayerChrome.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDestructive ? Color.red : PlayerChrome.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering && isEnabled ? PlayerChrome.hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
    }
}

struct PlayerPanelToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

/// "Subtitle delay   −  +0.5s  +  ⟲"
struct PlayerPanelStepperRow: View {
    let title: String
    let value: Double
    let step: Double
    let change: (Double) -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 6)
            stepButton("minus") { change(-step) }
            Text(String(format: "%+.1fs", value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(minWidth: 44)
            stepButton("plus") { change(step) }
            stepButton("arrow.counterclockwise", action: reset)
                .disabled(value == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(PlayerIconButtonStyle(symbolSize: 11, hitSize: 24))
    }
}
