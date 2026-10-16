import Foundation

/// One rule as the shared catalog lists it, before it is downloaded.
public struct OnlineSourceCatalogItem: Sendable, Hashable, Identifiable {
    public let name: String
    public let version: String
    public let author: String
    public let updatedAt: Date?

    public var id: String { OnlineSourceRule.identityKey(name) }

    public init(name: String, version: String, author: String = "", updatedAt: Date? = nil) {
        self.name = name
        self.version = version
        self.author = author
        self.updatedAt = updatedAt
    }
}

/// Where shared rules come from.
///
/// Rules are a community format and the catalog is a plain directory of JSON
/// files behind an `index.json` — so this is two GETs and no API. The
/// default is the KazumiRules repository, whose schema this app reads: a
/// rule is written against a site, not against a player, and the same rule
/// is as useful here as it is there.
///
/// The address is settable because a raw-GitHub URL is not reachable
/// everywhere this app is used, and because somebody may keep their own
/// rules.
public struct OnlineSourceCatalog: Sendable {
    public static let defaultIndexURL = URL(
        string: "https://raw.githubusercontent.com/Predidit/KazumiRules/main/"
    )!

    /// A mirror reachable where raw.githubusercontent.com is not.
    public static let mirrorIndexURL = URL(
        string: "https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/"
    )!

    public var baseURL: URL
    private let http: TorrentHTTPClient

    public init(baseURL: URL = OnlineSourceCatalog.defaultIndexURL, http: TorrentHTTPClient = TorrentHTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    public func index() async throws -> [OnlineSourceCatalogItem] {
        let data = try await http.get(baseURL.appending(path: "index.json"), accept: "application/json")
        return try Self.parseIndex(data)
    }

    /// One rule, by the catalog's own spelling of its name.
    public func rule(named name: String) async throws -> OnlineSourceRule {
        let data = try await http.get(baseURL.appending(path: "\(name).json"), accept: "application/json")
        var rule = try JSONDecoder().decode(OnlineSourceRule.self, from: data)
        // A catalog entry and the file it points at can disagree about
        // capitalization; the catalog's spelling is the one shown and the one
        // updates are checked against.
        if !name.isEmpty { rule.name = name }
        return rule
    }

    /// Reads the index, keeping what it can.
    ///
    /// An entry this cannot read is skipped rather than failing the whole
    /// catalog: one malformed line upstream would otherwise leave the user
    /// with no sources at all.
    public static func parseIndex(_ data: Data) throws -> [OnlineSourceCatalogItem] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OnlineSourceError.unreadableResponse
        }
        let items = rows.compactMap { row -> OnlineSourceCatalogItem? in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let version = OnlineSourceJSONPath.text(of: row["version"] ?? "") ?? ""
            // `lastUpdate` is milliseconds since the epoch.
            let updatedAt = (row["lastUpdate"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return OnlineSourceCatalogItem(
                name: name,
                version: version,
                author: row["author"] as? String ?? "",
                updatedAt: updatedAt
            )
        }
        guard !items.isEmpty || rows.isEmpty else { throw OnlineSourceError.unreadableResponse }
        return items
    }

    /// Whether a catalog version supersedes an installed one.
    ///
    /// Compared component by component as numbers, because `1.10` is after
    /// `1.9` and a string comparison says otherwise. A version that is not
    /// numeric at all falls back to "different means newer", which is what
    /// the catalog's own convention amounts to.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) }
        let installedParts = installed.split(separator: ".").map { Int($0) }
        guard !candidateParts.contains(nil), !installedParts.contains(nil),
              !candidateParts.isEmpty, !installedParts.isEmpty
        else { return candidate != installed }
        for index in 0..<max(candidateParts.count, installedParts.count) {
            let left = index < candidateParts.count ? candidateParts[index]! : 0
            let right = index < installedParts.count ? installedParts[index]! : 0
            if left != right { return left > right }
        }
        return false
    }
}
