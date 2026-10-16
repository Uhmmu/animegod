import Foundation

/// The rules installed on this Mac, and their order.
///
/// Kept as one JSON file rather than rows in the library database: a rule is
/// not library data, it is configuration the user exports, edits in a text
/// editor and shares, and a file is what makes that possible. The order is
/// the file's order — it is the order sources are listed in, which is the
/// user's own preference and not something to sort.
public actor OnlineSourceStore {
    public struct Installed: Sendable {
        public var rules: [OnlineSourceRule]
        /// Rules whose file would not parse, by file position. Reported
        /// rather than dropped silently, because a rule that vanishes looks
        /// like the app lost it.
        public var unreadable: Int
    }

    private let fileURL: URL
    private var rules: [OnlineSourceRule] = []
    private var didLoad = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default location: beside the library database in the app's own
    /// support folder, so it travels with the container.
    public static func defaultFileURL(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: "online-sources.json")
    }

    public func load() throws -> Installed {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            didLoad = true
            rules = []
            return Installed(rules: [], unreadable: 0)
        }
        let data = try Data(contentsOf: fileURL)
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw OnlineSourceError.unreadableResponse
        }
        var loaded: [OnlineSourceRule] = []
        var unreadable = 0
        let decoder = JSONDecoder()
        for row in rows {
            guard let rowData = try? JSONSerialization.data(withJSONObject: row),
                  let rule = try? decoder.decode(OnlineSourceRule.self, from: rowData),
                  !rule.name.isEmpty
            else {
                unreadable += 1
                continue
            }
            loaded.append(rule)
        }
        rules = loaded
        didLoad = true
        return Installed(rules: loaded, unreadable: unreadable)
    }

    public func all() -> [OnlineSourceRule] { rules }

    public func rule(named name: String) -> OnlineSourceRule? {
        let key = OnlineSourceRule.identityKey(name)
        return rules.first { $0.id == key }
    }

    /// Adds a rule, or replaces the one with that name.
    ///
    /// Replacing in place rather than appending keeps the user's ordering
    /// across an update, which is the whole point of storing an order.
    public func install(_ rule: OnlineSourceRule) throws {
        guard !rule.name.isEmpty else { throw OnlineSourceError.ruleIncomplete(field: "name") }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        try save()
    }

    public func install(contentsOf newRules: [OnlineSourceRule]) throws {
        for rule in newRules where !rule.name.isEmpty {
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index] = rule
            } else {
                rules.append(rule)
            }
        }
        try save()
    }

    public func remove(named name: String) throws {
        let key = OnlineSourceRule.identityKey(name)
        rules.removeAll { $0.id == key }
        try save()
    }

    public func move(from offsets: [Int], to destination: Int) throws {
        guard offsets.allSatisfy(rules.indices.contains), destination <= rules.count else { return }
        let moved = offsets.sorted().reversed().map { rules.remove(at: $0) }
        let insertAt = min(max(0, destination - offsets.count(where: { $0 < destination })), rules.count)
        rules.insert(contentsOf: moved.reversed(), at: insertAt)
        try save()
    }

    /// Which installed rules the catalog has a newer version of.
    public func updatable(against catalog: [OnlineSourceCatalogItem]) -> [OnlineSourceCatalogItem] {
        let installed = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.version) })
        return catalog.filter { item in
            guard let version = installed[item.id] else { return false }
            return OnlineSourceCatalog.isNewer(item.version, than: version)
        }
    }

    /// Takes a rule only if it is actually newer.
    ///
    /// A mirror can lag behind the repository it mirrors, so a download is
    /// not on its own a reason to overwrite what is installed — doing that
    /// would silently downgrade a working rule.
    public func installIfNewer(_ rule: OnlineSourceRule) throws -> Bool {
        guard !rule.requiresNewerClient else { throw OnlineSourceError.requiresNewerClient(api: rule.api) }
        if let existing = self.rule(named: rule.name),
           !OnlineSourceCatalog.isNewer(rule.version, than: existing.version) {
            return false
        }
        try install(rule)
        return true
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encoded one rule at a time and reassembled, so the file stays a
        // plain array of rule objects — the same shape the rules are shared
        // in, which is what lets one be lifted out of the file by hand.
        let rows = try rules.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        let data = try JSONSerialization.data(
            withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Reads rules out of what somebody pasted or dropped in.
///
/// A rule is shared as a bare JSON object, as an array of them, or as a
/// base64 blob out of a chat message, and all three turn up. Taking whatever
/// arrives is the difference between a rule that can be shared and one that
/// has to be retyped.
public enum OnlineSourceImport {
    public static func rules(from text: String) throws -> [OnlineSourceRule] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnlineSourceError.unreadableResponse }
        if let rules = try? decode(Data(trimmed.utf8)), !rules.isEmpty { return rules }
        // Base64, which is how these are pasted into a group chat.
        let unpadded = trimmed.replacingOccurrences(of: "\n", with: "")
        if let data = Data(base64Encoded: unpadded, options: [.ignoreUnknownCharacters]),
           let rules = try? decode(data), !rules.isEmpty {
            return rules
        }
        throw OnlineSourceError.unreadableResponse
    }

    private static func decode(_ data: Data) throws -> [OnlineSourceRule] {
        let decoder = JSONDecoder()
        if let many = try? decoder.decode([OnlineSourceRule].self, from: data) {
            return many.filter { !$0.name.isEmpty }
        }
        let one = try decoder.decode(OnlineSourceRule.self, from: data)
        return one.name.isEmpty ? [] : [one]
    }
}
