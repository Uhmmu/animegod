import AnimeGodCore
import AppKit
import SwiftUI

/// In-player danmaku manager: browse the comments just before the playhead
/// or search the whole episode, jump to a comment, and block its text or
/// sender. It lives inside the player window, so it reports text-field
/// focus upward and the player suspends its single-key shortcuts while the
/// user types.
struct DanmakuManagerPanel: View {
    @ObservedObject var session: DanmakuSession
    @ObservedObject var preferences: DanmakuPreferences
    let position: Double
    let seek: (Double) -> Void
    let onTypingChange: (Bool) -> Void
    let onClose: () -> Void

    private enum Tab: Hashable {
        case nearby, search, blocked
    }

    /// Media seconds of history shown in the Nearby tab.
    private static let nearbyWindow: Double = 30
    private static let rowLimit = 300

    @State private var tab: Tab = .nearby
    @State private var query = ""
    @State private var matches: [DanmakuComment] = []
    @FocusState private var searchFocused: Bool
    @State private var keywordFocused = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) {
                Text("Nearby").tag(Tab.nearby)
                Text("Search").tag(Tab.search)
                Text("Blocked").tag(Tab.blocked)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            switch tab {
            case .nearby: nearbyView
            case .search: searchView
            case .blocked: blockedView
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .playerSurface()
        .onChange(of: searchFocused) { _, _ in reportTyping() }
        .onChange(of: keywordFocused) { _, _ in reportTyping() }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: session.comments) { _, _ in runSearch() }
        .onDisappear { onTypingChange(false) }
    }

    private func reportTyping() {
        onTypingChange(searchFocused || keywordFocused)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Danmaku Manager").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (M)")
        }
        .padding(12)
    }

    private var summary: String {
        let snapshot = session.renderer
        guard snapshot.totalCount > 0 else { return String(localized: "No comments loaded") }
        return String(localized: "\(snapshot.loadedCount.formatted()) of \(snapshot.totalCount.formatted()) shown · \(snapshot.mergedCount.formatted()) merged · \(snapshot.hiddenCount.formatted()) hidden")
    }

    // MARK: - Nearby

    private var nearbyView: some View {
        commentList(
            nearbyComments(),
            empty: session.comments.isEmpty
                ? String(localized: "No danmaku loaded for this episode.")
                : String(localized: "No comments in the last \(Int(Self.nearbyWindow)) seconds."),
            footer: String(localized: "Newest first. Click to jump, right-click to block.")
        )
    }

    /// Comments from the last `nearbyWindow` media seconds, newest first.
    private func nearbyComments() -> [DanmakuComment] {
        let comments = session.comments
        let now = position - preferences.settings.timeOffset
        // First index whose time is after `now`.
        var low = 0
        var high = comments.count
        while low < high {
            let mid = (low + high) / 2
            if comments[mid].time <= now { low = mid + 1 } else { high = mid }
        }
        var result: [DanmakuComment] = []
        var index = low - 1
        while index >= 0, comments[index].time >= now - Self.nearbyWindow, result.count < Self.rowLimit {
            result.append(comments[index])
            index -= 1
        }
        return result
    }

    // MARK: - Search

    private var searchView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search comments", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if trimmedQuery.isEmpty {
                placeholder(String(localized: "Search every comment in this episode."))
            } else {
                commentList(
                    Array(matches.prefix(Self.rowLimit)),
                    empty: String(localized: "No comments contain “\(trimmedQuery)”."),
                    footer: matches.count > Self.rowLimit
                        ? String(localized: "Showing the first \(Self.rowLimit) of \(matches.count.formatted()) matches.")
                        : String(localized: "\(matches.count.formatted()) matches.")
                )
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scanning every comment is too slow to repeat on each playback tick,
    /// so results are cached and refreshed only when the query or the
    /// comment set changes.
    private func runSearch() {
        let needle = trimmedQuery
        matches = needle.isEmpty ? [] : session.comments.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    // MARK: - Blocked

    private var blockedView: some View {
        Form {
            Section("Keywords") {
                DanmakuKeywordRows(preferences: preferences, onFocusChange: { keywordFocused = $0 })
            }
            Section("Users") {
                DanmakuBlockedUserRows(preferences: preferences, comments: session.comments)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Rows

    @ViewBuilder
    private func commentList(_ items: [DanmakuComment], empty: String, footer: String) -> some View {
        if items.isEmpty {
            placeholder(empty)
        } else {
            let filter = DanmakuCommentFilter(settings: preferences.settings)
            VStack(spacing: 0) {
                List(items) { comment in
                    row(comment, reason: filter.hidingReason(for: comment))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Divider()
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
    }

    private func row(_ comment: DanmakuComment, reason: DanmakuCommentFilter.HidingReason?) -> some View {
        let mediaTime = max(0, comment.time + preferences.settings.timeOffset)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timestamp(mediaTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if comment.isColored {
                Circle()
                    .fill(Color(
                        red: Double((comment.color >> 16) & 0xFF) / 255,
                        green: Double((comment.color >> 8) & 0xFF) / 255,
                        blue: Double(comment.color & 0xFF) / 255
                    ))
                    .frame(width: 7, height: 7)
            }
            Text(comment.text)
                .lineLimit(3)
                .foregroundStyle(reason == nil ? .primary : .tertiary)
                .strikethrough(reason != nil)
            Spacer(minLength: 4)
            if let reason {
                Text(Self.label(for: reason))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { seek(mediaTime) }
        .contextMenu {
            Button("Jump to \(Self.timestamp(mediaTime))") { seek(mediaTime) }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(comment.text, forType: .string)
            }
            Divider()
            if case let .keyword(keyword)? = reason {
                Button("Unblock “\(Self.shortened(keyword))”") {
                    preferences.settings.blockedKeywords.removeAll { $0 == keyword }
                }
            } else {
                Button("Block “\(Self.shortened(comment.text))”") { block(text: comment.text) }
            }
            if let sender = comment.senderID {
                if preferences.settings.blockedSenders.contains(sender) {
                    Button("Unblock This User") {
                        preferences.settings.blockedSenders.removeAll { $0 == sender }
                    }
                } else {
                    Button("Block This User") {
                        preferences.settings.blockedSenders.append(sender)
                    }
                }
            }
        }
    }

    private func block(text: String) {
        var keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Text that happens to look like /pattern/ is blocked literally.
        if DanmakuCommentFilter.regexPattern(from: keyword) != nil {
            keyword = "/\(NSRegularExpression.escapedPattern(for: keyword))/"
        }
        guard DanmakuCommentFilter.isValidKeyword(keyword),
              !preferences.settings.blockedKeywords.contains(keyword) else { return }
        preferences.settings.blockedKeywords.append(keyword)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func shortened(_ text: String) -> String {
        text.count > 16 ? "\(text.prefix(16))…" : text
    }

    private static func label(for reason: DanmakuCommentFilter.HidingReason) -> String {
        switch reason {
        case .mode: String(localized: "Mode hidden")
        case .colored: String(localized: "Colored")
        case .tooLong: String(localized: "Too long")
        case let .keyword(keyword): String(localized: "Blocked: \(shortened(keyword))")
        case .sender: String(localized: "Blocked user")
        }
    }
}

/// Add/remove rows for blocked keywords, shared by the settings sheet and
/// the in-player manager.
struct DanmakuKeywordRows: View {
    @ObservedObject var preferences: DanmakuPreferences
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var newKeyword = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack {
            TextField("Block", text: $newKeyword, prompt: Text("Keyword or /regex/"))
                .labelsHidden()
                .focused($fieldFocused)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(!DanmakuCommentFilter.isValidKeyword(newKeyword))
        }
        .onChange(of: fieldFocused) { _, focused in onFocusChange(focused) }
        .onDisappear { onFocusChange(false) }

        if preferences.settings.blockedKeywords.isEmpty {
            Text("No blocked keywords. Wrap a pattern in slashes, like /^23+$/, to use a regular expression.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(preferences.settings.blockedKeywords, id: \.self) { keyword in
            HStack {
                Text(keyword).lineLimit(1)
                Spacer()
                Button {
                    preferences.settings.blockedKeywords.removeAll { $0 == keyword }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
    }

    private func add() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DanmakuCommentFilter.isValidKeyword(keyword) else { return }
        if !preferences.settings.blockedKeywords.contains(keyword) {
            preferences.settings.blockedKeywords.append(keyword)
        }
        newKeyword = ""
    }
}

/// Blocked sender rows. Sender IDs are opaque hashes, so each row shows one
/// of the user's comments from the current episode when there is one.
struct DanmakuBlockedUserRows: View {
    @ObservedObject var preferences: DanmakuPreferences
    let comments: [DanmakuComment]

    var body: some View {
        if preferences.settings.blockedSenders.isEmpty {
            Text("No blocked users. Right-click a comment in the Danmaku Manager (M) to block its sender.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(preferences.settings.blockedSenders, id: \.self) { sender in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sender).font(.body.monospaced()).lineLimit(1)
                    if let sample = comments.first(where: { $0.senderID == sender }) {
                        Text("“\(sample.text)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    preferences.settings.blockedSenders.removeAll { $0 == sender }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Unblock")
            }
        }
    }
}
