import AnimeGodCore
import SwiftUI

/// The viewer's own ordering — not a provider's.
struct RankingsScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var works: [LinkRankedWork] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(works) { work in
                HStack(spacing: 12) {
                    if let ranking = work.ranking {
                        Text(verbatim: "#\(ranking)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .frame(width: 42, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else {
                        Spacer().frame(width: 42)
                    }
                    PosterView(animeID: work.animeID, cornerRadius: 6).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(work.displayTitle).font(.subheadline).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(work.status.displayName)
                            if let score = work.score {
                                Label(String(format: "%.1f", score), systemImage: "star.fill")
                                    .foregroundStyle(.orange)
                            }
                            if work.isFavorite {
                                Image(systemName: "heart.fill").foregroundStyle(.pink)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }

            if loaded && works.isEmpty {
                ContentUnavailableView(
                    "Nothing Ranked",
                    systemImage: "trophy",
                    description: Text("Scores, ranks and favourites you set on your Mac show up here.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Rankings")
        .task {
            works = await model.rankings() ?? []
            loaded = true
        }
        .refreshable { works = await model.rankings() ?? works }
    }
}
