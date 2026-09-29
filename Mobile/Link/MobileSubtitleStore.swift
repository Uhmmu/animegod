import AnimeGodCore
import Foundation

/// Sidecar subtitles the Mac downloaded, written where mpv can open them.
///
/// The phone inherits the Mac's work rather than repeating it: the matching,
/// the scoring, the ZIP and GBK/Big5 handling and the provider credentials all
/// stay there. What arrives here is text and a path.
///
/// Subtitles are kept beside offline episodes deliberately. An episode
/// downloaded for a train with no subtitle is half a download, and the file is
/// a few tens of kilobytes against a gigabyte of video.
@MainActor
enum MobileSubtitleStore {
    static var directory: URL {
        URL.documentsDirectory.appending(path: "Subtitles", directoryHint: .isDirectory)
    }

    private static func url(mediaFileID: UUID, record: SubtitleDownloadRecord) -> URL {
        // The extension is what mpv reads the format from; a .ass named .txt
        // loads as plain text with no typesetting.
        directory.appending(path: "\(mediaFileID.uuidString)-\(record.id.uuidString).\(record.format.rawValue)")
    }

    static func localURL(mediaFileID: UUID, record: SubtitleDownloadRecord) -> URL? {
        let url = url(mediaFileID: mediaFileID, record: record)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Fetches one if it is not already here. Returns nil rather than
    /// throwing: a subtitle that cannot be had must never stop playback.
    static func fetch(
        mediaFileID: UUID,
        record: SubtitleDownloadRecord,
        using model: MobileModel
    ) async -> URL? {
        if let existing = localURL(mediaFileID: mediaFileID, record: record) { return existing }
        guard let text = await model.subtitleText(mediaFileID: mediaFileID, id: record.id), !text.isEmpty else {
            return nil
        }
        let destination = url(mediaFileID: mediaFileID, record: record)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// Keeps the list for a video so an offline episode still knows what it
    /// has, with the Mac unreachable.
    static func remember(_ list: LinkSubtitleList) {
        LinkCache.save(list, "subtitles-\(list.mediaFileID.uuidString)")
    }

    static func remembered(mediaFileID: UUID) -> LinkSubtitleList? {
        LinkCache.load(LinkSubtitleList.self, "subtitles-\(mediaFileID.uuidString)")
    }

    static func removeAll(mediaFileID: UUID) {
        guard let list = remembered(mediaFileID: mediaFileID) else { return }
        for record in list.subtitles {
            try? FileManager.default.removeItem(at: url(mediaFileID: mediaFileID, record: record))
        }
    }
}
