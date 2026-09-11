import Foundation
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
        #expect(profile(primaries: "bt.2020", transfer: "pq", hint: "DoVi").hdrFormat == .hdr10)
        let metadata = DolbyVisionMetadata(profile: 8, rpuPresent: true, compatibilityID: 1, configurationKind: .dvcC)
        #expect(profile(primaries: "bt.2020", transfer: "pq", dolbyVision: metadata).hdrFormat == .dolbyVision)
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
        hint: String? = nil,
        dolbyVision: DolbyVisionMetadata? = nil
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
            releaseHint: hint,
            dolbyVision: dolbyVision
        )
    }

    @Test func parsesDolbyVisionConfigurationAndNativeEligibility() {
        // v1.0, profile 8, level 6, RPU + BL, compatibility ID 4.
        let metadata = DolbyVisionConfigurationParser.parse(
            Data([1, 0, 16, 0b0011_0101, 0x40]), kind: .dvvC
        )
        #expect(metadata?.profile == 8)
        #expect(metadata?.level == 6)
        #expect(metadata?.rpuPresent == true)
        #expect(metadata?.baseLayerPresent == true)
        #expect(metadata?.isAppleNativeEligible(
            codecTag: "hvc1", bitDepth: 10, videoTrackCount: 1,
            primaries: "bt.2020", transfer: "hlg"
        ) == true)
        #expect(metadata?.isAppleNativeEligible(
            codecTag: "hev1", bitDepth: 10, videoTrackCount: 1,
            primaries: "bt.2020", transfer: "hlg"
        ) == false)
    }

    @Test func probesRealConfigurationBoxInsteadOfFilename() {
        var data = Data([0, 0, 0, 32])
        data.append(contentsOf: Array("hvc1".utf8))
        data.append(contentsOf: [0, 0, 0, 13])
        data.append(contentsOf: Array("dvvC".utf8))
        data.append(contentsOf: [1, 0, 16, 0b0011_0101, 0x40])
        let result = DolbyVisionContainerProbe.inspect(data: data)
        #expect(result?.metadata.profile == 8)
        #expect(result?.codecTag == "hvc1")
        #expect(DolbyVisionContainerProbe.inspect(data: Data("movie.DoVi.mkv".utf8)) == nil)
    }

    @Test func coversSDRAndHDRDisplayDecisionMatrix() {
        let sdr8 = VideoColorProfile(
            codec: "h264", pixelFormat: "yuv420p", bitDepth: 8,
            primaries: "bt.709", transfer: "bt.1886", matrix: "bt.709",
            signalPeak: 1, hardwareDecoder: nil
        )
        let sdr10 = VideoColorProfile(
            codec: "hevc", pixelFormat: "p010", bitDepth: 10,
            primaries: "bt.709", transfer: "bt.1886", matrix: "bt.709",
            signalPeak: 1, hardwareDecoder: nil
        )
        let hdr10 = profile(primaries: "bt.2020", transfer: "pq")
        let hlg = profile(primaries: "bt.2020", transfer: "hlg")
        #expect(HDRRenderDecision.decide(profile: sdr8, potentialHeadroom: 1, forcedSDR: false) == .sdr)
        #expect(HDRRenderDecision.decide(profile: sdr10, potentialHeadroom: 4, forcedSDR: false) == .sdr)
        #expect(HDRRenderDecision.decide(profile: hdr10, potentialHeadroom: 4, forcedSDR: false) == .edr)
        #expect(HDRRenderDecision.decide(profile: hlg, potentialHeadroom: 4, forcedSDR: false) == .edr)
        #expect(HDRRenderDecision.decide(profile: hdr10, potentialHeadroom: 1, forcedSDR: false) == .toneMapToSDR)
        #expect(HDRRenderDecision.decide(profile: hdr10, potentialHeadroom: 4, forcedSDR: true) == .toneMapToSDR)
    }
}
