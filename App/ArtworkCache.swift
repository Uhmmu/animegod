import CryptoKit
import Foundation

/// Disk + memory cache for poster artwork (spec §19). A poster that loaded
/// once stays visible through provider outages and flaky networks, and the
/// UI can fall back to another metadata source when one CDN is unreachable.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private var memory: [URL: Data] = [:]
    private var memoryOrder: [URL] = []
    private let memoryLimit = 120
    private var inflight: [URL: Task<Data?, Never>] = [:]
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        directory = (caches ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appending(path: "AnimeGod/artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for url: URL) async -> Data? {
        if let cached = memoryHit(url) { return cached }
        let file = directory.appending(path: Self.fileName(for: url))
        if let disk = try? Data(contentsOf: file), !disk.isEmpty {
            remember(url, disk)
            return disk
        }
        if let running = inflight[url] {
            let result = await running.value
            if let result { remember(url, result) }
            return result
        }
        let task = Task<Data?, Never> { [directory] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty
            else { return nil }
            try? data.write(to: directory.appending(path: Self.fileName(for: url)))
            return data
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { remember(url, result) }
        return result
    }

    private func memoryHit(_ url: URL) -> Data? {
        guard let cached = memory[url] else { return nil }
        memoryOrder.removeAll { $0 == url }
        memoryOrder.append(url)
        return cached
    }

    private func remember(_ url: URL, _ data: Data) {
        memory[url] = data
        memoryOrder.removeAll { $0 == url }
        memoryOrder.append(url)
        if memoryOrder.count > memoryLimit, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            memory[oldest] = nil
        }
    }

    private static func fileName(for url: URL) -> String {
        let digest = CryptoKit.SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return "\(hex).\(ext)"
    }
}
