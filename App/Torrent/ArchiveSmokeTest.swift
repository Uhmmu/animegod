import AnimeGodCore
import Foundation

/// Headless check that a finished download's archives can actually be
/// unpacked where they landed:
///
///     AnimeGod -smokeExtract "/Volumes/T7/video/Some Release"
///
/// The sandbox is the reason this exists. Unpacking runs in-process against
/// the system libarchive precisely so it keeps the app's own folder access;
/// this proves that on a real folder rather than in a unit test that runs
/// outside the sandbox. Non-destructive: archives are left where they are.
enum ArchiveSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeExtract")
    }

    static func run() -> Never {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-smokeExtract"), flag + 1 < arguments.count else {
            print("SMOKE usage: -smokeExtract <folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        let archives = ArchiveExtractor.archives(in: folder)
        print("SMOKE folder \(folder.path)")
        print("SMOKE archives=\(archives.map(\.lastPathComponent))")
        guard !archives.isEmpty else {
            print("SMOKE nothing to unpack")
            exit(0)
        }
        let outcome = ArchiveExtractor.extractAll(in: folder)
        for destination in outcome.extracted {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            print("SMOKE unpacked \(destination.lastPathComponent) → \(contents.count) item(s): \(contents.prefix(5))")
        }
        for failure in outcome.failures { print("SMOKE FAILED \(failure)") }
        exit(outcome.failures.isEmpty ? 0 : 1)
    }
}
