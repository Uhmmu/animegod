import Testing
@testable import AnimeGodCore

struct AnimeKindClassificationTests {
    @Test(arguments: [
        ("TV", AnimeKind.tv),
        ("TV_SHORT", AnimeKind.tv),
        ("MOVIE", AnimeKind.movie),
        ("OVA", AnimeKind.ova),
        ("ONA", AnimeKind.ona),
        ("SPECIAL", AnimeKind.special)
    ])
    func mapsAniListFormats(format: String, expected: AnimeKind) {
        #expect(AniListMetadataProvider.kind(fromFormat: format) == expected)
        #expect(AniListMetadataProvider.kind(fromFormat: "MUSIC") == nil)
    }

    @Test(arguments: [
        ("TV", AnimeKind.tv),
        ("剧场版", AnimeKind.movie),
        ("OVA", AnimeKind.ova),
        ("WEB", AnimeKind.ona)
    ])
    func mapsBangumiPlatforms(platform: String, expected: AnimeKind) {
        #expect(BangumiMetadataProvider.kind(fromPlatform: platform) == expected)
        #expect(BangumiMetadataProvider.kind(fromPlatform: nil) == nil)
        #expect(BangumiMetadataProvider.kind(fromPlatform: "PS4") == nil)
    }
}
