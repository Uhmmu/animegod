import AnimeGodCore
import SwiftUI

/// The Downloads list: what the embedded BitTorrent engine is fetching, how
/// fast, and whether this Mac is reachable — the single biggest factor in
/// BitTorrent speed, so it is shown rather than hidden.
struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var downloads: TorrentDownloadManager
    @ObservedObject private var folders: DownloadFolderStore
    @State private var confirmingRemoval: TorrentDownloadItem?

    init(downloads: TorrentDownloadManager) {
        self.downloads = downloads
        folders = downloads.folders
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if let notice = folders.fallbackNotice {
                notice_(notice, icon: "externaldrive.trianglebadge.exclamationmark", tint: .orange)
            }
            if let status = downloads.statusMessage {
                notice_(status, icon: "info.circle", tint: .secondary) { downloads.statusMessage = nil }
            }
            if let error = downloads.errorMessage {
                notice_(error, icon: "exclamationmark.triangle.fill", tint: .red) {
                    downloads.errorMessage = nil
                }
            }
            Divider()
            content
        }
        .navigationTitle("Downloads")
        .alert(
            "Remove this download?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { item in
            Button("Remove and Delete Files", role: .destructive) {
                downloads.remove(item, deleteFiles: true)
                confirmingRemoval = nil
            }
            Button("Remove, Keep Files") {
                downloads.remove(item, deleteFiles: false)
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { item in
            Text("“\(item.title)” will stop downloading. Files already written can be kept or deleted.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Choose Folder…") { folders.chooseFolder() }
                if !folders.libraryFolders.isEmpty {
                    Section("Library Folders") {
                        ForEach(folders.libraryFolders) { folder in
                            // A folder added before downloads existed was
                            // authorised read-only; saying so here beats
                            // failing after the user picks it.
                            let writable = folders.isWritable(folder)
                            Button(writable ? folder.path : "\(folder.path) — read-only, re-pick to allow") {
                                folders.select(folder)
                            }
                        }
                    }
                }
                if !folders.recentFolders.isEmpty {
                    Section("Recent") {
                        ForEach(folders.recentFolders) { folder in
                            Button(folder.path) { folders.select(folder) }
                        }
                    }
                }
            } label: {
                Label(folders.currentFolder.displayName, systemImage: "folder")
            }
            .fixedSize()
            .help(folders.currentFolder.libraryRootID != nil
                  ? "Downloads are saved to \(folders.currentFolder.path) and scanned into the library when they finish"
                  : "Downloads are saved to \(folders.currentFolder.path)")

            if let info = downloads.sessionInfo, info.isRunning {
                Label(
                    ByteCountFormatter.string(fromByteCount: Int64(info.downloadRate), countStyle: .binary) + "/s",
                    systemImage: "arrow.down"
                )
                .monospacedDigit()
                Label(
                    ByteCountFormatter.string(fromByteCount: Int64(info.uploadRate), countStyle: .binary) + "/s",
                    systemImage: "arrow.up"
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
                Spacer()
                connectivity(info)
            } else {
                Spacer()
                Text("Engine idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func connectivity(_ info: AGTorrentSessionInfo) -> some View {
        HStack(spacing: 10) {
            Label("\(info.dhtNodes) DHT", systemImage: "point.3.connected.trianglepath.dotted")
                .help("Peers reachable through the distributed hash table")
            if let mapped = info.portMapped?.boolValue {
                Label(
                    mapped ? "Port \(info.listenPort) open" : "Port \(info.listenPort) not mapped",
                    systemImage: mapped ? "network" : "network.slash"
                )
                .foregroundStyle(mapped ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .help(mapped
                      ? "Other peers can connect to this Mac, which raises the speed ceiling."
                      : "UPnP/NAT-PMP could not open the port. Forwarding port \(info.listenPort) on your router lets peers connect to you — the biggest factor in BitTorrent speed. On CGNAT connections only IPv6 peers can reach you.")
            } else {
                Label("Mapping port…", systemImage: "network")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func notice_(_ text: String, icon: String, tint: Color, dismiss: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let dismiss {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if downloads.items.isEmpty {
            ContentUnavailableView {
                Label("No Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Releases you download from Find Releases appear here. Files are saved to \(folders.currentFolder.displayName) and keep downloading while AnimeGod is open.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(downloads.items) { item in
                    DownloadRow(item: item, downloads: downloads) { confirmingRemoval = item }
                        .padding(.vertical, 4)
                        .environmentObject(model)
                        .environmentObject(folders)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct DownloadRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var folders: DownloadFolderStore
    let item: TorrentDownloadItem
    @ObservedObject var downloads: TorrentDownloadManager
    let remove: () -> Void

    /// A file can be opened once enough of its start exists. Sequential
    /// downloads fill the beginning first, so playback catches up with the
    /// download rather than running past it.
    private var playableFile: AGTorrentFileEntry? {
        downloads.playableVideoFile(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .lineLimit(2)
                    .help(item.title)
                Spacer(minLength: 12)
                Text(sizeText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: min(max(item.progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(item.isComplete ? .green : (item.isPaused ? .secondary : .accentColor))

            HStack(spacing: 8) {
                Text(item.statusText)
                    .font(.caption)
                    .foregroundStyle(item.snapshot?.state == .errored ? .red : .secondary)
                    .lineLimit(1)
                if let remaining = item.remainingText {
                    Text("· \(remaining) left")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if item.record.isSequential {
                    Text("· in order")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Pieces are downloaded in order so the file can be played before it finishes")
                }
                Spacer()
                controls
            }
        }
        .contextMenu {
            if let file = playableFile {
                Button(item.isComplete ? "Play" : "Play While Downloading") {
                    downloads.play(file, of: item, using: model)
                }
            }
            Button("Show in Finder") { downloads.revealInFinder(item) }
            if (item.snapshot?.savePath ?? item.record.savePath) != folders.currentFolder.path {
                Button("Move to \(folders.currentFolder.displayName)") { downloads.moveToCurrentFolder(item) }
            }
            Button(item.record.isSequential ? "Download in Any Order" : "Download in Order") {
                downloads.setSequential(!item.record.isSequential, for: item)
            }
            Button("Re-announce to Trackers") { downloads.reannounce(item) }
            Divider()
            if item.isComplete, model.libraryRoot(containing: URL(fileURLWithPath: item.record.savePath)) == nil {
                Button("Add Download Folder to Library") {
                    Task { await model.addDownloadFolderToLibrary(URL(fileURLWithPath: item.record.savePath)) }
                }
            }
            Button("Copy Magnet Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.record.magnet, forType: .string)
            }
            Button("Remove…", role: .destructive) { remove() }
        }
    }

    private var sizeText: String {
        let total = item.totalBytes
        guard total > 0 else { return "—" }
        let done = ByteCountFormatter.string(fromByteCount: item.downloadedBytes, countStyle: .binary)
        let whole = ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
        return item.isComplete ? whole : "\(done) / \(whole)"
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            if let file = playableFile {
                Button { downloads.play(file, of: item, using: model) } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help(item.isComplete ? "Play" : "Play now — the rest keeps downloading")
            }
            if !item.isComplete {
                Button {
                    item.isPaused ? downloads.resume(item) : downloads.pause(item)
                } label: {
                    Image(systemName: item.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(item.isPaused ? "Resume" : "Pause")
            }
            Button { downloads.revealInFinder(item) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button(role: .destructive) { remove() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .controlSize(.small)
    }
}
