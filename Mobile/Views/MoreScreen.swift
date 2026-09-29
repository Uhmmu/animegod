import SwiftUI

/// The Mac sidebar's remaining sections.
///
/// A phone with twelve tabs is a bad phone, so they live behind "More". Some
/// are the phone's own screens over the Mac's data; some are the phone acting
/// as a remote control for the Mac. Both are the same library.
struct MoreScreen: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Row("Offline Episodes", "iphone.and.arrow.forward", "Play with no network at all") {
                        OfflineScreen()
                    }
                }

                Section {
                    Row("Diary", "book", "What you watched, when") { DiaryScreen() }
                    Row("Statistics", "chart.pie", "Hours, episodes, studios") { StatisticsScreen() }
                    Row("Rankings", "trophy", "Your own ordering") { RankingsScreen() }
                    Row("Charts", "chart.bar", "Bangumi's site-wide rankings") { ChartsScreen() }
                } header: {
                    Text("Your Library")
                }

                Section {
                    Row("Downloads", "arrow.down.circle", "Pause and resume from here") { DownloadsScreen() }
                    Row("Subscriptions", "bell", "Seasons your Mac is following") { SubscriptionsScreen() }
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text("These control what your Mac is doing. Starting a download or making a rule stays there — a rule is read off an episode set, and there is nothing sensible to type on a phone.")
                }
            }
            .navigationTitle("More")
        }
    }
}

private struct Row<Destination: View>: View {
    let title: LocalizedStringKey
    let icon: String
    let detail: LocalizedStringKey
    @ViewBuilder let destination: () -> Destination

    init(
        _ title: LocalizedStringKey,
        _ icon: String,
        _ detail: LocalizedStringKey,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.icon = icon
        self.detail = detail
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 26).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
