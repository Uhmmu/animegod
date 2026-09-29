import SwiftUI

/// A poster with a stable aspect ratio and a placeholder that does not jump.
struct PosterView: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        default:
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    Image(systemName: "film.stack")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

/// Thin bar under a card: how far through the work you are.
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
