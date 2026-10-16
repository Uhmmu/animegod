import AnimeGodCore
import SwiftUI

/// Picks the work to fold this one into.
///
/// A season whose first episode arrived on its own, a week before the set, is
/// two cards: the lone download named its folder after whichever team
/// published episode one, and the set named it after another. The two titles
/// are not spellings of each other — the teams' own subtitle-language tags are
/// in them — so nothing automatic can tell them from two different shows, and
/// `TorrentWorkIdentity` quite correctly says they are not one.
///
/// A submenu of every other work in the library would be a hundred titles
/// long and no help at all, so this is a sheet with a search field, prefilled
/// with the longest run of words the two names share: the near-duplicate is
/// almost always the first row.
struct MergeWorkView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The card that will be dissolved.
    let source: Anime
    @State private var query = ""
    @State private var chosen: UUID?
    @State private var isMerging = false

    private var candidates: [LibraryAnime] {
        let others = model.library.filter { $0.anime.id != source.id }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ranked(others) }
        let folded = needle.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return ranked(others.filter { item in
            names(of: item).contains { name in
                name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                    .contains(folded)
            }
        })
    }

    /// Works sharing a prefix with this one first: the split halves of one
    /// season differ only at the end, where the team's tag is.
    private func ranked(_ items: [LibraryAnime]) -> [LibraryAnime] {
        let key = TorrentWorkIdentity.key(source.title)
        return items.sorted { one, other in
            let a = shared(key, TorrentWorkIdentity.key(one.anime.title))
            let b = shared(key, TorrentWorkIdentity.key(other.anime.title))
            if a != b { return a > b }
            return one.anime.title.localizedStandardCompare(other.anime.title) == .orderedAscending
        }
    }

    private func shared(_ one: String, _ other: String) -> Int {
        var count = 0
        for (a, b) in zip(one, other) {
            guard a == b else { break }
            count += 1
        }
        return count
    }

    private func names(of item: LibraryAnime) -> [String] {
        var names = [item.anime.title]
        if let metadata = model.metadataByAnimeID[item.anime.id] {
            names.append(contentsOf: [metadata.title, metadata.originalTitle])
        }
        return names
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(source.title)” will be dissolved. Its episodes, files, watch history, downloads and subscriptions move to the work you pick, and its card disappears.")
                        .font(.callout)
                    Text("Nothing on disk is renamed or moved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider()

                if candidates.isEmpty {
                    ContentUnavailableView {
                        Label("No Other Work Matches", systemImage: "magnifyingglass")
                    } description: {
                        Text("Search by any name the work is known by — the folder's, or the one a metadata source gave it.")
                    }
                } else {
                    List(candidates, selection: $chosen) { item in
                        MergeTargetRow(
                            item: item,
                            metadataTitle: model.metadataByAnimeID[item.anime.id]?.title
                        )
                        .tag(item.anime.id)
                    }
                    .listStyle(.inset)
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search the Library"))
            .navigationTitle("Merge Into Another Work")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMerging ? "Merging…" : "Merge") {
                        guard let chosen, let target = model.library.first(where: { $0.anime.id == chosen })?.anime else { return }
                        isMerging = true
                        Task {
                            await model.merge(source, into: target)
                            isMerging = false
                            dismiss()
                        }
                    }
                    .disabled(chosen == nil || isMerging)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            // Nothing typed: the whole library, best match first. Prefilling
            // the field would hide every row that does not contain the
            // source's exact spelling, which is the one thing a near-duplicate
            // never does.
            chosen = candidates.first?.anime.id
        }
    }
}

private struct MergeTargetRow: View {
    let item: LibraryAnime
    let metadataTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metadataTitle ?? item.anime.title)
            HStack(spacing: 6) {
                if metadataTitle != nil, metadataTitle != item.anime.title {
                    Text(item.anime.title)
                    Text(verbatim: "·")
                }
                Text("\(item.episodeCount) episode(s)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// What the providers noticed: one subject id on two library rows.
///
/// Shown rather than acted on. The evidence is strong — a subject landing
/// twice does not depend on how anybody spells anything — and it is still a
/// provider's answer about two works, either of which it can have wrong, so
/// the merge is the viewer's move. The provider and the id are both on screen
/// because "Bangumi 622288" is checkable and "these look the same" is not.
struct DuplicateWorksBanner: View {
    @EnvironmentObject private var model: AppModel
    let group: DuplicateWorkDetector.Group

    private var evidence: String {
        group.evidence
            .map { "\($0.provider.displayName) \($0.externalID)" }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(group.works.count) cards look like one work")
                    .font(.headline)
                Text(group.works.map(\.title).joined(separator: " · "))
                    .font(.callout)
                Text("Matched to the same entry: \(evidence)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Merge Into “\(group.primary.title)”") {
                    Task { await model.mergeDuplicateGroup(group) }
                }
                .buttonStyle(.borderedProminent)
                Button("Not the Same") { model.dismissDuplicateGroup(group) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
