import AnimeGodCore
import SwiftUI

/// Asks which anime a download that has just started is of.
///
/// Matching used to wait until the files had landed, which meant going back
/// to the library afterwards and linking it by hand. Answering here gives the
/// work its anime straight away: the card carries the real cover while the
/// episodes arrive, it opens the anime's own page, and the scan that follows
/// finds it already matched.
///
/// The prompt is read from the model rather than passed in. A copy taken when
/// the sheet was presented never sees the search results arrive, which is
/// what made typing a different title look like it did nothing.
struct IncomingMatchSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var didPrefill = false

    private var prompt: AppModel.IncomingMatchPrompt? { model.incomingMatchPrompt }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                results
            }
            .navigationTitle("Which anime is this?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { model.skipIncomingMatch() }
                }
            }
        }
        .frame(minWidth: 540, minHeight: 460)
        .onAppear {
            guard !didPrefill, let prompt else { return }
            query = prompt.query
            didPrefill = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for the anime", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { search() }
            if prompt?.isSearching == true {
                ProgressView().controlSize(.small)
            }
            Button("Search") { search() }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder
    private var results: some View {
        if let prompt {
            if prompt.candidates.isEmpty && prompt.isSearching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if prompt.candidates.isEmpty {
                ContentUnavailableView {
                    Label("No Match Found", systemImage: "questionmark.circle")
                } description: {
                    Text("Nothing came back for “\(query)”. Try another spelling, or skip and match it later from the anime's page.")
                }
            } else {
                List(prompt.candidates) { ranked in
                    Button {
                        Task { await model.confirmIncomingMatch(ranked) }
                    } label: {
                        CandidateRow(ranked: ranked)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func search() {
        let text = query
        Task { await model.searchIncomingMatch(text) }
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
