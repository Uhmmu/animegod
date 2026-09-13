import Foundation

/// The HDR flavour actually carried by the decoded video, derived from real
/// color metadata plus a real Dolby Vision configuration/RPU signal. A
/// filename never upgrades a signal to Dolby Vision.
public enum HDRFormat: String, Sendable, Equatable {
    case sdr
    case hdr10
    case hlg
    case dolbyVision
    case unknown

    public var displayName: String {
        switch self {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        case .dolbyVision: "Dolby Vision (HDR10-compatible base)"
        case .unknown: "Unknown"
        }
    }
}

public enum DolbyVisionConfigurationKind: String, Sendable, Equatable {
    case dvvC
    case dvcC
    case mpvSideData
}

/// Parsed Dolby Vision decoder configuration. Unlike a release-name token,
/// this is evidence carried by the container or decoded frame side data.
public struct DolbyVisionMetadata: Sendable, Equatable {
    public let profile: Int
    public let level: Int?
    public let rpuPresent: Bool
    public let enhancementLayerPresent: Bool
    public let baseLayerPresent: Bool
    public let compatibilityID: Int?
    public let configurationKind: DolbyVisionConfigurationKind

    public init(
        profile: Int,
        level: Int? = nil,
        rpuPresent: Bool,
        enhancementLayerPresent: Bool = false,
        baseLayerPresent: Bool = true,
        compatibilityID: Int? = nil,
        configurationKind: DolbyVisionConfigurationKind
    ) {
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.enhancementLayerPresent = enhancementLayerPresent
        self.baseLayerPresent = baseLayerPresent
        self.compatibilityID = compatibilityID
        self.configurationKind = configurationKind
    }

    public var profileLabel: String {
        compatibilityID.map { "Profile \(profile).\($0)" } ?? "Profile \(profile)"
    }

    /// Apple's native Dolby Vision 8.4 path is HLG-compatible, single-track
    /// HEVC in an hvc1 sample entry with a dvvC configuration record.
    public func isAppleNativeEligible(
        codecTag: String?, bitDepth: Int?, videoTrackCount: Int,
        primaries: String?, transfer: String?
    ) -> Bool {
        let primaries = (primaries ?? "").lowercased()
        let transfer = (transfer ?? "").lowercased()
        return profile == 8 && compatibilityID == 4
            && configurationKind == .dvvC
            && codecTag?.lowercased() == "hvc1"
            && bitDepth == 10 && videoTrackCount == 1
            && primaries.contains("2020")
            && (transfer.contains("hlg") || transfer.contains("arib"))
    }

    public var hasHDR10CompatibleBaseLayer: Bool {
        baseLayerPresent && (profile == 7 || (profile == 8 && compatibilityID != 4))
    }
}

public enum DolbyVisionConfigurationParser {
    /// Parses the first five bytes of an ISO/IEC 14496-15 dvcC/dvvC record.
    public static func parse(_ data: Data, kind: DolbyVisionConfigurationKind) -> DolbyVisionMetadata? {
        guard data.count >= 5 else { return nil }
        let bytes = [UInt8](data.prefix(5))
        let profile = Int(bytes[2] >> 1)
        guard profile > 0 else { return nil }
        let level = Int((bytes[2] & 1) << 5 | bytes[3] >> 3)
        return DolbyVisionMetadata(
            profile: profile,
            level: level,
            rpuPresent: bytes[3] & 0x04 != 0,
            enhancementLayerPresent: bytes[3] & 0x02 != 0,
            baseLayerPresent: bytes[3] & 0x01 != 0,
            compatibilityID: Int(bytes[4] >> 4),
            configurationKind: kind
        )
    }
}

public enum HDRRenderDecision: Sendable, Equatable {
    case sdr
    case edr
    case toneMapToSDR

    public static func decide(
        profile: VideoColorProfile?, potentialHeadroom: Double, forcedSDR: Bool
    ) -> HDRRenderDecision {
        guard profile?.isHDR == true else { return .sdr }
        return potentialHeadroom > 1 && !forcedSDR ? .edr : .toneMapToSDR
    }
}

