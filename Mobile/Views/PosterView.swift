import SwiftUI

/// A poster with a stable aspect ratio and a placeholder that does not jump.
///
/// Fetched through the Mac rather than from the provider's CDN: one less thing
/// to be slow or blocked, it reuses artwork the Mac already has, and it keeps
/// working on a network where bgm.tv does not resolve.
struct PosterView: View {
    @EnvironmentObject private var model: MobileModel
    let animeID: UUID
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if didLoad {
                    Image(systemName: "film.stack").font(.title2).foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .task(id: animeID) {
                guard !didLoad || image == nil else { return }
                let data = await model.posterData(for: animeID)
                image = data.flatMap(UIImage.init(data:))
                didLoad = true
            }
    }
}

/// Thin bar: how far through something you are.
struct ProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 3)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
