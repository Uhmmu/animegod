import AnimeGodCore
import SwiftUI

struct SongRoute: Hashable {
    let songID: String
}

struct SongsView: View {
    @ObservedObject var section: ConcertCoordinator
    @Binding var navigationPath: NavigationPath
    @State private var search = ""

    private var songs: [LibraryConcertSong] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return section.songs }
        return section.songs.filter {
            $0.title.localizedStandardContains(query)
                || $0.artists.contains { $0.localizedStandardContains(query) }
                || $0.appearances.contains { $0.concert.displayTitle.localizedStandardContains(query) }
                || $0.appearances.contains { $0.track.title.localizedStandardContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(section.songs.count) songs")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if section.songs.isEmpty {
                ContentUnavailableView(
                    "No songs yet", systemImage: "music.note.list",
                    description: Text("Songs from your concert setlists appear here. Identify a BD or paste its song timeline on the concert page.")
                )
            } else if songs.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(songs) { song in
                    Button {
                        navigationPath.append(SongRoute(songID: song.id))
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "music.note")
                                .font(.title3).foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title).font(.headline)
                                if !song.artists.isEmpty {
                                    Text(song.artists.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(song.discCount) BDs")
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Songs")
        .searchable(text: $search, prompt: "Search songs, artists or BDs")
        .task { await section.reload() }
    }
}

struct SongDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var section: ConcertCoordinator
    let songID: String

    private var song: LibraryConcertSong? { section.songs.first { $0.id == songID } }

    var body: some View {
        ScrollView {
            if let song {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(song.title, systemImage: "music.note")
                            .font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                        if !song.artists.isEmpty {
                            Text(song.artists.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        Text("Appears on \(song.discCount) BDs")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("BDs featuring this song").font(.title2.weight(.semibold))
                    ForEach(song.appearances) { appearance in
                        appearanceRow(appearance)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("Song no longer in the library", systemImage: "music.note")
            }
        }
        .navigationTitle(song?.title ?? String(localized: "Song"))
    }

    private func appearanceRow(_ appearance: ConcertSongAppearance) -> some View {
        HStack(spacing: 16) {
            NavigationLink(value: ConcertRoute(
                animeID: appearance.concert.id, discNumber: appearance.discNumber
            )) {
                HStack(spacing: 16) {
                    PosterView(urls: appearance.concert.coverURLs, height: 80)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(appearance.concert.displayTitle).font(.headline)
                        Text(appearance.track.title)
                            .font(.callout).foregroundStyle(.secondary)
                        if let date = appearance.concert.sortDate {
                            Text(date).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text("Disc \(appearance.discNumber)")
                            Text("Track \(appearance.track.position)")
                            if let title = appearance.discTitle, !title.isEmpty {
                                Text(title).lineLimit(1)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Label("Open BD", systemImage: "chevron.right")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 6) {
                if let time = appearance.startTime {
                    Button {
                        Task { await model.play(appearance.episode, startingAt: time) }
                    } label: {
                        Label("Play Song", systemImage: "play.fill")
                    }
                    Text(timeLabel(time))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if appearance.timeline?.isTrustworthy == false {
                        Text("Times are a guess").font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    Text("No times").font(.caption).foregroundStyle(.secondary)
                }
                if let source = appearance.concert.release?.attribution[.setlist] {
                    Text("Setlist from \(source.displayName)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
