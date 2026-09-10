import Testing
@testable import AnimeGodCore

struct VideoColorProfileTests {
    @Test func classifiesFromRealColorMetadataNotFilenames() {
        // HDR10: BT.2020 + PQ from the decoded signal.
        #expect(profile(primaries: "bt.2020", transfer: "pq").hdrFormat == .hdr10)
        #expect(profile(primaries: "bt.2020", transfer: "smpte2084").hdrFormat == .hdr10)
        // HLG: BT.2020 + HLG transfer.
        #expect(profile(primaries: "bt.2020", transfer: "hlg").hdrFormat == .hlg)
        // SDR: 709 gamma.
        #expect(profile(primaries: "bt.709", transfer: "bt.1886").hdrFormat == .sdr)
        // A PQ transfer alone on a narrow gamut stays unclassified as HDR
        // modes require wide gamut + HDR transfer together.
        #expect(profile(primaries: "bt.709", transfer: "pq").hdrFormat == .sdr)
    }

    @Test func dolbyVisionNeedsSignalPlusReleaseHint() {
        // A "DoVi" filename never invents HDR for an SDR signal.
        #expect(profile(primaries: "bt.709", transfer: "bt.1886", hint: "DoVi").hdrFormat == .sdr)
        // Wide-gamut PQ with a DoVi release label reports the DV fallback mode.
        #expect(profile(primaries: "bt.2020", transfer: "pq", hint: "DoVi").hdrFormat == .dolbyVision)
        #expect(profile(primaries: "bt.2020", transfer: "pq", hint: "DoVi").isHDR)
    }

    @Test(arguments: [
        ("p010", 10),
        ("p016", 16),
        ("yuv420p10", 10),
        ("yuv420p16", 16),
        ("nv12", 8),
        (nil, nil)
    ])
    func readsBitDepthFromPixelFormats(format: String?, expected: Int?) {
        #expect(VideoColorProfile.bitDepth(fromPixelFormat: format) == expected)
    }

    @Test func formatsDisplayNames() {
        #expect(profile(primaries: "bt.2020", transfer: "pq").primariesDisplayName == "BT.2020")
        #expect(profile(primaries: "bt.2020", transfer: "pq").transferDisplayName == "SMPTE ST 2084 (PQ)")
        #expect(profile(primaries: "bt.2020", transfer: "hlg").transferDisplayName == "HLG (ARIB STD-B67)")
        #expect(profile(primaries: "bt.709", transfer: "bt.1886").transferDisplayName == "bt.1886")
    }

    private func profile(
        primaries: String?,
        transfer: String?,
        hint: String? = nil
    ) -> VideoColorProfile {
        VideoColorProfile(
            codec: "hevc",
            pixelFormat: "p010",
            bitDepth: 10,
            primaries: primaries,
            transfer: transfer,
            matrix: "bt.2020c",
            signalPeak: 1.0,
            hardwareDecoder: "videotoolbox",
            releaseHint: hint
        )
    }
}
