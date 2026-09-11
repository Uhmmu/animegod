import AnimeGodCore
import SwiftUI

/// Cache management: total usage, per-episode copies with live copy progress,
/// manual deletion, and the two rules that drive automatic caching.
struct EpisodeCacheView: View {
    @ObservedObject var cache: EpisodeCacheStore
    @State private var confirmingClearAll = false

    private var grouped: [(anime: String, entries: [EpisodeCacheEntry])] {
        let byAnime = Dictionary(grouping: cache.entries) { $0.animeTitle ?? "Unknown Anime" }
        return byAnime
            .map { (anime: $0.key, entries: $0.value) }
            .sorted { $0.anime.localizedCaseInsensitiveCompare($1.anime) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                summary
            } header: {
                Text("Rules")
            } footer: {
                Text("Auto caches are created while playing from an external drive and are deleted once you finish an episode (≥90% on close). Manual caches stay until you remove them.")
            }

            if cache.entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Cached Episodes",
                        systemImage: "icloud.slash",
                        description: Text("Episodes played from an external drive cache onto this Mac automatically. You can also cache any episode from its anime page.")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(grouped, id: \.anime) { group in
                    Section(group.anime) {
                        ForEach(group.entries) { entry in
                            CacheEntryRow(entry: entry, cache: cache)
                        }
                    }
                }
            }
        }
        .navigationTitle("Episode Cache")
        .alert("Clear all cached episodes?", isPresented: $confirmingClearAll) {
            Button("Clear All", role: .destructive) { cache.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are removed from this Mac. Nothing on your external drive is touched.")
        }
        .task { await cache.reload() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label(
                    cache.entries.isEmpty
                        ? "Nothing cached"
                        : "\(cache.entries.count) episode\(cache.entries.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: cache.totalBytes, countStyle: .file))",
                    systemImage: "internaldrive"
                )
                Spacer()
                Button {
                    confirmingClearAll = true
                } label: {
                    Label("Clear All…", systemImage: "trash")
                }
                .disabled(cache.entries.isEmpty)
            }

            Toggle("Auto-cache while playing from an external drive", isOn: $cache.autoCachingEnabled)
            Toggle("Delete auto caches after finishing an episode", isOn: $cache.autoDeleteEnabled)

            HStack(spacing: 6) {
                Text(cache.cacheDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(cache.cacheDirectory.path)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.open(cache.cacheDirectory)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CacheEntryRow: View {
    let entry: EpisodeCacheEntry
    @ObservedObject var cache: EpisodeCacheStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.state == .complete ? "checkmark.icloud.fill" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(entry.state == .complete ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(entry.animeTitle ?? "Unknown Anime") · \(entry.episodeLabel ?? entry.fileName)")
                    .font(.headline)
                    .lineLimit(1)
                if entry.state == .copying {
                    HStack(spacing: 8) {
                        ProgressView(value: entry.progress)
                            .frame(width: 140)
                        Text("\(ByteCountFormatter.string(fromByteCount: entry.bytesCopied, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(entry.fileName) · \(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if entry.isEpisodeWatched {
                Label("Watched", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.policy.displayName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(entry.policy == .manual ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
                .help(entry.policy == .manual
                      ? "You asked to keep this copy; it stays until you remove it."
                      : "Created automatically while playing; removed once watched.")

            if entry.state == .copying {
                Button {
                    cache.removeEntry(mediaFileID: entry.mediaFileID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Cancel this copy")
            } else {
                Button {
                    cache.revealInFinder(mediaFileID: entry.mediaFileID)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                Button(role: .destructive) {
                    cache.removeEntry(mediaFileID: entry.mediaFileID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this cached copy")
            }
        }
        .padding(.vertical, 2)
    }
}
