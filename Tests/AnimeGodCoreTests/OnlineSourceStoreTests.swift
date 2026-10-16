import Foundation
import Testing
@testable import AnimeGodCore

@Suite("The rules installed on this Mac")
struct OnlineSourceStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "animegod-online-\(UUID().uuidString)")
            .appending(path: "online-sources.json")
    }

    private func rule(_ name: String, version: String = "1.0", api: String = "9") -> OnlineSourceRule {
        OnlineSourceRule(
            api: api,
            name: name,
            version: version,
            baseURL: "https://\(name).example.com",
            searchURL: "https://\(name).example.com/s?wd=@keyword",
            searchList: "//div[@class='row']",
            searchName: "//a",
            searchResult: "//a",
            chapterRoads: "//ul",
            chapterResult: "//li/a"
        )
    }

    @Test("Rules survive a relaunch, in the order they were put in")
    func persistsRulesAndOrder() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = OnlineSourceStore(fileURL: file)
        _ = try await store.load()
        try await store.install(rule("alpha"))
        try await store.install(rule("beta"))
        try await store.install(rule("gamma"))

        // The order is the order sources are listed in, which is the user's
        // own preference and must not be re-sorted on the way to disk.
        let reopened = OnlineSourceStore(fileURL: file)
        let loaded = try await reopened.load()
        #expect(loaded.rules.map(\.name) == ["alpha", "beta", "gamma"])
        #expect(loaded.unreadable == 0)
    }

    @Test("An update replaces a rule where it sits")
    func keepsPositionAcrossAnUpdate() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = OnlineSourceStore(fileURL: file)
        _ = try await store.load()
        try await store.install(contentsOf: [rule("alpha"), rule("beta"), rule("gamma")])
        try await store.install(rule("beta", version: "2.0"))

        let names = await store.all().map(\.name)
        #expect(names == ["alpha", "beta", "gamma"])
        #expect(await store.rule(named: "beta")?.version == "2.0")
    }

    @Test("One unreadable rule does not take the rest of the file with it")
    func reportsUnreadableRulesAndKeepsTheOthers() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // A hand-edited file with one broken entry in it. Dropping the whole
        // list would look like the app had lost the user's sources.
        try Data("""
        [{"name":"good","baseURL":"https://a.example.com","version":"1.0"},
         {"version":"1.0"},
         {"name":"alsogood","baseURL":"https://b.example.com","version":"1.0"}]
        """.utf8).write(to: file)

        let loaded = try await OnlineSourceStore(fileURL: file).load()
        #expect(loaded.rules.map(\.name) == ["good", "alsogood"])
        #expect(loaded.unreadable == 1)
    }

    @Test("A mirror that lags behind cannot downgrade a working rule")
    func refusesToDowngrade() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = OnlineSourceStore(fileURL: file)
        _ = try await store.load()
        try await store.install(rule("alpha", version: "2.5"))

        #expect(try await store.installIfNewer(rule("alpha", version: "1.2")) == false)
        #expect(await store.rule(named: "alpha")?.version == "2.5")
        #expect(try await store.installIfNewer(rule("alpha", version: "2.6")) == true)
        #expect(await store.rule(named: "alpha")?.version == "2.6")
    }

    @Test("A rule needing a newer AnimeGod is refused rather than half-installed")
    func refusesANewerSchema() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = OnlineSourceStore(fileURL: file)
        _ = try await store.load()
        let future = rule("future", api: "\(OnlineSourceRule.supportedAPILevel + 1)")
        await #expect(throws: OnlineSourceError.requiresNewerClient(api: future.api)) {
            _ = try await store.installIfNewer(future)
        }
        #expect(await store.all().isEmpty)
    }

    @Test("Only the rules the catalog is actually ahead of are offered")
    func picksOutUpdatableRules() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = OnlineSourceStore(fileURL: file)
        _ = try await store.load()
        try await store.install(contentsOf: [rule("alpha", version: "1.2"), rule("beta", version: "2.0")])

        let catalog = [
            OnlineSourceCatalogItem(name: "Alpha", version: "1.10"),
            OnlineSourceCatalogItem(name: "beta", version: "2.0"),
            OnlineSourceCatalogItem(name: "gamma", version: "1.0"),
        ]
        let updatable = await store.updatable(against: catalog).map(\.name)
        // `1.10` is after `1.2`; `beta` is level; `gamma` is not installed,
        // so it is an install rather than an update.
        #expect(updatable == ["Alpha"])
    }

    @Test("A rule is shared as an object, a list or a pasted blob")
    func importsEverySharedShape() throws {
        let one = #"{"name":"solo","baseURL":"https://s.example.com","version":"1.0"}"#
        #expect(try OnlineSourceImport.rules(from: one).map(\.name) == ["solo"])
        #expect(try OnlineSourceImport.rules(from: "[\(one)]").map(\.name) == ["solo"])
        // Base64 is how these get pasted into a group chat.
        let blob = Data(one.utf8).base64EncodedString()
        #expect(try OnlineSourceImport.rules(from: blob).map(\.name) == ["solo"])
        #expect(throws: OnlineSourceError.unreadableResponse) {
            try OnlineSourceImport.rules(from: "not a rule at all")
        }
    }
}

@Suite("The shared rule catalog")
struct OnlineSourceCatalogTests {
    /// Trimmed from the real `index.json` on 2026-10-16.
    static let indexJSON = """
    [
      {"name":"7sefun","version":"1.3","useNativePlayer":true,"antiCrawlerEnabled":false,"author":"","lastUpdate":1786362131000},
      {"name":"AGE","version":"1.5","useNativePlayer":true,"antiCrawlerEnabled":false,"author":"","lastUpdate":1758092260000},
      {"name":"giriGiriLove","version":"2.5","useNativePlayer":true,"antiCrawlerEnabled":false,"author":"","lastUpdate":1787289623000}
    ]
    """

    @Test("The catalog index becomes a list of rules to install")
    func readsTheIndex() throws {
        let items = try OnlineSourceCatalog.parseIndex(Data(Self.indexJSON.utf8))
        #expect(items.map(\.name) == ["7sefun", "AGE", "giriGiriLove"])
        #expect(items[1].version == "1.5")
        // `lastUpdate` is milliseconds, so read as seconds it would be in 1970.
        let updated = try #require(items[1].updatedAt)
        #expect(updated > Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("One malformed entry upstream does not empty the catalog")
    func skipsUnreadableEntries() throws {
        let items = try OnlineSourceCatalog.parseIndex(Data("""
        [{"name":"good","version":"1.0"},{"version":"1.0"},{"name":"","version":"1.0"}]
        """.utf8))
        #expect(items.map(\.name) == ["good"])
    }

    @Test("Versions are compared as numbers, so 1.10 is after 1.9")
    func comparesVersionsNumerically() {
        #expect(OnlineSourceCatalog.isNewer("1.10", than: "1.9"))
        #expect(!OnlineSourceCatalog.isNewer("1.9", than: "1.10"))
        #expect(OnlineSourceCatalog.isNewer("2.0", than: "1.99"))
        #expect(!OnlineSourceCatalog.isNewer("1.5", than: "1.5"))
        #expect(OnlineSourceCatalog.isNewer("1.5.1", than: "1.5"))
        // A version that is not numeric at all falls back to "different
        // means newer", which is what the catalog's convention amounts to.
        #expect(OnlineSourceCatalog.isNewer("2024a", than: "2023b"))
        #expect(!OnlineSourceCatalog.isNewer("beta", than: "beta"))
    }
}
