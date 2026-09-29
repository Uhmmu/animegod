import AnimeGodCore
import SwiftUI

/// The year in numbers.
struct StatisticsScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var report: StatisticsReport?
    @State private var year: Int?
    @State private var isLoading = true

    var body: some View {
        List {
            if let report {
                if report.availableYears.count > 1 {
                    Section {
                        Picker("Year", selection: Binding(
                            get: { year ?? report.year },
                            set: { year = $0; Task { await load() } }
                        )) {
                            ForEach(report.availableYears, id: \.self) { Text(verbatim: String($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    HStack {
                        SummaryTile(String(localized: "Watched"), formatDuration(report.totalWatchTime))
                        SummaryTile(String(localized: "Episodes"), String(report.completedEpisodeCount))
                        SummaryTile(String(localized: "Works"), String(report.distinctAnimeCount))
                    }
                    .padding(.vertical, 4)
                }

                Section("By Month") {
                    BarRow(values: report.monthlyWatchTime, labels: (1...12).map(String.init))
                }

                Section("By Weekday") {
                    BarRow(
                        values: report.weekdaySessions.map(Double.init),
                        labels: Calendar.current.veryShortStandaloneWeekdaySymbols
                    )
                }

                if !report.topAnime.isEmpty {
                    Section("Most Watched") {
                        ForEach(report.topAnime.prefix(10)) { entry in
                            HStack {
                                Text(entry.title).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text(formatDuration(entry.watchTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !report.topStudios.isEmpty {
                    Section("Studios") {
                        ForEach(report.topStudios.prefix(8)) { studio in
                            HStack {
                                Text(studio.studio).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text(formatDuration(studio.watchTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else {
                ContentUnavailableView("No Statistics", systemImage: "chart.pie")
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Statistics")
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        report = await model.statistics(year: year)
        isLoading = false
    }
}

/// A plain bar row. Deliberately hand-drawn rather than a Charts dependency:
/// two bar rows do not justify one, and this renders identically offline.
struct BarRow: View {
    let values: [Double]
    let labels: [String]

    private var peak: Double { max(values.max() ?? 0, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { index in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(values[index] > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: max(2, 56 * values[index] / peak))
                    Text(verbatim: index < labels.count ? labels[index] : "")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 76)
        .padding(.vertical, 4)
    }
}
