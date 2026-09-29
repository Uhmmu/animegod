import AnimeGodCore
import SwiftUI

/// Bangumi's site-wide ranking charts.
///
/// The only screen here that depends on a third party being up, so it says so
/// when it is not rather than showing an empty list.
struct ChartsScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var charts: LinkCharts?
    @State private var channel = "anime"
    @State private var page = 1
    @State private var isLoading = false
    @State private var error: String?

    private let channels = [
        ("anime", String(localized: "Anime")),
        ("book", String(localized: "Books")),
        ("music", String(localized: "Music")),
        ("game", String(localized: "Games")),
        ("real", String(localized: "Live Action"))
    ]

    var body: some View {
        List {
            Section {
                Picker("Channel", selection: $channel) {
                    ForEach(channels, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: channel) { _, _ in
                    page = 1
                    Task { await load() }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(charts?.entries ?? []) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: "#\(entry.rank)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 38, alignment: .leading)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.subheadline).lineLimit(2)
                        if let original = entry.originalTitle, !original.isEmpty, original != entry.title {
                            Text(original).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            if let score = entry.score {
                                Label(String(format: "%.1f", score), systemImage: "star.fill")
                                    .foregroundStyle(.orange)
                            }
                            if let count = entry.ratingCount {
                                Text("\(count) ratings")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            if let charts, charts.page < charts.totalPages {
                Button {
                    page += 1
                    Task { await load(appending: true) }
                } label: {
                    HStack {
                        Text("Load More")
                        Spacer()
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isLoading)
            }
        }
        .navigationTitle("Charts")
        .task { if charts == nil { await load() } }
    }

    private func load(appending: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await model.charts(channel: channel, page: page)
            if appending, let existing = charts {
                charts = LinkCharts(
                    channel: result.channel, page: result.page, totalPages: result.totalPages,
                    entries: existing.entries + result.entries
                )
            } else {
                charts = result
            }
            error = nil
        } catch let failure as LinkError {
            error = failure.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}
