import SwiftUI

/// The mark in the corner of a poster that says this work is followed.
///
/// One small shape carries the whole state of a subscription, which is why it
/// is a rectangle rather than a ring: a rectangle can be outlined, filled
/// round its edge, or filled solid, and those three states read at a glance
/// from across the room.
///
/// - `following`: a blue outline. Nothing is happening; new episodes will be
///   fetched when they appear.
/// - `downloading`: the outline gains an inner border that fills clockwise as
///   the new episode arrives.
/// - `ready`: solid blue. A new episode has landed and has not been looked at.
enum SubscriptionBadgeState: Equatable {
    case following
    case downloading(Double)
    case ready
}

struct SubscriptionBadge: View {
    let state: SubscriptionBadgeState
    /// The whole badge scales from this, so the same shape works on a poster
    /// corner and beside a heading.
    var height: CGFloat = 18

    private var isFilled: Bool { state == .ready }
    private var progress: Double? {
        if case let .downloading(value) = state { return value }
        return nil
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: height * 0.22, style: .continuous) }
    private var lineWidth: CGFloat { max(1.5, height * 0.1) }

    var body: some View {
        ZStack {
            shape
                .fill(isFilled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.45)))
            shape
                .strokeBorder(Color.accentColor, lineWidth: lineWidth)
            if let progress {
                // The inner ring: an inset rounded rectangle whose border
                // fills as the episode arrives, so "downloading" is visibly
                // the outline plus something growing inside it.
                shape
                    .inset(by: lineWidth * 1.8)
                    .trim(from: 0, to: max(0.02, min(progress, 1)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .animation(.easeInOut(duration: 0.4), value: progress)
            }
            Text(Self.label)
                .font(.system(size: height * 0.55, weight: .bold))
                .foregroundStyle(isFilled ? Color.white : Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, height * 0.22)
        }
        .frame(height: height)
        .fixedSize()
        .accessibilityLabel(accessibilityText)
        .help(helpText)
    }

    /// Two characters in Chinese and Japanese, three letters in English: the
    /// badge has room for a word, not a sentence.
    private static var label: String { String(localized: "SUB") }

    private var accessibilityText: String {
        switch state {
        case .following: String(localized: "Subscribed")
        case .downloading(let value): String(localized: "Subscribed, new episode \(Int(value * 100)) percent downloaded")
        case .ready: String(localized: "Subscribed, a new episode is ready")
        }
    }

    private var helpText: String {
        switch state {
        case .following: String(localized: "Followed — new episodes download on their own")
        case .downloading: String(localized: "A new episode is downloading now")
        case .ready: String(localized: "A new episode has arrived")
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        SubscriptionBadge(state: .following)
        SubscriptionBadge(state: .downloading(0.4))
        SubscriptionBadge(state: .ready)
        SubscriptionBadge(state: .downloading(0.8), height: 30)
    }
    .padding()
}
