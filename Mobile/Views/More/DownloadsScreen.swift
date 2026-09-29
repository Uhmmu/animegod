import AnimeGodCore
import SwiftUI

/// The Mac's downloads, as a remote control.
///
/// The phone has no torrent engine: it shows what the Mac is doing and can
/// pause or resume it. Polling rather than pushing, because this screen is
/// only open while someone is looking at it.
struct DownloadsScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var downloads: [LinkDownload] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(downloads) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.animeTitle ?? item.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        if item.isAutomatic {
                            Image(systemName: "bell.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if item.animeTitle != nil {
                        Text(item.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }

                    if !item.isComplete {
                        ProgressBar(fraction: item.progress)
                    }

                    HStack(spacing: 8) {
                        if item.isComplete {
                            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text(verbatim: "\(Int(item.progress * 100))%")
                            Text(verbatim: "↓\(formatRate(item.downloadRate))")
                            Text(verbatim: "↑\(formatRate(item.uploadRate))")
                            Text("\(item.peers) peers")
                        }
                        Spacer()
                        Text(formatBytes(item.totalBytes))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    if !item.isComplete {
                        Button(item.isPaused ? "Resume" : "Pause") {
                            Task {
                                await model.downloadAction(
                                    infoHash: item.infoHash,
                                    item.isPaused ? "resume" : "pause"
                                )
                                await refresh()
                            }
                        }
                        .tint(item.isPaused ? .green : .orange)
                    }
                }
            }

            if loaded && downloads.isEmpty {
                ContentUnavailableView(
                    "Nothing Downloading",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloads you start on your Mac show up here, and can be paused from your phone.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Downloads")
        .refreshable { await refresh() }
        .task {
            await refresh()
            loaded = true
            // Only while the screen is on screen; the Mac ticks once a second
            // and there is no reason to hold that open in the background.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    private func refresh() async {
        if let items = await model.downloads() { downloads = items }
    }
}

func formatRate(_ bytesPerSecond: Int64) -> String {
    guard bytesPerSecond > 0 else { return "0" }
    return formatBytes(bytesPerSecond) + "/s"
}
