import AnimeGodCore
import AppKit
import Foundation

/// Where downloads are written, and how that survives an unplugged drive.
///
/// Ported from magnet-crawler's download-path memory: recently used folders
/// are remembered, and if the chosen one is gone or not writable, new
/// downloads fall back to the most recent folder that works — with a notice —
/// instead of failing. Folders outside the sandbox are reached through
/// security-scoped bookmarks, which must be resolved and kept open.
@MainActor
final class DownloadFolderStore: ObservableObject {
    struct Folder: Identifiable, Hashable {
        var path: String
        var bookmark: Data?
        /// Set when this is a library folder: the sandbox access comes from
        /// the library's own bookmark, and finished downloads are picked up
        /// by the next scan without the user adding anything.
        var libraryRootID: UUID?
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var displayName: String { url.lastPathComponent }
    }

    /// Most recently used first.
    @Published private(set) var recentFolders: [Folder] = []
    @Published private(set) var currentFolder: Folder
    /// Set when the chosen folder was unusable and another was used instead.
    @Published var fallbackNotice: String?

    private let defaults: UserDefaults
    private static let foldersKey = "torrent.downloadFolders"
    private static let currentKey = "torrent.currentDownloadFolder"
    static let maximumRemembered = 10

    /// Started security scopes, kept open for as long as the app runs.
    private var openScopes: [String: URL] = [:]
    /// Library folders, which can be downloaded into using the access the
    /// library already has. Supplied by AppModel as roots change.
    @Published private(set) var libraryFolders: [Folder] = []
    private var libraryAccess: [UUID: ScopedLibraryAccess] = [:]
    private var roots: [LibraryRoot] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        currentFolder = Folder(path: Self.defaultFolderURL.path, bookmark: nil)
        loadFolders()
    }

    /// The always-available fallback inside the app's own container.
    static var defaultFolderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AnimeGod/Downloads")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var isUsingDefaultFolder: Bool { currentFolder.path == Self.defaultFolderURL.path }

    /// Whether a folder can actually be written to right now.
    func isWritable(_ folder: Folder) -> Bool { accessibleURL(for: folder) != nil }

    /// Keeps the list of library folders that can be downloaded into.
    func updateLibraryRoots(_ roots: [LibraryRoot]) {
        self.roots = roots
        libraryFolders = roots.map { root in
            Folder(path: root.lastKnownPath, bookmark: nil, libraryRootID: root.id)
        }
        // A remembered library folder keeps working across launches.
        if let rootID = currentFolder.libraryRootID, let match = libraryFolders.first(where: { $0.libraryRootID == rootID }) {
            currentFolder = match
        }
    }

    // MARK: - Choosing

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a download folder")
        panel.prompt = String(localized: "Use Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(url)
    }

    func adopt(_ url: URL) {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = Folder(path: url.path, bookmark: bookmark)
        remember(folder)
        select(folder)
    }

    func select(_ folder: Folder) {
        guard let usable = resolve(folder) else {
            fallbackNotice = Self.reasonUnusable(folder)
            return
        }
        currentFolder = usable
        fallbackNotice = nil
        defaults.set(usable.path, forKey: Self.currentKey)
        remember(usable)
    }

    /// The folder a new download should use: the chosen one when it works,
    /// otherwise the most recent one that does, otherwise the container.
    func folderForNewDownload() -> URL {
        if let url = accessibleURL(for: currentFolder) {
            fallbackNotice = nil
            return url
        }
        let reason = Self.reasonUnusable(currentFolder)
        for folder in recentFolders where folder.path != currentFolder.path {
            if let url = accessibleURL(for: folder) {
                fallbackNotice = String(localized: "\(reason) Downloading to “\(folder.displayName)” instead.")
                return url
            }
        }
        fallbackNotice = String(localized: "\(reason) Downloading to the app's own folder instead.")
        return Self.defaultFolderURL
    }

    /// Re-opens every remembered scope after launch so resumed downloads can
    /// keep writing where they were.
    func restoreAccess() {
        for folder in recentFolders { _ = accessibleURL(for: folder) }
        _ = accessibleURL(for: currentFolder)
    }

    // MARK: - Bookmarks

    private func accessibleURL(for folder: Folder) -> URL? {
        guard let url = resolveURL(for: folder) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Why a folder cannot be used, in terms the user can act on. A library
    /// folder bookmarked while the app was read-only stays read-only even
    /// after the entitlement changed, and only re-picking it in the open
    /// panel grants write access.
    private static func reasonUnusable(_ folder: Folder) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            return String(localized: "“\(folder.displayName)” is not there right now — is the drive plugged in?")
        }
        guard isDirectory.boolValue else { return String(localized: "“\(folder.displayName)” is not a folder.") }
        if folder.libraryRootID != nil {
            return String(localized: "AnimeGod can read “\(folder.displayName)” but not write to it: this library folder was authorised for reading only. Use “Choose Folder…” and pick it again to allow downloads into it.")
        }
        return String(localized: "AnimeGod is not allowed to write to “\(folder.displayName)”. Use “Choose Folder…” and pick it again.")
    }

    private func resolve(_ folder: Folder) -> Folder? {
        guard accessibleURL(for: folder) != nil else { return nil }
        return folder
    }

    private func resolveURL(for folder: Folder) -> URL? {
        // The signed app has a read-write exception for /Volumes/. Resolve
        // these folders by path first so access survives relaunches even if
        // an older security-scoped bookmark is stale or cannot be reopened.
        // The sandbox still enforces that this exception cannot escape the
        // external-volume root.
        if Self.isOnExternalVolume(folder.url) { return folder.url.standardizedFileURL }
        if let rootID = folder.libraryRootID {
            // Downloading into the library uses the library's own access.
            if let access = libraryAccess[rootID] { return access.url }
            guard let root = roots.first(where: { $0.id == rootID }),
                  let access = try? ScopedLibraryAccess(root: root) else { return nil }
            libraryAccess[rootID] = access
            return access.url
        }
        if let open = openScopes[folder.path] { return open }
        // The container folder needs no bookmark.
        if folder.bookmark == nil { return folder.url }
        guard let bookmark = folder.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), url.startAccessingSecurityScopedResource() else { return nil }
        openScopes[folder.path] = url
        return url
    }

    private static func isOnExternalVolume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/Volumes" || path.hasPrefix("/Volumes/")
    }

    private func remember(_ folder: Folder) {
        recentFolders.removeAll { $0.path == folder.path }
        recentFolders.insert(folder, at: 0)
        recentFolders = Array(recentFolders.prefix(Self.maximumRemembered))
        saveFolders()
    }

    private func loadFolders() {
        if let stored = defaults.array(forKey: Self.foldersKey) as? [[String: Any]] {
            recentFolders = stored.compactMap { entry in
                guard let path = entry["path"] as? String else { return nil }
                return Folder(
                    path: path,
                    bookmark: entry["bookmark"] as? Data,
                    libraryRootID: (entry["libraryRootID"] as? String).flatMap(UUID.init(uuidString:))
                )
            }
        }
        if let path = defaults.string(forKey: Self.currentKey),
           let folder = recentFolders.first(where: { $0.path == path }) {
            currentFolder = folder
        }
    }

    private func saveFolders() {
        let encoded = recentFolders.map { folder -> [String: Any] in
            var entry: [String: Any] = ["path": folder.path]
            if let bookmark = folder.bookmark { entry["bookmark"] = bookmark }
            if let rootID = folder.libraryRootID { entry["libraryRootID"] = rootID.uuidString }
            return entry
        }
        defaults.set(encoded, forKey: Self.foldersKey)
    }
}
