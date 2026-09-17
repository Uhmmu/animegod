import AnimeGodCore
import Foundation

/// Headless check that the embedded engine really talks to the network:
///
///     AnimeGod.app/Contents/MacOS/AnimeGod -smokeTorrentTest <magnet|file.torrent> [seconds]
///
/// Prints session and task state once a second, then removes the task
/// without keeping any files. Nothing is written outside a temporary folder.
/// Point it at a torrent you are allowed to download (a Linux ISO, say).
enum TorrentEngineSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeTorrentTest")
            || ProcessInfo.processInfo.arguments.contains("-smokeTorrentLoopback")
    }

    static func runIfRequested() -> Never {
        if ProcessInfo.processInfo.arguments.contains("-smokeTorrentLoopback") { runLoopback() }
        run()
    }

    /// Proves the engine really transfers data without depending on the
    /// internet: one session seeds a generated file, a second downloads it,
    /// and they find each other through local service discovery.
    static func runLoopback() -> Never {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "animegod-loopback-\(UUID().uuidString)")
        let seedFiles = root.appending(path: "seed")
        let leechFiles = root.appending(path: "leech")
        for directory in [seedFiles, leechFiles] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = seedFiles.appending(path: "sample.bin")
        let megabytes = Int(ProcessInfo.processInfo.environment["AG_LOOPBACK_MB"] ?? "") ?? 8
        var data = Data(count: megabytes * 1024 * 1024)
        data.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 4) {
                buffer.storeBytes(of: UInt32.random(in: .min ... .max), toByteOffset: index, as: UInt32.self)
            }
        }
        try? data.write(to: payload)

        guard let torrent = try? AGTorrentEngine.createTorrentData(forPath: payload) else {
            print("SMOKE could not create the test torrent")
            exit(1)
        }

        let seeder = AGTorrentEngine(stateDirectory: root.appending(path: "seed-state"), listenPort: 6991, preferTCP: false)
        let leecher = AGTorrentEngine(stateDirectory: root.appending(path: "leech-state"), listenPort: 6992, preferTCP: false)
        for (name, engine) in [("seeder", seeder), ("leecher", leecher)] where engine.startupError != nil {
            print("SMOKE \(name) failed to start: \(engine.startupError!)")
            exit(1)
        }

        do {
            _ = try seeder.addTorrentData(torrent, savePath: seedFiles, sequential: false)
            let hash = try leecher.addTorrentData(torrent, savePath: leechFiles, sequential: true)
            let entries = leecher.files(forInfoHash: hash).map { "\($0.path) (\($0.length) bytes)" }
            print("SMOKE loopback hash=\(hash) size=\(megabytes) MiB files=\(entries)")
            print("SMOKE seed dir=\(seedFiles.path) leech dir=\(leechFiles.path)")

            var completed = false
            for tick in 1...90 {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                guard let leech = leecher.snapshot(forInfoHash: hash) else { continue }
                let seed = seeder.snapshot(forInfoHash: hash)
                if tick % 5 == 0 || leech.progress > 0 {
                    print(String(
                        format: "SMOKE t=%02ds seeder=%ld leecher=%ld peers=%d %.1f%% %.0f KiB/s",
                        tick, seed?.state.rawValue ?? -1, leech.state.rawValue,
                        leech.connectedPeers, leech.progress * 100, Double(leech.downloadRate) / 1024
                    ))
                }
                if leech.state == .finished || leech.state == .seeding, leech.progress >= 1 {
                    completed = true
                    break
                }
            }

            let downloaded = leechFiles.appending(path: "sample.bin")
            let downloadedData = try? Data(contentsOf: downloaded)
            let same = downloadedData == data
            print("SMOKE downloaded file exists=\(FileManager.default.fileExists(atPath: downloaded.path)) bytes=\(downloadedData?.count ?? -1)")
            seeder.shutdown()
            leecher.shutdown()
            // Shutdown must leave resume data behind, or a quit mid-download
            // would re-check every piece on the next launch.
            let resumeFiles = (try? FileManager.default.contentsOfDirectory(
                at: root.appending(path: "leech-state"), includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "resume" } ?? []
            print("SMOKE loopback complete=\(completed) bytesMatch=\(same) resumeFiles=\(resumeFiles.count)")
            try? FileManager.default.removeItem(at: root)
            exit(completed && same && !resumeFiles.isEmpty ? 0 : 1)
        } catch {
            print("SMOKE loopback failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() -> Never {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-smokeTorrentTest"), flag + 1 < arguments.count else {
            print("SMOKE usage: -smokeTorrentTest <magnet|file.torrent> [seconds]")
            exit(2)
        }
        let source = arguments[flag + 1]
        let seconds = (flag + 2 < arguments.count ? Int(arguments[flag + 2]) : nil) ?? 60

        let stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "animegod-smoke-\(UUID().uuidString)")
        let saveDirectory = stateDirectory.appending(path: "files")
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

        let engine = AGTorrentEngine(stateDirectory: stateDirectory, listenPort: 6881, preferTCP: false)
        if let failure = engine.startupError {
            print("SMOKE engine failed to start: \(failure)")
            exit(1)
        }
        print("SMOKE engine started")

        let hash: String
        do {
            if source.hasPrefix("magnet:") {
                hash = try engine.addMagnet(source, savePath: saveDirectory, sequential: true)
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: source))
                hash = try engine.addTorrentData(data, savePath: saveDirectory, sequential: true)
            }
        } catch {
            print("SMOKE could not add the task: \(error.localizedDescription)")
            exit(1)
        }
        print("SMOKE added \(hash)")

        var sawMetadata = false
        var sawPeers = false
        var sawBytes = false
        for tick in 1...seconds {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let info = engine.sessionInfo()
            guard let snapshot = engine.snapshot(forInfoHash: hash) else { continue }
            sawMetadata = sawMetadata || snapshot.hasMetadata
            sawPeers = sawPeers || snapshot.connectedPeers > 0
            sawBytes = sawBytes || snapshot.downloadedBytes > 0
            print(String(
                format: "SMOKE t=%02ds alerts=%d listen=%@ dht=%d port=%@ state=%ld meta=%@ peers=%d/%d rate=%.1f KiB/s got=%lld/%lld",
                tick, info.alertCount, info.listenError ?? "ok", info.dhtNodes,
                info.portMapped.map { $0.boolValue ? "open" : "closed" } ?? "pending",
                snapshot.state.rawValue, snapshot.hasMetadata ? "yes" : "no",
                snapshot.connectedSeeds, snapshot.connectedPeers,
                Double(snapshot.downloadRate) / 1024,
                snapshot.downloadedBytes, snapshot.totalBytes
            ))
            if sawBytes && snapshot.downloadedBytes > 8 * 1024 * 1024 { break }
        }

        engine.remove(hash, deleteFiles: true)
        engine.shutdown()
        try? FileManager.default.removeItem(at: stateDirectory)
        print("SMOKE result metadata=\(sawMetadata) peers=\(sawPeers) data=\(sawBytes)")
        exit(sawMetadata && sawPeers && sawBytes ? 0 : 1)
    }
}
