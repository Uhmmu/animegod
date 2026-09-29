import AnimeGodCore
import SwiftUI

/// What was watched, newest first, grouped by day.
struct DiaryScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var diary: LinkDiary?

    private var days: [(day: Date, events: [WatchEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: diary?.events ?? []) {
            calendar.startOfDay(for: $0.endedAt)
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.endedAt > $1.endedAt }) }
    }

    var body: some View {
        List {
            if let summary = diary?.summary {
                Section {
                    HStack {
                        SummaryTile(String(localized: "Watched"), formatDuration(summary.totalWatchTime))
                        SummaryTile(String(localized: "Sessions"), String(summary.sessionCount))
                        SummaryTile(String(localized: "Episodes"), String(summary.completedEpisodeCount))
                        SummaryTile(String(localized: "Works"), String(summary.animeCount))
                    }
                    .padding(.vertical, 4)
                }
            }

            ForEach(days, id: \.day) { day in
                Section(day.day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(day.events) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.animeTitle).font(.subheadline).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(Episode.localizedLabel(event.episodeLabel))
                                Text(verbatim: "·")
                                Text(formatDuration(event.watchedDuration))
                                if event.completedEpisode {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                                Spacer()
                                Text(event.endedAt.formatted(date: .omitted, time: .shortened))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            if diary?.events.isEmpty ?? false {
                ContentUnavailableView("Nothing Watched Yet", systemImage: "book")
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Diary")
        .task { diary = await model.diary() }
        .refreshable { diary = await model.diary() }
    }
}

struct SummaryTile: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}
