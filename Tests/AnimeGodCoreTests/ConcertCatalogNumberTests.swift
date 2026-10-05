import Foundation
import Testing
@testable import AnimeGodCore

/// A concert disc is looked up by its catalogue number, so everything hangs
/// on reading one out of a folder name without mistaking a codec for one.
struct ConcertCatalogNumberTests {
    @Test func readsTheCanonicalSpelling() {
        let number = ConcertCatalogNumber.first(in: "ANZX-10294")
        #expect(number?.prefix == "ANZX")
        #expect(number?.number == "10294")
        #expect(number?.description == "ANZX-10294")
    }

    /// Both indexes were measured to answer to any of these, and so must the
    /// reader: a folder is named whichever way its ripper felt like.
    @Test(arguments: ["ANZX-10294", "ANZX 10294", "ANZX10294", "anzx-10294", "[ANZX-10294]"])
    func foldsEverySpellingToOne(_ spelling: String) {
        #expect(ConcertCatalogNumber.first(in: spelling)?.description == "ANZX-10294")
    }

    @Test func offersTheSpellingsAnIndexMightWant() {
        #expect(ConcertCatalogNumber.first(in: "BRMM-10716")?.queryVariants
            == ["BRMM-10716", "BRMM 10716", "BRMM10716"])
    }

    /// `ANZX-10294~10296` is one three-disc box, not one disc.
    @Test func expandsARangeIntoItsDiscs() {
        let number = ConcertCatalogNumber.first(in: "[ANZX-10294~10296] 結束バンドLIVE-恒星-")
        #expect(number?.description == "ANZX-10294")
        #expect(number?.continuationNumbers == ["10295", "10296"])
        #expect(number?.discCount == 3)
    }

    /// Discogs files the Aqours tour as `LABX-8333~4`: the tail names the
    /// last disc by its final digit only.
    @Test func widensAShorthandRange() {
        let number = ConcertCatalogNumber.first(in: "LABX-8333~4")
        #expect(number?.number == "8333")
        #expect(number?.continuationNumbers == ["8334"])
        #expect(number?.discCount == 2)
    }

    /// Every one of these appears in real release names and every one of them
    /// is shaped like a catalogue number. Asking an index about `BD-50` or
    /// `AAC2` is a wasted request and a wrong match waiting to happen.
    @Test(arguments: [
        "1080P", "1920X1080", "X264", "H264", "H265", "AAC2", "BD-50", "DTS-HD",
        "HEVC", "FLAC", "WEB-DL", "MA5", "S01E02", "SP01", "VOL-02", "DISC1"
    ])
    func refusesWhatOnlyLooksLikeOne(_ token: String) {
        #expect(ConcertCatalogNumber.all(in: token).isEmpty, "\(token) is not a catalogue number")
    }

    /// A CRC stamped into a folder name is eight hex digits, and `ABCD1234`
    /// is a perfectly shaped catalogue number that nobody ever issued.
    @Test(arguments: ["E7E8AD1D", "ABCD1234", "(ABCD1234)"])
    func refusesACRC(_ token: String) {
        #expect(ConcertCatalogNumber.all(in: token).isEmpty)
    }

    /// The shape a real download has: the number among the tags.
    @Test func findsTheNumberInsideARealFolderName() {
        let name = "[ANZX-10294~10296] 結束バンドLIVE-恒星- [BDMV][2023.11.22][1080P][x264][FLAC2.0]"
        let all = ConcertCatalogNumber.all(in: name)
        #expect(all.map(\.description) == ["ANZX-10294"])
    }

    @Test func readsTheOtherLabelsPrefixes() {
        #expect(ConcertCatalogNumber.first(in: "BRMM-10716")?.description == "BRMM-10716")
        #expect(ConcertCatalogNumber.first(in: "LABX-8480")?.description == "LABX-8480")
        #expect(ConcertCatalogNumber.first(in: "VVXL-240")?.description == "VVXL-240")
        #expect(ConcertCatalogNumber.first(in: "VVXL 77")?.description == "VVXL-77")
    }

    /// Two numbers in one name: the set's own comes first and is what a
    /// lookup uses, but the rest must not be silently thrown away.
    @Test func keepsEveryNumberItFinds() {
        let all = ConcertCatalogNumber.all(in: "ANZX-10294 / PCXP-50999")
        #expect(all.map(\.description) == ["ANZX-10294", "PCXP-50999"])
    }
}
