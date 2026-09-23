import AnimeGodCore
import Charts
import SwiftUI

/// Yearly answers to "what did I watch" (spec §17), derived entirely from
/// local watch history and cached metadata.
struct StatisticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedYear: Int = Calendar.current.dateComponents([.year], from: .now).year!

    private var report: StatisticsReport? { model.statisticsReport }

    var body: some View {
        ScrollView {
            if let report {
                LazyVStack(alignment: .leading, spacing: 26) {
                    yearPicker(report)
                    headlineCards(report)
                    monthlyChart(report)
                    habitsSection(report)
                    topAnimeSection(report)
                    studiosSection(report)
                    ratedSection(report)
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
            } else {
                ContentUnavailableView(
                    "No Statistics Yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Play a few episodes and your yearly viewing report will build itself from watch history.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Statistics")
        .task(id: selectedYear) {
            await model.loadStatistics(year: selectedYear)
        }
        .onChange(of: model.watchHistory.count) { _, _ in
            Task { await model.loadStatistics(year: selectedYear) }
        }
    }

    private func yearPicker(_ report: StatisticsReport) -> some View {
        HStack {
            Picker("Year", selection: $selectedYear) {
                ForEach(report.availableYears, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.menu)
            Spacer()
        }
    }

    private func headlineCards(_ report: StatisticsReport) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            StatCard(title: "Watch Time", value: durationText(report.totalWatchTime), systemImage: "clock")
            StatCard(title: "Sessions", value: "\(report.sessionCount)", systemImage: "play.rectangle")
            StatCard(title: "Episodes Finished", value: "\(report.completedEpisodeCount)", systemImage: "checkmark.circle")
            StatCard(title: "Anime Touched", value: "\(report.distinctAnimeCount)", systemImage: "square.stack.3d.up")
        }
    }

    private var shortMonthSymbols: [String] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        return formatter.shortMonthSymbols ?? Array(1...12).map(String.init)
    }

    private func monthlyChart(_ report: StatisticsReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monthly Watch Time").font(.title3.bold())
            Chart {
                ForEach(Array(report.monthlyWatchTime.enumerated()), id: \.offset) { index, hours in
                    BarMark(
                        x: .value("Month", shortMonthSymbols[index]),
                        y: .value("Hours", hours / 3600)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: 190)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func habitsSection(_ report: StatisticsReport) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sessions by Weekday").font(.headline)
                Chart {
                    ForEach(Array(report.weekdaySessions.enumerated()), id: \.offset) { index, count in
                        BarMark(
                            x: .value("Weekday", Calendar.current.shortWeekdaySymbols[index]),
                            y: .value("Sessions", count)
                        )
                        .foregroundStyle(.teal.gradient)
                    }
                }
                .frame(height: 150)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text("Sessions by Hour").font(.headline)
                Chart {
                    ForEach(Array(report.hourSessions.enumerated()), id: \.offset) { index, count in
                        BarMark(
                            x: .value("Hour", "\(index)"),
                            y: .value("Sessions", count)
                        )
                        .foregroundStyle(.indigo.gradient)
                    }
                }
                .frame(height: 150)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func topAnimeSection(_ report: StatisticsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most Watched Anime").font(.title3.bold())
            if report.topAnime.isEmpty {
                Text("Nothing watched in \(String(report.year)) yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(report.topAnime.prefix(10).enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        PosterView(urls: model.posterCandidates(for: entry.animeID), height: 60)
                            .frame(width: 40, height: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.headline)
                            Text("\(entry.completedEpisodes) episodes finished · \(entry.sessionCount) sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(durationText(entry.watchTime))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func studiosSection(_ report: StatisticsReport) -> some View {
        Group {
            if !report.topStudios.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Most Watched Studios").font(.title3.bold())
                    Chart {
                        ForEach(Array(report.topStudios.prefix(8).enumerated()), id: \.element.id) { _, entry in
                            BarMark(
                                x: .value("Hours", entry.watchTime / 3600),
                                y: .value("Studio", entry.studio)
                            )
                            .foregroundStyle(Color.accentColor.gradient)
                            .annotation(position: .trailing) {
                                Text(durationText(entry.watchTime))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(min(report.topStudios.count, 8)) * 34)
                }
                .padding(18)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func ratedSection(_ report: StatisticsReport) -> some View {
        Group {
            if !report.highestRated.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("My Highest-Rated of \(String(report.year))").font(.title3.bold())
                    ForEach(report.highestRated) { entry in
                        HStack {
                            Text(entry.title)
                            Spacer()
                            Label(String(format: "%.1f", entry.score), systemImage: "star.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(18)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func durationText(_ seconds: Double) -> String {
        // Whole minutes, formatted for the interface language.
        Duration.seconds(Int(seconds) / 60 * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

private struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