/// The luminance contract between libplacebo's linear output and Core
/// Animation's system EDR tone mapper. libplacebo defines diffuse white as
/// 203 nits, so CAEDRMetadata must use the same optical scale. The renderer
/// maps into the mastering range once; Core Animation then adapts that range
/// to the display's current headroom.
public enum HDROutputContract {
    public static let referenceWhiteNits = 203.0
    public static let masteringPeakNits = 1_000.0

    public static func linearComponentValue(forNits nits: Double) -> Double {
        max(0, nits) / referenceWhiteNits
    }
}

/// Color-relevant signal properties read from the playback engine
/// (mpv `video-params/*`), kept verbatim so the diagnostics panel can prove
/// metadata survived demux → decode → render.
public struct VideoColorProfile: Sendable, Equatable {
    public let codec: String?
    public let pixelFormat: String?
    public let bitDepth: Int?
    public let primaries: String?
    public let transfer: String?
    public let matrix: String?
    public let signalPeak: Double?
    public let hardwareDecoder: String?
    /// Human-readable label derived from detected container/side-data metadata;
    /// never used by itself to classify a file as HDR.
    public let releaseHint: String?
    public let dolbyVision: DolbyVisionMetadata?
    public let codecTag: String?
    public let videoTrackCount: Int

    public init(
        codec: String?,
        pixelFormat: String?,
        bitDepth: Int?,
        primaries: String?,
        transfer: String?,
        matrix: String?,
        signalPeak: Double?,
        hardwareDecoder: String?,
        releaseHint: String? = nil,
        dolbyVision: DolbyVisionMetadata? = nil,
        codecTag: String? = nil,
        videoTrackCount: Int = 1
    ) {
        self.codec = codec
        self.pixelFormat = pixelFormat
        self.bitDepth = bitDepth
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.signalPeak = signalPeak
        self.hardwareDecoder = hardwareDecoder
        self.releaseHint = releaseHint
        self.dolbyVision = dolbyVision
        self.codecTag = codecTag
        self.videoTrackCount = videoTrackCount
    }

    public var isHDR: Bool { hdrFormat == .hdr10 || hdrFormat == .hlg || hdrFormat == .dolbyVision }

    public var hdrFormat: HDRFormat {
        let transfer = (transfer ?? "").lowercased()
        let primaries = (primaries ?? "").lowercased()
        let wideGamut = primaries.contains("2020") || primaries.contains("bt2020")
        let pq = transfer.contains("pq") || transfer.contains("2084") || transfer.contains("smpte2084")
        let hlg = transfer.contains("hlg") || transfer.contains("arib")

        if (pq || hlg) && wideGamut, dolbyVision != nil { return .dolbyVision }
        if pq && wideGamut {
            return .hdr10
        }
        if hlg && wideGamut { return .hlg }
        return .sdr
    }

    /// Bit depth from mpv pixel formats (p010, yuv420p10, p016, …).
    public static func bitDepth(fromPixelFormat format: String?) -> Int? {
        guard let format = format?.lowercased(), !format.isEmpty else { return nil }
        switch format {
        case "p010": return 10
        case "p016": return 16
        case "rgb30": return 10
        case "nv12", "nv21", "nv16", "yuv420p", "yuv422p", "yuv444p",
             "bgra", "bgr0", "rgba", "rgb0", "gbrp", "ayuv":
            return 8
        default: break
        }
        // Planar formats carry the depth as a suffix: yuv420p10 → 10.
        if let digits = format.range(of: #"\d{2}$"#, options: .regularExpression) {
            return Int(format[digits])
        }
        return nil
    }

    public var transferDisplayName: String {
        let value = (transfer ?? "").lowercased()
        if value.contains("2084") || value.contains("pq") { return "SMPTE ST 2084 (PQ)" }
        if value.contains("hlg") || value.contains("arib") { return "HLG (ARIB STD-B67)" }
        if value.contains("linear") { return "Linear" }
        if value.contains("srgb") { return "sRGB" }
        if !value.isEmpty { return transfer ?? "" }
        return "—"
    }

    public var primariesDisplayName: String {
        let value = (primaries ?? "").lowercased()
        if value.contains("2020") { return "BT.2020" }
        if value.contains("709") { return "BT.709" }
        if value.contains("p3") { return "Display P3" }
        if !value.isEmpty { return primaries ?? "" }
        return "—"
    }
}
