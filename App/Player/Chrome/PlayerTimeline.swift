import SwiftUI

/// The player's scrubber: a thin track that thickens under the pointer, with
/// the buffered read-ahead, chapter boundaries, a hover time bubble and
/// drag scrubbing.
///
/// Dragging sends keyframe seeks at most every 100 ms and one exact seek on
/// release. Every seek goes through the `seek` closure (`PlayerState.seek`),
/// which re-anchors danmaku. While dragging, and briefly after release, the
/// knob follows the pointer rather than the reported position, so it doesn't
/// snap back while mpv catches up.
struct PlayerTimeline: View {
    let position: Double
    let duration: Double
    let bufferedEnd: Double?
    let chapters: [MediaChapter]
    let seek: (_ time: Double, _ exact: Bool) -> Void

    /// AG_SMOKE_TIMELINE_HOVER=<points> pins the hover state for smoke
    /// captures, which can't move a pointer.
    @State private var hoverX: CGFloat? = ProcessInfo.processInfo.environment["AG_SMOKE_TIMELINE_HOVER"].flatMap(Double.init).map { CGFloat($0) }
    @State private var dragTime: Double?
    @State private var lastDragSeek = Date.distantPast
    /// Where the last release seeked to, until playback reports being there.
    @State private var settleTarget: (time: Double, until: Date)?

    private static let hitHeight: CGFloat = 22
    private static let knobSize: CGFloat = 13

    private var isActive: Bool { hoverX != nil || dragTime != nil }

    private var displayedPosition: Double {
        if let dragTime { return dragTime }
        if let settleTarget, Date() < settleTarget.until, abs(position - settleTarget.time) > 1.5 {
            return settleTarget.time
        }
        return position
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let trackHeight: CGFloat = isActive ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                if let bufferedEnd, duration > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: width * fraction(bufferedEnd))
                }
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(trackHeight, width * fraction(displayedPosition)))
                chapterGaps(width: width, height: trackHeight)
            }
            .frame(height: trackHeight)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .offset(x: width * fraction(displayedPosition) - Self.knobSize / 2)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if let bubbleX = dragTime.map({ width * fraction($0) }) ?? hoverX {
                    // A point anchor at the pointer with the bubble hanging
                    // above it, kept clear of the track's ends.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .overlay(alignment: .bottom) { bubble(at: bubbleX, width: width) }
                        .offset(x: min(max(bubbleX, 44), max(width - 44, 44)), y: -2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): hoverX = min(max(location.x, 0), width)
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = time(at: value.location.x, width: width)
                        dragTime = time
                        hoverX = min(max(value.location.x, 0), width)
                        if Date().timeIntervalSince(lastDragSeek) >= 0.1 {
                            lastDragSeek = Date()
                            seek(time, false)
                        }
                    }
                    .onEnded { value in
                        let time = time(at: value.location.x, width: width)
                        dragTime = nil
                        lastDragSeek = .distantPast
                        settleTarget = (time, Date().addingTimeInterval(1.5))
                        seek(time, true)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isActive)
        }
        .frame(height: Self.hitHeight)
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
        .accessibilityValue(Self.format(displayedPosition))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(position + 10, duration), true)
            case .decrement: seek(max(position - 10, 0), true)
            @unknown default: break
            }
        }
    }

    private func fraction(_ time: Double) -> CGFloat {
        guard duration > 0, time.isFinite else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1))
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    /// Short cuts through the track at each chapter start, so chapters read
    /// as segments.
    private func chapterGaps(width: CGFloat, height: CGFloat) -> some View {
        ForEach(chapters.filter { $0.startTime > 0.5 && $0.startTime < duration - 0.5 }) { chapter in
            Rectangle()
                .fill(Color.black.opacity(0.75))
                .frame(width: 2, height: height)
                .offset(x: width * fraction(chapter.startTime) - 1)
        }
    }

    private func bubble(at x: CGFloat, width: CGFloat) -> some View {
        let time = time(at: x, width: width)
        let chapter = chapters.last { $0.startTime <= time }
        return VStack(spacing: 1) {
            Text(Self.format(time))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            if let chapter, !chapter.title.isEmpty {
                Text(chapter.title)
                    .font(.system(size: 11))
                    .foregroundStyle(PlayerChrome.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(PlayerChrome.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
        .allowsHitTesting(false)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
