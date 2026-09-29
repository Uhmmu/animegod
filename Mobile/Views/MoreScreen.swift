import SwiftUI

/// The Mac sidebar's remaining sections. A phone with twelve tabs is a bad
/// phone, so they live behind "More" — see §9 of the plan. None of them are
/// built yet; they are listed so the shape of the app is visible.
struct MoreScreen: View {
    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let detail: String
        let phase: Int
    }

    private let sections: [Section] = [
        .init(title: "Bangumi Charts", icon: "chart.bar", detail: "What is airing this season", phase: 5),
        .init(title: "Rankings", icon: "trophy", detail: "Your own ordering", phase: 5),
        .init(title: "Diary", icon: "book", detail: "What you watched, when", phase: 5),
        .init(title: "Statistics", icon: "chart.pie", detail: "Hours, completions, streaks", phase: 5),
        .init(title: "Find Releases", icon: "magnifyingglass", detail: "Search here, download on the Mac", phase: 6),
        .init(title: "Downloads", icon: "arrow.down.circle", detail: "Live progress, pause and resume remotely", phase: 6),
        .init(title: "Subscriptions", icon: "bell", detail: "Follow a season, confirm candidates", phase: 6),
    ]

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section {
                    NavigationLink {
                        OfflineScreen()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .frame(width: 26)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Offline Episodes")
                                Text("Play with no network at all")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                SwiftUI.Section {
                    ForEach(sections) { section in
                        HStack(spacing: 12) {
                            Image(systemName: section.icon)
                                .frame(width: 26)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                Text(section.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Phase \(section.phase)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("These mirror the Mac's sidebar. Some are the phone's own screens; some are the phone acting as a remote control for the Mac. None are built yet.")
                }
            }
            .navigationTitle("More")
        }
    }
}
