import Foundation

/// The HDR flavour actually carried by the decoded video, derived from real
/// color metadata — never from the filename alone. The filename only ever
/// upgrades a bt.2020+PQ/HLG signal to "Dolby Vision" when an RPU-capable
/// release label is present.
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
    /// Release-label hint only ("DoVi", "DV", "P8"); never used alone to
    /// classify a file as HDR.
    public let releaseHint: String?

    public init(
        codec: String?,
        pixelFormat: String?,
        bitDepth: Int?,
        primaries: String?,
        transfer: String?,
        matrix: String?,
        signalPeak: Double?,
        hardwareDecoder: String?,
        releaseHint: String? = nil
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
    }

    public var isHDR: Bool { hdrFormat == .hdr10 || hdrFormat == .hlg || hdrFormat == .dolbyVision }

    public var hdrFormat: HDRFormat {
        let transfer = (transfer ?? "").lowercased()
        let primaries = (primaries ?? "").lowercased()
        let wideGamut = primaries.contains("2020") || primaries.contains("bt2020")
        let pq = transfer.contains("pq") || transfer.contains("2084") || transfer.contains("smpte2084")
        let hlg = transfer.contains("hlg") || transfer.contains("arib")

        if pq && wideGamut {
            if let hint = releaseHint?.lowercased(), hint.contains("dovi") || hint.contains("dv") || hint.contains("dolby") {
                return .dolbyVision
            }
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
