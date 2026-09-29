import AnimeGodCore
import Foundation
import Security

/// Where the phone keeps what pairing gave it.
///
/// The token goes in the Keychain — on iOS there is no reason not to, and it
/// survives reinstalls the way the Mac's credential file does. The address is
/// ordinary preference data and lives in `UserDefaults`.
enum LinkCredentials {
    private static let service = "com.uhmmu.AnimeGod.link"
    private static let account = "macToken"

    /// Non-nil when the last token write was rejected; surfaced in Settings
    /// rather than left to be discovered as an empty library.
    nonisolated(unsafe) private(set) static var lastWriteFailure: OSStatus?

    /// The paired token.
    ///
    /// Keychain first, with a fallback to a file in the app's own container.
    /// The fallback is not laziness: a build that is only ad-hoc signed has no
    /// `application-identifier` entitlement, so **every** Keychain call fails
    /// with `errSecMissingEntitlement` (-34018) — which looks exactly like a
    /// pairing that succeeded and then forgot itself. The Mac side reached the
    /// same conclusion for the same reason and keeps its keys in a file.
    ///
    /// The container is private to the app and covered by data protection, so
    /// the fallback is a weaker place for a secret, not an open one.
    static var token: String? {
        get { keychainToken ?? fileToken }
        set {
            _ = writeKeychain(newValue)
            // Written both ways when the Keychain works, so a later build that
            // loses entitlements does not lose the pairing with them.
            writeFile(newValue)
        }
    }

    /// Whether the token is only in the container.
    ///
    /// Asked of the Keychain each time rather than remembered from the last
    /// write: a flag set during pairing is false again on the next launch, so
    /// it would report the wrong thing for every run but one.
    static var usedFallback: Bool {
        token != nil && keychainToken == nil
    }

    private static var keychainToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static var fileURL: URL {
        URL.documentsDirectory.appending(path: ".link-token")
    }

    private static var fileToken: String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeFile(_ value: String?) {
        guard let value, let data = value.data(using: .utf8) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    /// Plain computed accessors rather than a property wrapper: a wrapper
    /// would need static storage, which under strict concurrency is global
    /// mutable state. `UserDefaults` is already thread-safe.
    static var host: String? {
        get { UserDefaults.standard.string(forKey: "link.host") }
        set { set(newValue, "link.host") }
    }

    /// Every address the Mac has been reached on, by kind.
    ///
    /// Replaces the single `host` slot for resolution: one address is
    /// overwritten by whatever answered last, which silently discards the
    /// Tailscale name the moment a LAN address wins. `host` is kept as the
    /// *current* one for display and for building media URLs.
    static var addresses: LinkAddressBook {
        get {
            guard let data = UserDefaults.standard.data(forKey: "link.addresses"),
                  let book = try? JSONDecoder().decode(LinkAddressBook.self, from: data)
            else {
                // First run after the upgrade: seed from whatever single
                // address was already stored, so nobody has to re-pair.
                var book = LinkAddressBook()
                if let host { book.remember(host) }
                return book
            }
            return book
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: "link.addresses")
        }
    }

    static var macName: String? {
        get { UserDefaults.standard.string(forKey: "link.macName") }
        set { set(newValue, "link.macName") }
    }

    private static func set(_ value: String?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    static var isPaired: Bool { token != nil && host != nil }

    static func forget() {
        token = nil
        host = nil
        macName = nil
        UserDefaults.standard.removeObject(forKey: "link.addresses")
    }
}
