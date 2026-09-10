import AnimeGodCore
import SwiftUI

struct AnimeDetailView: View {
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    @State private var episodes: [EpisodeMedia] = []
    @State private var showingMatch = false
    @State private var showingProfile = false
    @State private var communityKind: CommunityPostKind = .review
    @State private var communityProvider: MetadataProviderID = .bangumi
    @State private var expandedCategories: Set<EpisodeCategory> = [.main]

    private var metadata: AnimeMetadata? { model.metadataByAnimeID[anime.id] }
    private var metadataSources: [AnimeMetadata] { model.metadataSourcesByAnimeID[anime.id] ?? [] }
    /// Prefer a provider-reported type; fall back to the local classification.
    private var resolvedKind: AnimeKind? {
        metadataSources.compactMap(\.kind).first ?? anime.kind
    }
    private var communityProviders: [MetadataProviderID] {
        metadataSources.map(\.provider).filter { $0 != .myAnimeList }
    }
    private var communityPosts: [CommunityPost] {
        (model.communityByAnimeID[anime.id] ?? []).filter {
            $0.kind == communityKind && $0.provider == communityProvider
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                hero
                episodeSection
                if metadata != nil { communitySection }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(metadata?.title ?? anime.title)
        .toolbar {
            Button { showingProfile = true } label: {
                Label("Edit My Entry", systemImage: "person.crop.circle.badge.checkmark")
            }
            Button { showingMatch = true } label: {
                Label(metadata == nil ? "Match Metadata" : "Change Match", systemImage: "link.badge.plus")
            }
        }
        .sheet(isPresented: $showingMatch) {
            MetadataMatchView(anime: anime)
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 520)
        }
        .sheet(isPresented: $showingProfile) {
            AnimeProfileEditor(anime: anime, profile: model.profile(for: anime.id))
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 650)
        }
        .task {
            episodes = await model.episodes(for: anime)
            await model.loadCommunity(for: anime)
            if !communityProviders.contains(communityProvider), let first = communityProviders.first {
                communityProvider = first
            }
        }
    }

    @ViewBuilder
    private var hero: some View {
        HStack(alignment: .top, spacing: 24) {
            PosterView(urls: model.posterCandidates(for: anime.id))
                .frame(width: 190, height: 285)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(metadata?.title ?? anime.title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .textSelection(.enabled)
                    if let originalTitle = metadata?.originalTitle,
                       originalTitle != metadata?.title {
                        Text(originalTitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if let metadata {
                    sourceRatings

                    Text(metadata.summary.isEmpty ? "No synopsis is available." : metadata.summary)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: 700, alignment: .leading)

                    Text("Synopsis and artwork from \(metadata.provider.displayName)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ContentUnavailableView {
                        Label("No Online Metadata", systemImage: "photo.badge.plus")
                    } description: {
                        Text("Match this local title with Bangumi or AniList to add artwork, synopsis, sourced ratings, and community reviews.")
                    } actions: {
                        Button("Find Metadata…") { showingMatch = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: 580, alignment: .leading)
                }

                if let first = episodes.first {
                    Button { Task { await model.play(first) } } label: {
                        Label(first.progress == nil ? "Play First Episode" : "Resume Watching", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                let profile = model.profile(for: anime.id)
                HStack(spacing: 12) {
                    Label(profile.status.displayName, systemImage: "person.text.rectangle")
                    if let score = profile.score {
                        Label("My Score \(String(format: "%.1f", score))", systemImage: "star.fill")
                    }
                    if let ranking = profile.ranking { Text("My Rank #\(ranking)") }
                    if profile.isFavorite { Label("Favorite", systemImage: "heart.fill").foregroundStyle(.pink) }
                    Button("Edit…") { showingProfile = true }.buttonStyle(.link)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceRatings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let kind = resolvedKind, kind != .unknown {
                    Text(kind.displayName)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if let airDate = metadata?.airDate { Text(airDate) }
                if let platform = metadata?.platform { Text(platform) }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(metadataSources) { source in
                    Group {
                        if let url = source.sourceURL {
                            Link(destination: url) { sourceRatingLabel(source) }
                        } else {
                            sourceRatingLabel(source)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Auto-guessed links carry their confidence so a wrong match is
            // easy to spot and fix via "Change Match".
            let autoMatches = metadataSources.compactMap { source -> (String, Double)? in
                guard let link = model.matchLinksByAnimeID[anime.id]?[source.provider], !link.isManual, link.confidence < 0.94
                else { return nil }
                return (source.provider.displayName, link.confidence)
            }
            if !autoMatches.isEmpty {
                Text(autoMatches.map { "\($0.0) 自动匹配 \(Int(($0.1 * 100).rounded()))%——有误请点右上角 Change Match" }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sourceRatingLabel(_ source: AnimeMetadata) -> some View {
        HStack(spacing: 6) {
            Text(source.provider.displayName).fontWeight(.semibold)
            if let score = source.score {
                Label(String(format: "%.1f", score), systemImage: "star.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("No score").foregroundStyle(.secondary)
            }
            if let rank = source.rank { Text("#\(rank)").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Episodes grouped by category (正片 / SP / 音乐 / 预告 / 其他) while
    /// keeping the sort order inside each group.
    private var episodeSections: [(category: EpisodeCategory, items: [EpisodeMedia])] {
        var grouped: [EpisodeCategory: [EpisodeMedia]] = [:]
        for item in episodes {
            grouped[item.episode.kind.category, default: []].append(item)
        }
        return EpisodeCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodes").font(.title2.bold())

            if episodes.isEmpty {
                ContentUnavailableView("No Episodes", systemImage: "film").frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(episodeSections, id: \.category) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            // Specials and extras stay tucked away until the
                            // user opens them; the main episodes stay visible.
                            Button {
                                if expandedCategories.contains(section.category) {
                                    expandedCategories.remove(section.category)
                                } else {
                                    expandedCategories.insert(section.category)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .rotationEffect(.degrees(expandedCategories.contains(section.category) ? 90 : 0))
                                    Text(section.category.displayName).font(.headline)
                                    Text("\(section.items.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expandedCategories.contains(section.category) {
                                episodeRows(section.items)
                            }
                        }
                    }
                }
            }
        }
    }

    private func episodeRows(_ items: [EpisodeMedia]) -> some View {
        LazyVStack(spacing: 1) {
            ForEach(items) { item in
                Button { Task { await model.play(item) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.progress?.isWatched == true ? "checkmark.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(item.progress?.isWatched == true ? Color.green : Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episodeLabel(item.episode)).font(.headline)
                            Text(item.mediaFile.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let progress = item.progress, !progress.isWatched {
                            ProgressView(value: progress.completion)
                                .frame(width: 90)
                                .accessibilityLabel("Playback progress")
                        }
                        Text((item.progress?.position ?? 0) > 0 ? "Resume" : "Play")
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 50)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Community").font(.title2.bold())
                Spacer()
                Picker("Community section", selection: $communityKind) {
                    Text("Reviews").tag(CommunityPostKind.review)
                    Text("Discussions").tag(CommunityPostKind.discussion)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                if communityProviders.count > 1 {
                    Picker("Source", selection: $communityProvider) {
                        ForEach(communityProviders, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .frame(width: 140)
                }
                if canTranslateCommunity {
                    Button {
                        Task { await model.translateCommunity(for: anime, posts: communityPosts) }
                    } label: {
                        if model.translation.isTranslating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Translate", systemImage: "translate")
                        }
                    }
                    .disabled(model.translation.isTranslating)
                    .help("Translate these \(communityKind == .review ? "reviews" : "discussions") with the configured translation service")
                }
                Button { Task { await model.loadCommunity(for: anime, provider: communityProvider, refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh \(communityProvider.displayName) community content")
            }

            if !model.translation.isConfigured, communityPosts.contains(where: { $0.originalLanguage != nil }) {
                Label("Configure a translation provider in Settings to read foreign-language posts in Chinese without losing the original text.", systemImage: "translate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if communityPosts.isEmpty {
                ContentUnavailableView(
                    communityKind == .review ? "No Reviews" : "No Discussions",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(communityPosts) { post in
                    communityRow(post)
                }
            }
        }
        .onChange(of: communityProviders) { _, providers in
            if !providers.contains(communityProvider), let first = providers.first {
                communityProvider = first
            }
        }
    }

    private var canTranslateCommunity: Bool {
        model.translation.isConfigured
            && communityPosts.contains { $0.translatedBody == nil && ($0.body != nil || !$0.title.isEmpty) }
    }

    @ViewBuilder
    private func communityRow(_ post: CommunityPost) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Link(destination: post.url) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(post.title).font(.headline).foregroundStyle(.primary)
                        Spacer()
                        if post.replyCount > 0 {
                            Label("\(post.replyCount)", systemImage: "bubble.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let translatedTitle = post.translatedTitle, translatedTitle != post.title {
                        Text(translatedTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let summary = post.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if let translated = post.translatedBody, !translated.isEmpty {
                        Text(translated)
                            .font(.callout)
                            .lineLimit(6)
                            .padding(.top, 2)
                    }
                    HStack {
                        Text(post.author)
                        Text("·")
                        Text(post.provider.displayName)
                        if post.translatedBody != nil { Text("· Translated") }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            if model.translation.isConfigured, post.translatedBody == nil, post.body != nil {
                Button {
                    Task { await model.translateCommunity(for: anime, posts: [post]) }
                } label: {
                    Image(systemName: "translate")
                }
                .buttonStyle(.borderless)
                .disabled(model.translation.isTranslating)
                .help("Translate this post")
            }
        }
    }

    private func episodeLabel(_ episode: Episode) -> String {
        switch episode.kind {
        case .opening: "Creditless Opening"
        case .ending: "Creditless Ending"
        case .music: "Music Video\(episode.numberText.map { " \($0)" } ?? "")"
        case .trailer: "Trailer"
        case .special: "Special \(episode.numberText ?? "")"
        case .extra: "Extra"
        case .regular: episode.numberText.map { "Episode \($0)" } ?? "Movie / Episode"
        }
    }
}

/// Poster artwork with source fallback and a persistent cache. When the
/// preferred metadata source's CDN is unreachable, the next source's poster
/// is tried instead of showing a broken image.
struct PosterView: View {
    private let urls: [URL]
    @State private var image: NSImage?
    @State private var attempt = 0

    init(url: URL?) {
        urls = [url].compactMap { $0 }
    }

    init(urls: [URL]) {
        var seen = Set<URL>()
        self.urls = urls.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if attempt < urls.count {
                if urls.isEmpty {
                    Image(systemName: "film.stack")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: TaskKey(urls: urls, attempt: attempt)) {
            guard attempt < urls.count else { return }
            if let data = await ArtworkCache.shared.data(for: urls[attempt]),
               let loaded = NSImage(data: data) {
                image = loaded
            } else {
                attempt += 1
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .accessibilityLabel("Anime poster")
    }

    private struct TaskKey: Equatable {
        let urls: [URL]
        let attempt: Int
    }
}

private struct MetadataMatchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let anime: Anime
    @State private var query: String
    @State private var candidates: [AnimeMetadataCandidate] = []
    @State private var isSearching = false
    @State private var matchingID: String?
    @State private var provider: MetadataProviderID = .bangumi

    init(anime: Anime) {
        self.anime = anime
        _query = State(initialValue: anime.title)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && candidates.isEmpty {
                    ProgressView("Searching \(provider.displayName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(candidates) { candidate in
                        Button { Task { await select(candidate) } } label: {
                            HStack(spacing: 14) {
                                PosterView(url: candidate.posterURL).frame(width: 54, height: 81)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(candidate.title).font(.headline)
                                    if candidate.originalTitle != candidate.title {
                                        Text(candidate.originalTitle).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 10) {
                                        if let date = candidate.airDate { Text(date) }
                                        if let score = candidate.score { Label(String(format: "%.1f", score), systemImage: "star.fill") }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if matchingID == candidate.id { ProgressView().controlSize(.small) }
                                else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(matchingID != nil)
                    }
                }
            }
            .navigationTitle("Match “\(anime.title)”")
            .searchable(text: $query, prompt: "Anime title")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("Source", selection: $provider) {
                        Text("Bangumi").tag(MetadataProviderID.bangumi)
                        Text("AniList").tag(MetadataProviderID.anilist)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .onChange(of: provider) { _, _ in Task { await search() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Search") { Task { await search() } }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }
            }
            .task { await search() }
        }
    }

    private func search() async {
        isSearching = true
        candidates = []
        candidates = await model.searchMetadata(
            query.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider
        )
        isSearching = false
    }

    private func select(_ candidate: AnimeMetadataCandidate) async {
        matchingID = candidate.id
        if await model.match(anime, to: candidate) { dismiss() }
        matchingID = nil
    }
}
