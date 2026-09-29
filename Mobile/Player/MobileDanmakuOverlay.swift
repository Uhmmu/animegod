import AnimeGodCore
import SwiftUI

/// Puts the danmaku canvas over the video.
///
/// Danmaku is an enhancement and nothing else: a pool that never arrives shows
/// as a quiet line in the controls, never as a playback failure. Nothing here
/// can reach the player.
struct MobileDanmakuOverlay: UIViewRepresentable {
    let comments: [DanmakuComment]
    let isVisible: Bool
    var settings: DanmakuDisplaySettings = .default
    /// Handed back so the player state can anchor the clock on every sample.
    var onReady: (MobileDanmakuCanvas) -> Void

    func makeUIView(context: Context) -> MobileDanmakuCanvas {
        let canvas = MobileDanmakuCanvas(frame: .zero)
        canvas.apply(settings: settings)
        canvas.setVisible(isVisible)
        canvas.setComments(comments)
        DispatchQueue.main.async { onReady(canvas) }
        return canvas
    }

    func updateUIView(_ canvas: MobileDanmakuCanvas, context: Context) {
        canvas.apply(settings: settings)
        canvas.setVisible(isVisible)
        if context.coordinator.loadedCount != comments.count {
            context.coordinator.loadedCount = comments.count
            canvas.setComments(comments)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Reloading the engine is expensive and SwiftUI calls `updateUIView`
        /// on every unrelated state change, so the pool is only handed over
        /// when it has actually changed.
        var loadedCount = -1
    }
}
