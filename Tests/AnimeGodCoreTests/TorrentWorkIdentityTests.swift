import Foundation
import Testing
@testable import AnimeGodCore

@Suite("One work, however its episodes were started")
struct TorrentWorkIdentityTests {
    @Test("A season started one episode at a time is still one work")
    func joinsTheWorkAlreadyDownloading() {
        // Episode one was fetched on its own, because in a season's first
        // week there is no set to download. The set that exists a week later
        // names the same folder, which is what keeps them together.
        let lone = TorrentDownloadFolder.name(
            animeTitle: nil,
            releaseNames: ["[ANi] 藥師少女的獨語 / Kusuriya no Hitorigoto - 01 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4"]
        )
        let set = TorrentDownloadFolder.name(
            animeTitle: nil,
            releaseNames: (1...2).map {
                "[ANi] 藥師少女的獨語 / Kusuriya no Hitorigoto - 0\($0) [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4"
            }
        )
        #expect(lone == "Kusuriya no Hitorigoto")
        #expect(set == lone)
        #expect(TorrentWorkIdentity.namesSameWork(lone!, set!))
    }

    @Test("Case, width, punctuation and spacing do not make a second work")
    func foldsWhatNamesDisagreeAbout() {
        #expect(TorrentWorkIdentity.namesSameWork("BanG Dream! Ave Mujica", "bang dream ave mujica"))
        #expect(TorrentWorkIdentity.namesSameWork("Re:Zero kara Hajimeru", "ReZero kara Hajimeru"))
        #expect(TorrentWorkIdentity.namesSameWork("ＹＡＮＩ ＮＥＫＯ", "Yani Neko"))
    }

    @Test("A folder name macOS handed back decomposed matches the same name typed")
    func precomposesFirst() {
        // Scanned folder names arrive decomposed, so 「まだ」 is `ま` + `た` +
        // U+3099 — and folding removes a combining mark while leaving a
        // precomposed one alone, which filed one work twice.
        // Swift compares the two spellings equal, which is exactly why
        // nothing in the app ever noticed; the scalars are what differ.
        let decomposed = "まだ".decomposedStringWithCanonicalMapping
        #expect(decomposed.unicodeScalars.count > "まだ".unicodeScalars.count)
        #expect(TorrentWorkIdentity.namesSameWork(decomposed, "まだ"))
        #expect(TorrentWorkIdentity.key(decomposed) == TorrentWorkIdentity.key("まだ"))
    }

    @Test("A later season is its own work")
    func seasonsStayApart() {
        #expect(!TorrentWorkIdentity.namesSameWork("Yani Neko", "Yani Neko S2"))
        #expect(!TorrentWorkIdentity.namesSameWork("Yani Neko", "Frieren"))
    }

    @Test("A name with nothing in it matches nothing")
    func emptyNamesMatchNothing() {
        #expect(!TorrentWorkIdentity.namesSameWork("", ""))
        #expect(!TorrentWorkIdentity.namesSameWork(" - ", "---"))
    }

    // MARK: - What a new download joins

    private func downloading(
        _ folderName: String,
        anime: UUID? = nil,
        title: String? = nil,
        minutesAgo: Int = 0
    ) -> TorrentWorkIdentity.Downloading {
        TorrentWorkIdentity.Downloading(
            folderName: folderName,
            animeID: anime,
            animeTitle: title,
            addedAt: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60)
        )
    }

    @Test("The second episode joins the folder the first one is in")
    func joinsTheFolderOnDisk() {
        let join = TorrentWorkIdentity.join(
            folderName: "Yani Neko",
            among: [downloading("Yani Neko", minutesAgo: 10_080)]
        )
        #expect(join.folderName == "Yani Neko")
    }

    @Test("The folder on disk keeps its spelling")
    func keepsTheSpellingOnDisk() {
        // The episodes that are there are in "Re:Zero"; renaming the folder
        // to the new spelling would move nothing and split the season.
        let join = TorrentWorkIdentity.join(
            folderName: "ReZero",
            among: [downloading("Re:Zero", minutesAgo: 10_080)]
        )
        #expect(join.folderName == "Re:Zero")
    }

    @Test("An episode joining a matched work is matched too")
    func inheritsTheAnime() {
        let anime = UUID()
        let join = TorrentWorkIdentity.join(
            folderName: "Yani Neko",
            among: [
                downloading("Yani Neko", minutesAgo: 20_160),
                downloading("Yani Neko", anime: anime, title: "ヤニねこ", minutesAgo: 10_080),
            ]
        )
        // Without this the first episode would be the matched show and the
        // second an anonymous magnet beside it — one season, two cards.
        #expect(join.animeID == anime)
        #expect(join.animeTitle == "ヤニねこ")
    }

    @Test("An anime the caller already knows is never overruled")
    func keepsTheCallersAnime() {
        let mine = UUID()
        let join = TorrentWorkIdentity.join(
            folderName: "Yani Neko",
            animeID: mine,
            animeTitle: "Yani Neko",
            among: [downloading("Yani Neko", anime: UUID(), title: "Something else", minutesAgo: 10_080)]
        )
        #expect(join.animeID == mine)
        #expect(join.animeTitle == "Yani Neko")
    }

    @Test("A work nothing matches starts a folder of its own")
    func noMatchChangesNothing() {
        let join = TorrentWorkIdentity.join(
            folderName: "Frieren",
            among: [downloading("Yani Neko", anime: UUID(), minutesAgo: 10_080)]
        )
        #expect(join == TorrentWorkIdentity.Join(folderName: "Frieren", animeID: nil, animeTitle: nil))
        #expect(TorrentWorkIdentity.join(folderName: nil, among: []).folderName == nil)
    }

    @Test("A second season is not poured into the first season's folder")
    func seasonsKeepTheirFolders() {
        let anime = UUID()
        let join = TorrentWorkIdentity.join(
            folderName: "Yani Neko S2",
            animeID: anime,
            among: [downloading("Yani Neko", anime: anime, minutesAgo: 10_080)]
        )
        #expect(join.folderName == "Yani Neko S2")
    }

    @Test("One episode of a later season says so, the same way a set does")
    func loneEpisodeOfALaterSeason() {
        let lone = TorrentDownloadFolder.name(
            animeTitle: nil,
            releaseNames: ["[LoliHouse] Yani Neko S2 - 01 [WebRip 1080p HEVC-10bit AAC].mkv"],
            season: 2
        )
        #expect(lone == "Yani Neko S2")
        #expect(TorrentDownloadFolder.name(animeTitle: "Yani Neko", releaseNames: [], season: 1) == "Yani Neko")
    }
}
