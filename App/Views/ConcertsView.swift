import AnimeGodCore
import SwiftUI

/// The concert section: the live discs in the library, and nothing else.
///
/// Its own section and deliberately not on the home screen. A concert is not
/// something anyone is partway through a season of, and mixed into a grid of
/// anime it is noise in both directions — the grid stops being "what am I
/// watching" and the concert loses the one thing worth saying about it, which is
/// what was played.
struct ConcertsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var section: ConcertCoordinator
    @Binding var navigationPath: NavigationPath

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            content
        }
        .navigationTitle("Concerts")
        .task { await section.reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if section.isIdentifying {
                ProgressView().controlSize(.small)
                Text(section.progress ?? String(localized: "Looking discs up…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("\(section.concerts.count) concerts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !section.unidentifiedDiscs.isEmpty {
                    Text("· \(section.unidentifiedDiscs.count) discs not identified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Identify Discs") {
                Task { await section.identifyAll() }
            }
            .disabled(section.isIdentifying)
            .help("Looks every disc in the library up by the catalogue number in its folder name, and moves the live ones into this section.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if section.concerts.isEmpty {
            empty
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 18)], spacing: 22) {
                    ForEach(section.concerts) { concert in
                        Button {
                            navigationPath.append(ConcertRoute(animeID: concert.id))
                        } label: {
                            ConcertCard(concert: concert)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Look This Disc Up Again") {
                                Task { await section.identify(animeID: concert.id) }
                            }
                            Button("Not a Concert") {
                                Task { await section.removeFromConcerts(animeID: concert.id) }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.mic")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("No concerts yet")
                .font(.title3.weight(.semibold))
            // The two things that actually stop a disc being found, in the
            // order they bite.
            Text("A live Blu-ray lands here once it has been looked up. Discs are matched by the catalogue number in the folder name — ANZX-10294, BRMM-10716 — so a folder without one has to be matched by hand.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !section.hasDiscogsKey {
                Text("Add a Discogs API key in Settings to look covers and catalogue numbers up.")
                    .font(.callout)
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if !section.unidentifiedDiscs.isEmpty {
                Button("Identify \(section.unidentifiedDiscs.count) Discs") {
                    Task { await section.identifyAll() }
                }
                .disabled(section.isIdentifying)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where a concert's page is reached from.
struct ConcertRoute: Hashable {
    let animeID: UUID
}

private struct ConcertCard: View {
    let concert: LibraryConcert

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Square rather than a poster's 2:3: a concert's artwork is a disc
            // jacket or a stage photo, and cropping one to a film poster's
            // shape cuts the title off it.
            //
            // The square comes from an empty `Color` carrying the ratio, with
            // the artwork as an overlay. `PosterView` has no intrinsic size of
            // its own, so putting `.aspectRatio` on it directly lets it grow to
            // whatever the image wants — which is what made every card a
            // full-height cover with the titles overlapping each other.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PosterView(urls: concert.release?.coverImageURLs ?? [], height: 180)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(concert.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            // What a concert card can say that an episode count cannot: who
            // played, where, and how much of it there is.
            if let artist = concert.release?.artistNames.first {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                if concert.songCount > 0 {
                    Text("\(concert.songCount) songs")
                }
                if concert.discCount > 1 {
                    Text("· \(concert.discCount) discs")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
