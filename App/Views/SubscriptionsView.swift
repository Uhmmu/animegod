import AnimeGodCore
import SwiftUI

/// Standing rules that download new episodes on their own, and a log of what
/// they have done — automatic downloading is only comfortable when it is
/// easy to see and easy to stop.
struct SubscriptionsView: View {
    @ObservedObject var subscriptions: TorrentSubscriptionManager
    @State private var editing: TorrentSubscription?
    @State private var isCreating = false
    @State private var confirmingRemoval: TorrentSubscription?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if let error = subscriptions.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { subscriptions.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
            content
        }
        .navigationTitle("Subscriptions")
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
        .alert(
            "Remove this subscription?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { subscription in
            Button("Remove", role: .destructive) {
                Task { await subscriptions.remove(subscription) }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { subscription in
            Text("“\(subscription.title)” will stop checking for new episodes. Downloads it already started are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(subscriptions.subscriptions.isEmpty
                 ? "No subscriptions"
                 : "\(subscriptions.enabledCount) of \(subscriptions.subscriptions.count) active")
                .font(.callout)
                .foregroundStyle(.secondary)
            if subscriptions.isChecking {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Check Now") {
                Task { await subscriptions.checkAll() }
            }
            .disabled(subscriptions.isChecking || subscriptions.enabledCount == 0)
            Button {
                isCreating = true
            } label: {
                Label("New Subscription", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if subscriptions.subscriptions.isEmpty {
            ContentUnavailableView {
                Label("No Subscriptions", systemImage: "bell")
            } description: {
                Text("A subscription watches the anime indexes for new episodes of one title and downloads the ones matching your rule — a fansub, a resolution, a subtitle language. The quickest way to make one is from Find Releases, once the filters show exactly what you want.")
            } actions: {
                Button("New Subscription") { isCreating = true }
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(subscriptions.subscriptions) { subscription in
                        row(subscription)
                    }
                }
                if !subscriptions.activity.isEmpty {
                    Section("Recent Activity") {
                        ForEach(subscriptions.activity) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.date, format: .dateTime.hour().minute())
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ subscription: TorrentSubscription) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { subscription.isEnabled },
                set: { isOn in Task { await subscriptions.setEnabled(isOn, for: subscription) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.title)
                    .fontWeight(.medium)
                    .foregroundStyle(subscription.isEnabled ? .primary : .secondary)
                Text(subscription.ruleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusLine(subscription))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Check") { Task { await subscriptions.check(subscription, isManual: true) } }
                .controlSize(.small)
                .disabled(subscriptions.isChecking)
            Button { editing = subscription } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button(role: .destructive) { confirmingRemoval = subscription } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func statusLine(_ subscription: TorrentSubscription) -> String {
        var parts = [String(localized: "Searches: \(subscription.queries.joined(separator: ", "))")]
        if let checked = subscription.lastCheckedAt {
            parts.append(String(localized: "checked \(checked.formatted(.relative(presentation: .numeric)))"))
        } else {
            parts.append(String(localized: "not checked yet"))
        }
        if let matched = subscription.lastMatchedAt {
            parts.append(String(localized: "last match \(matched.formatted(.relative(presentation: .numeric)))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Create or edit one rule.
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
                    Text("Every name is searched together, so a fansub that uses the Chinese title and one that uses the romaji are both found.")
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
                    Text("A subscription normally follows what appears from now on. Turning these on makes the first check fetch a season pack, or every episode already out — for a running show that can be dozens of downloads at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Check automatically every 30 minutes", isOn: $draft.isEnabled)
                    Text("Matching episodes download on their own — one release per episode, never one already in your library or downloaded before. Everything it does is listed under Recent Activity.")
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
