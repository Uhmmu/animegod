import AnimeGodCore
import Foundation

/// Headless check of why a download folder is or is not usable:
///
///     AnimeGod -smokeFolderAccess /Volumes/T7/video
///
/// Prints each step the sandbox has to clear — library bookmark, security
/// scope, existence, writability — so a refusal can be attributed instead of
/// guessed at. Writes only a probe file, which it deletes again.
enum FolderAccessSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-smokeFolderAccess")
    }

    static func run() -> Never {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-smokeFolderAccess"), flag + 1 < arguments.count else {
            print("SMOKE usage: -smokeFolderAccess <path>")
            exit(2)
        }
        let path = arguments[flag + 1]
        let target = URL(fileURLWithPath: path, isDirectory: true)
        print("SMOKE folder \(path)")

        let container = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AnimeGod")
        let databaseURL = container.appending(path: "library.sqlite")
        print("SMOKE database exists=\(FileManager.default.fileExists(atPath: databaseURL.path))")

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 1
        Task {
            var scoped: ScopedLibraryAccess?
            do {
                let database = try LibraryDatabase(url: databaseURL)
                let roots = try await database.libraryRoots()
                print("SMOKE libraryRoots=\(roots.map(\.lastKnownPath))")
                if let root = roots.first(where: {
                    path == $0.lastKnownPath || path.hasPrefix($0.lastKnownPath + "/")
                }) {
                    print("SMOKE matching root=\(root.displayName) hasBookmark=\(root.bookmarkData != nil)")
                    do {
                        let access = try ScopedLibraryAccess(root: root)
                        scoped = access
                        print("SMOKE scope resolved to \(access.url.path)")
                    } catch {
                        print("SMOKE scope FAILED: \(error.localizedDescription)")
                    }
                } else {
                    print("SMOKE no library root covers this path — it would need its own bookmark")
                }
            } catch {
                print("SMOKE database FAILED: \(error.localizedDescription)")
            }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            print("SMOKE exists=\(exists) isDirectory=\(isDirectory.boolValue) isWritableFile=\(FileManager.default.isWritableFile(atPath: target.path))")

            // The real question is whether a file can be created, which is
            // what a download actually needs.
            let probe = target.appending(path: ".animegod-write-probe")
            do {
                try Data("probe".utf8).write(to: probe)
                try FileManager.default.removeItem(at: probe)
                print("SMOKE write probe OK")
                code = 0
            } catch {
                print("SMOKE write probe FAILED: \(error.localizedDescription)")
            }
            scoped?.stop()
            semaphore.signal()
        }
        semaphore.wait()
        exit(code)
    }
}
