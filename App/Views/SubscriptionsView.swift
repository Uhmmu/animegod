import AnimeGodCore
import SwiftUI

/// The shows AnimeGod is following, and what following them has done.
///
/// This page used to be a form: a list of hand-written rules, each one a
/// fansub name and a resolution typed in by hand. It is now the *library* of
/// followed shows — poster, next episode, what arrived, what needs a
/// decision — because that is what a subscription looks like from the
/// outside. Writing a rule by hand is still possible, from the button in the
/// corner, for a show the search cannot find on its own.
struct SubscriptionsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var subscriptions: TorrentSubscriptionManager
    @ObservedObject var downloads: TorrentDownloadManager
    @State private var editing: TorrentSubscription?
    @State private var isCreating = false
    @State private var confirmingRemoval: TorrentSubscription?
    @State private var showingActivity = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if let error = subscriptions.errorMessage {
                notice(error, icon: "exclamationmark.triangle.fill", tint: .red) {
                    subscriptions.errorMessage = nil
                }
            }
            if let status = subscriptions.statusMessage {
                notice(status, icon: "info.circle", tint: .secondary) {
                    subscriptions.statusMessage = nil
                }
            }
            Divider()
            content
        }
        .navigationTitle("Subscriptions")
        .navigationDestination(for: Anime.self) {
            AnimeDetailView(anime: $0, downloads: downloads, subscriptions: subscriptions)
        }
        .sheet(isPresented: $isCreating) {
            SubscriptionEditor(subscription: TorrentSubscription(title: "", queries: [])) { saved in
                Task { await subscriptions.save(saved) }
            }
        }
        .sheet(item: $editing) { subscription in
            SubscriptionEditor(subscription: subscription) { saved in
                Task { await subscriptions.save(saved) }
            }
        }
        .sheet(isPresented: $showingActivity) {
            ActivityLogView(entries: subscriptions.activity)
        }
        .alert(
            "Stop following this anime?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { subscription in
            Button("Stop Following", role: .destructive) {
                Task { await subscriptions.remove(subscription) }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { subscription in
            Text("“\(subscription.title)” will stop checking for new episodes. Downloads it already started are kept.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(subscriptions.subscriptions.isEmpty
                 ? "Nothing followed yet"
                 : "\(subscriptions.followingCount) waiting for new episodes · \(subscriptions.subscriptions.count) followed")
                .font(.callout)
                .foregroundStyle(.secondary)
            if subscriptions.isChecking {
                ProgressView().controlSize(.small)
            }
            Spacer()

            Picker("Check every", selection: $subscriptions.checkIntervalHours) {
                ForEach(TorrentSubscriptionManager.intervalChoices, id: \.self) { hours in
                    Text(Self.intervalLabel(hours)).tag(hours)
                }
            }
            .fixedSize()
            .help("How often the indexes are searched for a new episode of each followed show")

            Button("Check Now") {
                Task { await subscriptions.checkAll() }
            }
            .disabled(subscriptions.isChecking || subscriptions.followingCount == 0)

            if !subscriptions.activity.isEmpty {
                Button {
                    showingActivity = true
                } label: {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                }
                .help("Everything the subscriptions have done this session")
            }

            // The hand-written rule stays available, in the corner, for a show
            // whose releases the search cannot line up on its own.
            Button {
                isCreating = true
            } label: {
                Label("Add by Hand", systemImage: "plus")
            }
            .help("Write a rule yourself: a title to search, a fansub, a resolution")
        }
    }

    static func intervalLabel(_ hours: Int) -> String {
        if hours >= 24, hours % 24 == 0 {
            let days = hours / 24
            return days == 1 ? String(localized: "Every day") : String(localized: "Every \(days) days")
        }
        return hours == 1 ? String(localized: "Every hour") : String(localized: "Every \(hours) hours")
    }

    @ViewBuilder
    private func notice(_ text: String, icon: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if subscriptions.subscriptions.isEmpty {
            ContentUnavailableView {
                Label("Nothing Followed Yet", systemImage: "bell")
            } description: {
                Text("Search a season that is still airing under Find Releases, switch to Episode Sets, and press Subscribe. What is out downloads now; every episode after it arrives on its own, from the same fansub, into the same folder.")
            } actions: {
                Button("Add by Hand") { isCreating = true }
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(subscriptions.subscriptions) { subscription in
                        SubscriptionCard(
                            subscription: subscription,
                            subscriptions: subscriptions,
                            downloads: downloads,
                            edit: { editing = subscription },
                            remove: { confirmingRemoval = subscription }
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}

/// One followed show: its poster, what it is waiting for, what arrived, and
/// anything that needs a decision.
private struct SubscriptionCard: View {
    @EnvironmentObject private var model: AppModel
    let subscription: TorrentSubscription
    @ObservedObject var subscriptions: TorrentSubscriptionManager
    @ObservedObject var downloads: TorrentDownloadManager
    let edit: () -> Void
    let remove: () -> Void

    /// The library row this follows, so the card can open the anime's page.
    private var anime: Anime? {
        guard let animeID = subscription.animeID else { return nil }
        return model.library.first { $0.anime.id == animeID }?.anime ?? model.incomingAnime[animeID]
    }

    private var posterURLs: [URL] {
        subscription.animeID.map { model.posterCandidates(for: $0) } ?? []
    }

    private var displayTitle: String {
        subscription.animeID.flatMap { model.metadataByAnimeID[$0]?.title } ?? subscription.title
    }

    /// Episodes this rule started, newest first — what following it produced.
    private var automaticDownloads: [TorrentDownloadItem] {
        downloads.items
            .filter { $0.record.subscriptionID == subscription.id }
            .sorted { $0.record.addedAt > $1.record.addedAt }
    }

    private var running: [TorrentDownloadItem] { automaticDownloads.filter { !$0.isComplete } }
    private var candidates: [TorrentSubscriptionCandidate] { subscriptions.candidates(for: subscription.id) }

    private var badgeState: SubscriptionBadgeState {
        if !running.isEmpty {
            return .downloading(running.map(\.progress).reduce(0, +) / Double(running.count))
        }
        if let animeID = subscription.animeID, downloads.hasUnseenAutomaticDownload(animeID: animeID) {
            return .ready
        }
        return .following
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                poster
                VStack(alignment: .leading, spacing: 6) {
                    titleRow
                    statusRow
                    Text(subscription.ruleSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(subscription.ruleSummary)
                    if !running.isEmpty { arrivingRow }
                }
                Spacer(minLength: 8)
                actions
            }
            .padding(12)

            if !candidates.isEmpty {
                Divider()
                confirmations
            }
            if !automaticDownloads.isEmpty {
                Divider()
                arrived
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
        .opacity(subscription.isEnabled ? 1 : 0.6)
    }

    @ViewBuilder
    private var poster: some View {
        Group {
            if posterURLs.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "bell")
                            .foregroundStyle(.secondary)
                    }
            } else {
                PosterView(urls: posterURLs, height: 96)
            }
        }
        .frame(width: 64, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            SubscriptionBadge(state: badgeState, height: 14)
                .padding(3)
        }
    }

    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: 6) {
            // Opening the anime from here is the point of the poster being
            // here: it is the same show, seen from the other side.
            if let anime {
                NavigationLink(value: anime) {
                    Text(displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                .buttonStyle(.link)
            } else {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)
            }
            if subscription.isSeasonComplete {
                Tag(text: String(localized: "Season complete"), tint: .secondary)
            } else if !subscription.isEnabled {
                Tag(text: String(localized: "Paused"), tint: .secondary)
            } else {
                Tag(text: String(localized: "Following"), tint: .accentColor)
            }
            if subscriptions.checkingID == subscription.id {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if subscription.isSeasonComplete {
                Text("Every episode of this season has been published")
            } else if let next = subscription.nextEpisode {
                if let due = subscription.estimatedNextEpisodeAt() {
                    Text("Waiting for EP \(TorrentEpisodeLabel.text(for: next)) · expected \(due.formatted(.relative(presentation: .named)))")
                        .help(String(localized: "Estimated from the \(intervalText) between the episodes published so far — \(due.formatted(date: .complete, time: .shortened))"))
                } else {
                    Text("Waiting for EP \(TorrentEpisodeLabel.text(for: next))")
                }
            } else {
                Text("Waiting for a new episode")
            }
            if let checked = subscription.lastCheckedAt {
                Text("· checked \(checked.formatted(.relative(presentation: .numeric)))")
                    .foregroundStyle(.tertiary)
            } else {
                Text("· not checked yet").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// "every 7 days", for the tooltip that explains the estimate.
    private var intervalText: String {
        guard let seconds = subscription.averageIntervalSeconds, seconds > 0 else {
            return String(localized: "gaps")
        }
        let days = seconds / 86_400
        return days >= 1
            ? String(localized: "\(Int(days.rounded())) days")
            : String(localized: "\(Int((seconds / 3600).rounded())) hours")
    }

    private var arrivingRow: some View {
        HStack(spacing: 8) {
            EpisodeProgressRing(progress: running.map(\.progress).reduce(0, +) / Double(running.count))
                .frame(width: 18, height: 18)
            Text(running.count == 1
                 ? String(localized: "\(running[0].episodeText.map { String(localized: "EP \($0)") } ?? running[0].title) is downloading")
                 : String(localized: "\(running.count) episodes are downloading"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Check") { Task { await subscriptions.check(subscription, isManual: true) } }
                .controlSize(.small)
                .disabled(subscriptions.isChecking || subscription.isSeasonComplete)
            Toggle("", isOn: Binding(
                get: { subscription.isEnabled },
                set: { isOn in Task { await subscriptions.setEnabled(isOn, for: subscription) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Pause or resume checking for new episodes")
            Button { edit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit what this rule accepts")
            Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Stop following")
        }
    }

    /// Episodes of the right show published by the wrong line. Taking one is a
    /// decision, not something to do unattended — hence this.
    private var confirmations: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                Text("\(candidates.count) releases need a look")
                    .font(.caption.weight(.medium))
                Text("— the right episode, but not from the fansub this season was started with")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ForEach(candidates) { candidate in
                HStack(spacing: 8) {
                    Text(candidate.episode.map { TorrentEpisodeLabel.text(for: $0) } ?? "–")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(candidate.title)
                        HStack(spacing: 5) {
                            Tag(text: candidate.reasonText, tint: .orange)
                            if let group = candidate.group { Tag(text: group, tint: .accentColor) }
                            if let resolution = candidate.resolution { Tag(text: resolution, tint: .blue) }
                            if let seeders = candidate.seeders {
                                Text("\(seeders) ↑")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(seeders == 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                            }
                            if let size = candidate.size {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .binary))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Download") { Task { await subscriptions.accept(candidate) } }
                        .controlSize(.small)
                    Button("Ignore") { Task { await subscriptions.dismiss(candidate) } }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .padding(.bottom, 6)
    }

    /// What following this show has actually brought in.
    private var arrived: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloaded by this subscription")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ForEach(automaticDownloads.prefix(6)) { item in
                HStack(spacing: 8) {
                    if item.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .frame(width: 18)
                    } else {
                        EpisodeProgressRing(progress: item.progress, isPaused: item.isPaused)
                            .frame(width: 18, height: 18)
                    }
                    Text(item.episodeText.map { String(localized: "EP \($0)") } ?? item.title)
                        .font(.callout)
                        .frame(width: 60, alignment: .leading)
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.title)
                    Spacer(minLength: 8)
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if automaticDownloads.count > 6 {
                Text("\(automaticDownloads.count - 6) more under Downloads")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
    }
}

/// Everything the rules have done this session, in one sheet rather than
/// taking up half the page.
private struct ActivityLogView: View {
    let entries: [TorrentSubscriptionManager.Activity]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(entry.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Subscription Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
    }
}

/// Create or edit one rule by hand.
struct SubscriptionEditor: View {
    @State private var draft: TorrentSubscription
    @State private var queryText: String
    @State private var includeText: String
    @State private var excludeText: String
    @State private var minimumEpisodeText: String
    @Environment(\.dismiss) private var dismiss
    let save: (TorrentSubscription) -> Void

    init(subscription: TorrentSubscription, save: @escaping (TorrentSubscription) -> Void) {
        _draft = State(initialValue: subscription)
        _queryText = State(initialValue: subscription.queries.joined(separator: ", "))
        _includeText = State(initialValue: subscription.includeKeywords.joined(separator: ", "))
        _excludeText = State(initialValue: subscription.excludeKeywords.joined(separator: ", "))
        _minimumEpisodeText = State(initialValue: subscription.minimumEpisode.map { String(Int($0)) } ?? "")
        self.save = save
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !TorrentSearchCoordinator.splitQueries(queryText).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Anime") {
                    TextField("Name", text: $draft.title, prompt: Text("Shown in the list"))
                    TextField("Search for", text: $queryText, prompt: Text("Separate aliases with commas"))
                    Text("Every name is searched together, so a fansub that uses the Chinese title and one that uses the romaji are both found. The episode being waited for is searched by number as well.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Only download releases that match") {
                    TextField("Fansub", text: Binding(
                        get: { draft.group ?? "" },
                        set: { draft.group = $0.trimmingCharacters(in: .whitespaces).nilIfBlank }
                    ), prompt: Text("Any fansub"))
                    Picker("Resolution", selection: Binding(
                        get: { draft.resolution ?? "" },
                        set: { draft.resolution = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Any").tag("")
                        ForEach(["2160p", "1080p", "720p", "480p"], id: \.self) { Text($0).tag($0) }
                    }
                    ForEach(TorrentSubtitleLanguage.allCases) { language in
                        Toggle(language.displayName, isOn: Binding(
                            get: { draft.subtitleLanguages.contains(language) },
                            set: { isOn in
                                if isOn { draft.subtitleLanguages.insert(language) } else { draft.subtitleLanguages.remove(language) }
                            }
                        ))
                    }
                    TextField("Title must contain", text: $includeText, prompt: Text("e.g. WebRip"))
                    TextField("Title must not contain", text: $excludeText, prompt: Text("e.g. Reseed, BDRip"))
                    TextField("Skip episodes up to", text: $minimumEpisodeText, prompt: Text("e.g. 6"))
                    Toggle("Also download batches", isOn: $draft.includesBatches)
                    Toggle("Also download episodes released before now", isOn: $draft.includesExistingReleases)
                    Text("A subscription normally follows what appears from now on. Turning these on makes the first check fetch a season pack, or every episode already out — for a running show that can be dozens of downloads at once. “Skip episodes up to” is the precise way to say where to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Where the episodes go") {
                    TextField("Folder", text: Binding(
                        get: { draft.folderName ?? "" },
                        set: { draft.folderName = $0.trimmingCharacters(in: .whitespaces).nilIfBlank }
                    ), prompt: Text("A folder of its own"))
                    Text("Episodes this rule downloads are put in this folder inside your download folder, beside the ones already there — a season stays one folder and one library entry. A rule made by subscribing to a set fills this in itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Check automatically", isOn: $draft.isEnabled)
                    Text("Matching episodes download on their own — one release per episode, never one already in your library or downloaded before, and always under the speed limit for automatic downloads in Settings. Anything that fits the show but not this rule is offered on this page instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.queries.isEmpty ? "New Subscription" : "Edit Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.queries = TorrentSearchCoordinator.splitQueries(queryText)
                        draft.includeKeywords = splitKeywords(includeText)
                        draft.excludeKeywords = splitKeywords(excludeText)
                        draft.minimumEpisode = Double(minimumEpisodeText.trimmingCharacters(in: .whitespaces))
                        save(draft)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private func splitKeywords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
