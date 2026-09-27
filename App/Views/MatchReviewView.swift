import AnimeGodCore
import SwiftUI

/// Presents metadata matches the automatic pass could not make on its own, so
/// a person — not a heuristic — decides which provider entry a local anime
/// corresponds to.
///
/// Two kinds end up here. A dubious hit, where the provider offered something
/// but not confidently enough to link unattended; and a work the provider has
/// never heard of under any of the names the library knows it by, which used
/// to be dropped in silence. The second is why every section has a search
/// field: a person can spell a title a way the heuristics cannot.
struct MatchReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.pendingMatches.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to Review", systemImage: "checkmark.seal")
                    } description: {
                        Text("Matches AnimeGod could not make on its own appear here. It looks for metadata by itself after every scan, so this fills in without being asked.")
                    }
                } else {
                    List(model.pendingMatches) { pending in
                        PendingMatchSection(pending: pending)
                    }
                }
            }
            .navigationTitle("Review Matches")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

private struct PendingMatchSection: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingMetadataMatch
    @State private var query = ""
    @State private var didPrefill = false

    var body: some View {
        Section {
            searchBar
            if pending.candidates.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text(pending.isSearching
                         ? "Searching…"
                         : "\(pending.provider.displayName) has nothing under this name. Try another spelling — its romaji or English title often works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(pending.candidates) { ranked in
                Button {
                    Task { await model.confirmPendingMatch(pending, candidate: ranked.candidate) }
                } label: {
                    CandidateRow(ranked: ranked)
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text(pending.anime.title)
                Spacer()
                Text(pending.provider.displayName)
            }
        } footer: {
            HStack {
                Text("Skipping is remembered, so this title is not asked about again.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Skip This Anime") { model.skipPendingMatch(pending) }
                    .buttonStyle(.link)
            }
        }
        .onAppear {
            guard !didPrefill else { return }
            query = pending.query
            didPrefill = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(pending.provider.displayName)", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { search() }
            if pending.isSearching {
                ProgressView().controlSize(.small)
            }
            Button("Search") { search() }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending.isSearching)
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let text = query
        Task { await model.searchPendingMatch(pending, query: text) }
    }
}

private struct CandidateRow: View {
    let ranked: RankedMatch

    var body: some View {
        HStack(spacing: 14) {
            PosterView(url: ranked.candidate.posterURL, height: 69)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 4) {
                Text(ranked.candidate.title).font(.headline)
                if ranked.candidate.originalTitle != ranked.candidate.title {
                    Text(ranked.candidate.originalTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let date = ranked.candidate.airDate { Text(date) }
                    if let score = ranked.candidate.score {
                        Label(String(format: "%.1f", score), systemImage: "star.fill")
                            .foregroundStyle(.orange)
                    }
                    if let episodes = ranked.candidate.totalEpisodes {
                        Text("\(episodes) episodes")
                    }
                    Text("\(Int(round(ranked.score * 100)))% match")
                        .foregroundStyle(.blue)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
