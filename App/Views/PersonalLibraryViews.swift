import AnimeGodCore
import SwiftUI

struct RankingsView: View {
    @EnvironmentObject private var model: AppModel

    private var ranked: [(AnimeProfile, LibraryAnime)] {
        model.profilesByAnimeID.values
            .filter { $0.ranking != nil }
            .compactMap { profile in
                model.library.first(where: { $0.id == profile.animeID }).map { (profile, $0) }
            }
            .sorted {
                if $0.0.ranking != $1.0.ranking { return ($0.0.ranking ?? .max) < ($1.0.ranking ?? .max) }
                return $0.1.anime.sortTitle.localizedCaseInsensitiveCompare($1.1.anime.sortTitle) == .orderedAscending
            }
    }

    var body: some View {
        Group {
            if ranked.isEmpty {
                ContentUnavailableView {
                    Label("No Personal Ranking", systemImage: "list.number")
                } description: {
                    Text("Open an anime, edit your entry, and assign it a ranking. Rankings stay separate from scores.")
                }
            } else {
                List(Array(ranked.enumerated()), id: \.element.0.id) { index, entry in
                    let profile = entry.0
                    let item = entry.1
                    NavigationLink(value: item.anime) {
                        HStack(spacing: 14) {
                            Text("#\(profile.ranking ?? index + 1)")
                                .font(.title2.bold().monospacedDigit())
                                .frame(width: 58, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            PosterView(urls: model.posterCandidates(for: item.id))
                                .frame(width: 46, height: 69)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.metadataByAnimeID[item.id]?.title ?? item.anime.title).font(.headline)
                                HStack(spacing: 10) {
                                    Text(profile.status.displayName)
                                    if let score = profile.score { Label(String(format: "%.1f", score), systemImage: "star.fill") }
                                    if profile.isFavorite { Label("Favorite", systemImage: "heart.fill") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(spacing: 2) {
                                Button { Task { await model.moveRanking(animeID: item.id, by: -1) } } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)
                                Button { Task { await model.moveRanking(animeID: item.id, by: 1) } } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index == ranked.count - 1)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .navigationTitle("My Rankings")
        .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0) }
    }
}

struct DiaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.watchHistory.isEmpty {
                ContentUnavailableView(
                    "No Watch History",
                    systemImage: "book.closed",
                    description: Text("Meaningful playback sessions will form your private, local anime diary.")
                )
            } else {
                List {
                    Section {
                        summaryGrid
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    }
                    Section("Recent Sessions") {
                        ForEach(model.watchHistory) { event in
                            HStack(spacing: 12) {
                                Image(systemName: event.completedEpisode ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                                    .font(.title2)
                                    .foregroundStyle(event.completedEpisode ? Color.green : Color.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.animeTitle).font(.headline)
                                    Text(event.episodeLabel).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(event.endedAt, format: .dateTime.month().day().hour().minute())
                                    Text(duration(event.watchedDuration))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Anime Diary")
    }

    private var summaryGrid: some View {
        HStack(spacing: 12) {
            DiaryMetric(title: "Watch Time", value: duration(model.diarySummary.totalWatchTime), symbol: "clock")
            DiaryMetric(title: "Sessions", value: "\(model.diarySummary.sessionCount)", symbol: "play.rectangle")
            DiaryMetric(title: "Episodes Finished", value: "\(model.diarySummary.completedEpisodeCount)", symbol: "checkmark.circle")
            DiaryMetric(title: "Anime Watched", value: "\(model.diarySummary.animeCount)", symbol: "film.stack")
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

private struct DiaryMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct AnimeProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let anime: Anime
    @State private var profile: AnimeProfile
    @State private var scoreText: String
    @State private var rankingText: String
    @State private var tagsText: String

    init(anime: Anime, profile: AnimeProfile) {
        self.anime = anime
        _profile = State(initialValue: profile)
        _scoreText = State(initialValue: profile.score.map { String(format: "%.1f", $0) } ?? "")
        _rankingText = State(initialValue: profile.ranking.map(String.init) ?? "")
        _tagsText = State(initialValue: profile.tags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tracking") {
                    Picker("Status", selection: $profile.status) {
                        ForEach(WatchStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField("Score (0–10)", text: $scoreText)
                    TextField("Personal rank", text: $rankingText)
                    Toggle("Favorite", isOn: $profile.isFavorite)
                    Stepper("Rewatches: \(profile.rewatchCount)", value: $profile.rewatchCount, in: 0...999)
                }
                Section("Organization") {
                    TextField("Tags, separated by commas", text: $tagsText)
                }
                Section("Private Notes") {
                    TextEditor(text: $profile.notes).frame(minHeight: 80)
                }
                Section("My Review") {
                    TextEditor(text: $profile.review).frame(minHeight: 120)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("My Entry · \(anime.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func save() async {
        let trimmedScore = scoreText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRank = rankingText.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.score = trimmedScore.isEmpty ? nil : Double(trimmedScore)
        profile.ranking = trimmedRank.isEmpty ? nil : Int(trimmedRank)
        profile.tags = tagsText.split(separator: ",").map(String.init)
        if await model.saveProfile(profile) { dismiss() }
    }
}
