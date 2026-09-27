import AnimeGodCore
import SwiftUI

/// How the grid is ordered.
enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case title
    case added
    case score

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: String(localized: "Name")
        case .added: String(localized: "Recently Added")
        case .score: String(localized: "Rating")
        }
    }

    static let storageKey = "library.sortOrder"
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    /// Observed here rather than through AppModel: download progress ticks
    /// once a second, and only this screen and the sidebar badge show it.
    @ObservedObject var downloads: TorrentDownloadManager
    @ObservedObject var subscriptions: TorrentSubscriptionManager
    @State private var searchText = ""
    @AppStorage(LibrarySortOrder.storageKey) private var sortOrder: LibrarySortOrder = .title

    /// The name shown on the card, which is the name the grid is ordered by.
    ///
    /// The two used to disagree: the order came from `sortTitle`, which is the
    /// folder's name — usually romaji — while the card showed the title the
    /// metadata gave it, usually Chinese. The grid was in a perfectly good
    /// order that was invisible on screen.
    private func displayTitle(_ item: LibraryAnime) -> String {
        model.metadataByAnimeID[item.anime.id]?.title ?? item.anime.title
    }

    /// What the providers think of it, averaged over the ones that answered.
    /// Both report out of ten, so the two are directly comparable.
    private func averageScore(_ item: LibraryAnime) -> Double? {
        let scores = (model.metadataSourcesByAnimeID[item.anime.id] ?? []).compactMap(\.score)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private var filtered: [LibraryAnime] {
        let matching = searchText.isEmpty ? model.library : model.library.filter { item in
            // Searching by either name, since either one may be the one the
            // user remembers.
            item.anime.title.localizedCaseInsensitiveContains(searchText)
                || displayTitle(item).localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case .title:
            return matching.sorted { isBefore(displayTitle($0), displayTitle($1)) }
        case .added:
            return matching.sorted { $0.anime.createdAt > $1.anime.createdAt }
        case .score:
            // Unrated titles go last rather than sorting as zero, which would
            // bury everything the providers have not been asked about yet.
            return matching.sorted { lhs, rhs in
                switch (averageScore(lhs), averageScore(rhs)) {
                case let (left?, right?):
                    return left != right
                        ? left > right
                        : displayTitle(lhs).localizedStandardCompare(displayTitle(rhs)) == .orderedAscending
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil):
                    return isBefore(displayTitle(lhs), displayTitle(rhs))
                }
            }
        }
    }

    /// Alphabetical, with Latin and numeric titles ahead of the rest.
    ///
    /// `localizedStandardCompare` in a Chinese locale orders Han by pinyin,
    /// which is right — but it also puts every Latin title *after* every
    /// Chinese one, so a library of thirty Chinese titles ends with the one
    /// called "BanG Dream!" and reads like the sort gave up at the end.
    private func isBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = Self.isLatinLeading(lhs), right = Self.isLatinLeading(rhs)
        guard left == right else { return left }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func isLatinLeading(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first(where: { $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) })
        else { return false }
        return first.value < 0x2E80
    }

    /// Downloads that are not in the library yet, so a title being fetched is
    /// visible here rather than only under Downloads.
    private var pendingDownloads: [TorrentDownloadItem] {
        let libraryIDs = Set(model.library.map(\.anime.id))
        return downloads.items.filter { item in
            guard !item.isComplete else { return false }
            guard let animeID = item.record.animeID else { return true }
            return !libraryIDs.contains(animeID)
        }
    }

    /// The same downloads grouped by the work they belong to: a season
    /// started as a set is one card here, not twelve, because twelve cards
    /// for one show is not what "downloading" looks like to a viewer.
    ///
    /// The grouping key comes from the download manager, which keys on the
    /// folder the episodes share. Keying on the series title read off each
    /// release name — as this did — split a season apart whenever one
    /// episode's name parsed a little differently from its siblings, which for
    /// the all-bracket fansub styles was every episode.
    private var incoming: [IncomingWork] {
        var order: [String] = []
        var grouped: [String: [TorrentDownloadItem]] = [:]
        for item in pendingDownloads {
            let key = downloads.seriesKey(of: item)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.compactMap { key -> IncomingWork? in
            guard let items = grouped[key], let first = items.first else { return nil }
            let workKey = first.record.folderName
                ?? TorrentDownloadFolder.sharedSeriesTitle(of: items.map(\.title))
            // A work matched while it downloads has a real anime row, so its
            // cover and page come from the library like any other card's.
            let animeID = first.record.animeID
            let anime = animeID.flatMap { model.incomingAnime[$0] }
            let posters = animeID.map { model.posterCandidates(for: $0) } ?? []
            let matched = workKey.flatMap { model.incomingMatches[$0] }
            return IncomingWork(
                id: key,
                workKey: workKey,
                title: animeID.flatMap { model.metadataByAnimeID[$0]?.title }
                    ?? anime?.title
                    ?? first.record.animeTitle
                    ?? matched?.title
                    ?? workKey
                    ?? first.title,
                posterURLs: posters.isEmpty ? [matched?.posterURL].compactMap { $0 } : posters,
                anime: anime,
                items: items
            )
        }
        .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Anime rows that downloads point at but the library has no files for
    /// yet, so their cards can open after a relaunch too.
    private var incomingAnimeIDs: [UUID] {
        Array(Set(pendingDownloads.compactMap(\.record.animeID))).sorted { $0.uuidString < $1.uuidString }
    }

    /// The works being downloaded, for the metadata lookup that gives their
    /// cards a cover before a single file has landed.
    private var incomingSeriesTitles: [String] {
        Array(Set(pendingDownloads.compactMap { item in
            item.record.folderName ?? TorrentDownloadFolder.sharedSeriesTitle(of: [item.title])
        })).sorted()
    }

    /// Progress to draw on a library card for a title still downloading.
    private func downloadProgress(for animeID: UUID) -> Double? {
        let active = downloads.items.filter { $0.record.animeID == animeID && !$0.isComplete }
        guard !active.isEmpty else { return nil }
        return active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    /// What the subscription mark in the poster's corner should say, or nil
    /// when this title is not followed.
    private func subscriptionState(for animeID: UUID) -> SubscriptionBadgeState? {
        guard subscriptions.subscription(for: animeID) != nil else { return nil }
        let automatic = downloads.items.filter { $0.record.animeID == animeID && $0.record.isAutomatic }
        let running = automatic.filter { !$0.isComplete }
        if !running.isEmpty {
            return .downloading(running.map(\.progress).reduce(0, +) / Double(running.count))
        }
        if downloads.hasUnseenAutomaticDownload(animeID: animeID) { return .ready }
        return .following
    }

    /// Matched works have a real page; an unmatched one opens a page of its
    /// own rather than being the one card on this screen that does nothing.
    @ViewBuilder
    private func incomingCard(_ work: IncomingWork) -> some View {
        if let anime = work.anime {
            NavigationLink(value: anime) {
                DownloadingCard(work: work, subscriptionState: subscriptionState(for: anime.id))
            }
            .buttonStyle(.plain)
        } else if let key = work.workKey {
            NavigationLink(value: IncomingWorkRoute(key: key, title: work.title)) {
                DownloadingCard(work: work, subscriptionState: nil)
            }
            .buttonStyle(.plain)
        } else {
            DownloadingCard(work: work, subscriptionState: nil)
        }
    }

    private func libraryCard(_ item: LibraryAnime) -> some View {
        NavigationLink(value: item.anime) {
            AnimeCard(
                item: item,
                title: model.metadataByAnimeID[item.anime.id]?.title,
                score: sortOrder == .score ? averageScore(item) : nil,
                posterURLs: model.posterCandidates(for: item.anime.id),
                downloadProgress: downloadProgress(for: item.anime.id),
                subscriptionState: subscriptionState(for: item.anime.id)
            )
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Group {
            if model.library.isEmpty && incoming.isEmpty {
                ContentUnavailableView {
                    Label("No Anime Yet", systemImage: "film.stack")
                } description: {
                    Text("Add a folder to turn local video files into an anime library.")
                } actions: {
                    Button("Add Anime Folder…") { model.chooseLibraryRoot() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 24) {
                        ForEach(incoming) { work in incomingCard(work) }
                        ForEach(filtered) { item in libraryCard(item) }
                    }
                    .padding(24)
                }
                .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0, downloads: model.downloads, subscriptions: model.subscriptions) }
                .navigationDestination(for: IncomingWorkRoute.self) { route in
                    DownloadingWorkView(downloads: downloads, route: route)
                }
            }
        }
        .navigationTitle("All Anime")
        .toolbar {
            ToolbarItem {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .help("Order the grid by name, by when it was added, or by the average of the ratings its sources gave it")
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search library")
        .task(id: incomingSeriesTitles) {
            await model.resolveIncomingMatches(seriesTitles: incomingSeriesTitles)
        }
        .task(id: incomingAnimeIDs) {
            await model.loadIncomingAnime(ids: incomingAnimeIDs)
        }
    }
}

private struct AnimeCard: View {
    let item: LibraryAnime
    let title: String?
    /// Shown while the grid is ordered by rating, so the order is legible
    /// rather than something to take on trust.
    var score: Double?
    let posterURLs: [URL]
    /// Non-nil while an episode of this title is downloading.
    var downloadProgress: Double?
    /// Non-nil while this title is followed by a subscription.
    var subscriptionState: SubscriptionBadgeState?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterView(urls: posterURLs, height: 380)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if let downloadProgress {
                        DownloadRing(progress: downloadProgress)
                            .frame(width: 30, height: 30)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let subscriptionState {
                        SubscriptionBadge(state: subscriptionState)
                            .padding(8)
                    }
                }
            Text(title ?? item.anime.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("\(item.episodeCount) episodes")
                if let score {
                    Label(String(format: "%.1f", score), systemImage: "star.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}


/// One work being downloaded: every episode of it that is still running,
/// under the name and cover the metadata lookup found for it.
struct IncomingWork: Identifiable {
    let id: String
    /// The folder its episodes share — the key the match is filed under and
    /// the route its own page is opened with. Nil only for a lone download
    /// whose name nothing could be read out of.
    let workKey: String?
    let title: String
    let posterURLs: [URL]
    /// Set once the work has been matched, which is what makes the card
    /// open the anime's own page.
    let anime: Anime?
    let items: [TorrentDownloadItem]

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return items.map(\.progress).reduce(0, +) / Double(items.count)
    }

    /// Episodes of this work that have landed, out of the ones running.
    var finishedCount: Int { items.filter { $0.progress >= 1 }.count }
}

/// A title being downloaded, shown beside the library so it is visible from
/// the moment it starts rather than only once it lands on disk.
private struct DownloadingCard: View {
    let work: IncomingWork
    let subscriptionState: SubscriptionBadgeState?

    private var statusText: String {
        guard work.items.count > 1 else { return work.items.first?.statusText ?? "" }
        return String(localized: "\(work.finishedCount) of \(work.items.count) episodes")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if !work.posterURLs.isEmpty {
                    PosterView(urls: work.posterURLs, height: 380)
                        .overlay(alignment: .topTrailing) {
                            DownloadRing(progress: work.progress)
                                .frame(width: 30, height: 30)
                                .padding(8)
                        }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                        DownloadRing(progress: work.progress)
                            .frame(width: 56, height: 56)
                    }
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if let subscriptionState {
                    SubscriptionBadge(state: subscriptionState)
                        .padding(8)
                }
            }

            Text(work.title)
                .font(.headline)
                .lineLimit(2)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(work.items.map(\.title).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(work.title), downloading, \(Int(work.progress * 100)) percent")
    }
}

/// The App Store-style ring: fills clockwise as the download completes.
private struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.35))
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 3)
                .padding(3)
            Circle()
                .trim(from: 0, to: max(0.01, min(progress, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .animation(.easeInOut(duration: 0.4), value: progress)
            Text(verbatim: "\(Int(progress * 100))")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
