import Foundation

/// A work a source found, and the page that lists its episodes.
public struct OnlineSearchItem: Sendable, Hashable, Identifiable {
    /// The rule that found it. Two sources answering about one show are two
    /// results, because their episode lists and their streams differ.
    public let ruleName: String
    public let name: String
    /// The detail page, already absolute.
    public let pageURL: String

    public var id: String { "\(ruleName)\u{1F}\(pageURL)" }

    public init(ruleName: String, name: String, pageURL: String) {
        self.ruleName = ruleName
        self.name = name
        self.pageURL = pageURL
    }
}

/// One playback line of a work: the same episodes from one upload.
///
/// A site offers several because any one of them can be down, re-encoded or
/// missing the last episode, and choosing between them is the user's.
public struct OnlineRoad: Sendable, Hashable, Identifiable {
    public let name: String
    public let episodes: [OnlineEpisode]

    public var id: String { name }

    public init(name: String, episodes: [OnlineEpisode]) {
        self.name = name
        self.episodes = episodes
    }
}

/// One episode of one line: a label, and the page its stream has to be
/// resolved out of.
public struct OnlineEpisode: Sendable, Hashable, Identifiable {
    public let label: String
    public let pageURL: String
    /// Position within the line, kept because a label is not always a number
    /// — `OVA`, `特別編`, `预告` all appear in these lists.
    public let index: Int

    public var id: String { pageURL }

    public init(label: String, pageURL: String, index: Int) {
        self.label = label
        self.pageURL = pageURL
        self.index = index
    }

    /// The episode number the label states, when it states one. Used to line
    /// an online line up against what the library already has.
    public var number: Int? {
        guard let match = label.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(label[match])
    }
}

/// What went wrong running a rule.
///
/// Each case is a different thing to tell the user and a different thing to
/// do about it, which is why "found nothing" is not an error shape but its
/// own case: a source that works and has never heard of this show must not
/// be reported as broken.
public enum OnlineSourceError: Error, Sendable, Equatable {
    case ruleIncomplete(field: String)
    case invalidURL(String)
    case network(String)
    case http(Int)
    /// An anti-bot interstitial. The page is a challenge, not a result, and
    /// parsing it would report "no results" for a site that is simply
    /// refusing this request.
    case blocked
    case noResults
    case unreadableResponse
    case requiresNewerClient(api: String)

    public var isEmptyAnswer: Bool { self == .noResults }
}

/// What a rule's run produced, with what it had to skip.
///
/// The diagnostics are the point: a selector that still matches the list but
/// no longer matches the name inside it degrades to a page of blank rows, and
/// a count of skipped nodes is what makes that visible instead of mysterious.
public struct OnlineSearchResult: Sendable {
    public let ruleName: String
    public let items: [OnlineSearchItem]
    public let skipped: [String]

    public init(ruleName: String, items: [OnlineSearchItem], skipped: [String] = []) {
        self.ruleName = ruleName
        self.items = items
        self.skipped = skipped
    }
}

public struct OnlineChapterResult: Sendable {
    public let ruleName: String
    public let roads: [OnlineRoad]
    public let skipped: [String]

    public init(ruleName: String, roads: [OnlineRoad], skipped: [String] = []) {
        self.ruleName = ruleName
        self.roads = roads
        self.skipped = skipped
    }
}

/// Turns whatever a rule scraped into one stable absolute URL.
///
/// A scraped `href` is a relative path, or protocol-relative, or carries a
/// trailing slash the next page's links do not. The same episode has to come
/// out as the same string every time, because that string is its identity —
/// what watch progress is filed under and what a resumed session is looked
/// up by. So normalizing may not change where the URL points: the scheme is
/// unified to the one the rule itself declares, and only for the rule's own
/// host, since a site reachable only over http would break if rewritten.
public enum OnlineEpisodeURL {
    public static func absolute(_ raw: String, base: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let baseURL = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines))
        let hasUsableBase = baseURL?.scheme != nil && baseURL?.host != nil

        var resolved: URL?
        if let direct = URL(string: trimmed), direct.scheme != nil, direct.host != nil {
            resolved = direct
        } else if hasUsableBase {
            // A protocol-relative `//host/path` resolves against the base's
            // scheme, which is what `URL(string:relativeTo:)` does for it.
            resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        guard var components = resolved.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: true) }),
              components.host != nil
        else { return trimmed }

        if let baseURL, hasUsableBase,
           let baseScheme = baseURL.scheme, let scheme = components.scheme,
           ["http", "https"].contains(baseScheme), ["http", "https"].contains(scheme),
           scheme != baseScheme,
           components.host == baseURL.host,
           components.port == baseURL.port {
            components.scheme = baseScheme
        }

        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.query?.isEmpty == true { components.query = nil }
        if components.fragment?.isEmpty == true { components.fragment = nil }
        return components.url?.absoluteString ?? trimmed
    }
}
