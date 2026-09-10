import AnimeGodCore
import SwiftUI

/// Presents ambiguous metadata matches so the user — not a heuristic — decides
/// which provider entry a local anime corresponds to.
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
                        Text("Ambiguous matches found by “Find Metadata” appear here for your decision.")
                    }
                } else {
                    List(model.pendingMatches) { pending in
                        Section {
                            ForEach(pending.candidates) { ranked in
                                Button {
                                    Task { await model.confirmPendingMatch(pending, candidate: ranked.candidate) }
                                } label: {
                                    HStack(spacing: 14) {
                                        PosterView(url: ranked.candidate.posterURL)
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
                                Spacer()
                                Button("Skip This Anime") { model.skipPendingMatch(pending) }
                                    .buttonStyle(.link)
                            }
                        }
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
