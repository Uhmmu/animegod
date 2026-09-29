import AnimeGodCore
import SwiftUI

/// What is on the phone itself.
struct OfflineScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var confirmingRemoveAll = false

    private var downloaded: [MobileOfflineStore.Entry] {
        model.offline.entries.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    var body: some View {
        List {
            if !model.offline.active.isEmpty {
                Section("Downloading") {
                    ForEach(Array(model.offline.active.keys), id: \.self) { episodeID in
                        if let progress = model.offline.active[episodeID] {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(episodeName(episodeID))
                                    .font(.subheadline)
                                    .lineLimit(1)
                                ProgressBar(fraction: progress.fraction)
                                HStack {
                                    Text(verbatim: "\(formatBytes(progress.received)) / \(formatBytes(progress.expected))")
                                    Spacer()
                                    Button("Cancel") { model.offline.cancel(episodeID: episodeID) }
                                        .buttonStyle(.borderless)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if downloaded.isEmpty && model.offline.active.isEmpty {
                ContentUnavailableView(
                    "Nothing Downloaded",
                    systemImage: "iphone.and.arrow.forward",
                    description: Text("Episodes you download play with no network at all — the Mac does not need to be awake, or anywhere near you.")
                )
                .listRowBackground(Color.clear)
            }

            if !downloaded.isEmpty {
                Section {
                    ForEach(downloaded) { entry in
                        HStack(spacing: 12) {
                            PosterView(animeID: entry.animeID, cornerRadius: 6).frame(width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.subheadline).lineLimit(1)
                                Text(Episode.localizedLabel(entry.label))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatBytes(entry.byteCount))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                model.offline.remove(episodeID: entry.episodeID)
                            }
                        }
                    }
                } header: {
                    Text("On This Phone")
                } footer: {
                    Text("\(downloaded.count) episodes · \(formatBytes(model.offline.totalBytes)). Excluded from iCloud backup — they are copies of files that live on your Mac.")
                }

                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                }
            }

            if let error = model.offline.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Offline")
        .confirmationDialog("Remove every download?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { model.offline.removeAll() }
        } message: {
            Text("Nothing on your Mac changes.")
        }
    }

    private func episodeName(_ episodeID: UUID) -> String {
        if let entry = model.offline.entries[episodeID] {
            return "\(entry.title) · \(Episode.localizedLabel(entry.label))"
        }
        if let item = model.continueWatching.first(where: { $0.id == episodeID }) {
            return "\(model.title(forAnimeID: item.animeID)) · \(Episode.localizedLabel(item.label))"
        }
        return String(localized: "Episode")
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: max(0, bytes))
}
