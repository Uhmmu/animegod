import Foundation

/// Which danmaku source(s) the player pulls from.
///
/// Order matters for `.both`: dandanplay comes first, so when the two pools
/// carry the same comment the dandanplay copy is the one kept (see
/// `DanmakuCommentMerger`).
public enum DanmakuSourceSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case dandanplay
    case bilibili
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dandanplay: "dandanplay"
        case .bilibili: "Bilibili"
        case .both: "dandanplay + Bilibili"
        }
    }

    /// The provider ids this selection activates, in priority order.
    public var providerIDs: [String] {
        switch self {
        case .dandanplay: ["dandanplay"]
        case .bilibili: [BilibiliDanmakuProvider.providerID]
        case .both: ["dandanplay", BilibiliDanmakuProvider.providerID]
        }
    }

    public func includes(providerID: String) -> Bool {
        providerIDs.contains(providerID)
    }
}
