import AnimeGodCore
import SwiftUI

/// What this Mac is giving back: the finished downloads, whether each is
/// sharing, and how much has gone out.
///
/// It is its own section rather than a corner of Downloads because the two
/// answer different questions. Downloads is "is my episode here yet", and it
/// empties as things finish; seeding is "what am I uploading, and at whose
/// expense", which only starts once a download is done. Putting the switch at
/// the top of the list it governs is the same reasoning that keeps the speed
/// ceiling next to the speeds.
struct SeedingView: View {
    @ObservedObject var downloads: TorrentDownloadManager

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            content
        }
        .navigationTitle("Seeding")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Toggle("Share Finished Downloads", isOn: $downloads.seedsAfterDownloading)
                .toggleStyle(.switch)
                .help("BitTorrent only works because finished downloads keep sharing. Turning this off stops every task that has finished — nothing is uploaded once a download completes.")
                .fixedSize()

            if downloads.seedsAfterDownloading, let info = downloads.sessionInfo, info.isRunning {
                Label(
                    ByteCountFormatter.string(fromByteCount: Int64(info.uploadRate), countStyle: .binary) + "/s",
                    systemImage: "arrow.up"
                )
                .monospacedDigit()
                .help("How fast this Mac is uploading right now")
            }

            Spacer()

            if downloads.sharedBytes > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: downloads.sharedBytes, countStyle: .binary)) shared in total")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if !downloads.seedsAfterDownloading {
            ContentUnavailableView {
                Label("Not Sharing", systemImage: "arrow.up.circle.badge.xmark")
            } description: {
                Text("Nothing is being uploaded. Finished downloads stay on disk and stop sharing, and a download that completes from now on stops as soon as it finishes.\n\nSharing is how a swarm survives: every episode downloaded here came from someone who left theirs running. It costs upload bandwidth for as long as AnimeGod is open, so it is yours to switch on.")
            } actions: {
                Button("Share Finished Downloads") { downloads.seedsAfterDownloading = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        } else if downloads.completedItems.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Share Yet", systemImage: "arrow.up.circle")
            } description: {
                Text("Downloads that finish appear here and go on sharing themselves until you remove them or switch this off.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(downloads.completedItems) { item in
                    SeedingRow(item: item, downloads: downloads)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct SeedingRow: View {
    let item: TorrentDownloadItem
    @ObservedObject var downloads: TorrentDownloadManager

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: item.isSeeding ? "arrow.up.circle.fill" : "pause.circle")
                .foregroundStyle(item.isSeeding ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .help(item.isSeeding ? "Sharing" : "Stopped")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(2)
                    .help(item.title)
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let ratio = item.shareRatio {
                        Text("· \(ratioText(ratio)) shared back")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .help("How much has been uploaded against the size of the download: 1.0× is having given the episode back once")
                    }
                }
            }

            Spacer(minLength: 12)
            controls
        }
        .contextMenu {
            Button("Show in Finder") { downloads.revealInFinder(item) }
            Button("Re-announce to Trackers") { downloads.reannounce(item) }
                .help("Tell the trackers and the DHT this copy is here, so peers looking for it can find it")
            Divider()
            Button("Copy Magnet Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.record.magnet, forType: .string)
            }
        }
    }

    /// The live figures when it is sharing, and what it has already given
    /// back when it is not — a stopped task with 3 GB uploaded has still
    /// done the thing this section is about.
    private var statusText: String {
        let shared = ByteCountFormatter.string(fromByteCount: item.uploadedBytes, countStyle: .binary)
        guard item.isSeeding else {
            return item.uploadedBytes > 0
                ? String(localized: "Stopped · \(shared) shared")
                : String(localized: "Stopped")
        }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(item.uploadRate), countStyle: .binary)
        let peers = item.snapshot?.connectedPeers ?? 0
        return String(localized: "\(rate)/s · \(shared) shared · \(peers) peers")
    }

    private func ratioText(_ ratio: Double) -> String {
        String(format: "%.2f×", ratio)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            if item.isPaused {
                Button { downloads.startSeeding(item) } label: {
                    Image(systemName: "arrow.up.circle")
                }
                .buttonStyle(.borderless)
                .help("Share this one again")
            } else {
                Button { downloads.stopSeeding(item) } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop sharing this one, and leave the rest sharing")
            }
            Button { downloads.revealInFinder(item) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .controlSize(.small)
    }
}
