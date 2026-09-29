import AnimeGodCore
import Foundation
import Network

/// Finds an address that reaches the Mac.
///
/// The ladder from the plan: Bonjour on the same Wi-Fi, a pinned address when
/// multicast is filtered, then whatever the user typed — which is where a
/// Tailscale name goes, since to this code it is simply a host that resolves.
/// Candidates are raced rather than tried in order: the ranking decides ties,
/// not how long the app waits.
@MainActor
final class LinkResolver: ObservableObject {
    @Published private(set) var discovered: [Discovered] = []
    @Published private(set) var isBrowsing = false
    /// Which candidate answered last, for the Settings readout.
    @Published private(set) var activeTransport: String?

    struct Discovered: Identifiable, Hashable {
        let id: String
        let name: String
        /// The Bonjour endpoint itself. **Not** a hostname guessed from the
        /// service name: a Mac called "jiale's MacBook Pro" advertises under
        /// that name but answers to `jiales-MacBook-Pro.local`, so building
        /// `"\(name).local"` produces an address that never resolves. The
        /// endpoint has to be resolved by connecting to it.
        let endpoint: NWEndpoint
        /// Filled in once resolved.
        var host: String?
    }

    private var browser: NWBrowser?

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: LinkProtocol.bonjourType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let found: [Discovered] = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            let existing = discovered.first { $0.id == name }
            return Discovered(id: name, name: name, endpoint: result.endpoint, host: existing?.host)
        }
        .sorted { $0.name < $1.name }
        discovered = found
        for entry in found where entry.host == nil {
            Task { await resolveAddress(for: entry) }
        }
    }

    /// Turns a Bonjour service into an address that can be put in a URL.
    ///
    /// The only reliable way to learn it is to connect: once the connection is
    /// ready, its path's remote endpoint is the resolved host and port. Names
    /// cannot be derived from the service name, and the browser does not hand
    /// out addresses.
    private func resolveAddress(for entry: Discovered) async {
        let resolved: String? = await withCheckedContinuation { continuation in
            let connection = NWConnection(to: entry.endpoint, using: .tcp)
            let box = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        box.finish("\(Self.urlHost("\(host)")):\(port.rawValue)")
                    } else {
                        box.finish(nil)
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    box.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: .seconds(5))
                box.finish(nil)
                connection.cancel()
            }
        }
        guard let index = discovered.firstIndex(where: { $0.id == entry.id }) else { return }
        discovered[index].host = resolved
    }

    /// Races every candidate's `/health` and keeps the first that answers.
    ///
    /// Racing rather than trying in turn is the point: a dead pinned address
    /// costs a five-second timeout, and nobody should wait it out to discover
    /// that Bonjour would have worked.
    func resolve(candidates: [String]) async -> String? {
        guard !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            for host in candidates {
                group.addTask {
                    guard (try? await LinkClient.probe(host: host)) != nil else { return nil }
                    return host
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// Makes an address from `NWEndpoint` safe to put in a URL.
    ///
    /// Network.framework prints the interface zone it resolved on — an IPv4
    /// address comes back as `10.0.0.2%en0`, which no URL parser accepts. The
    /// zone is meaningful only for IPv6 link-local, where it must be kept and
    /// the whole literal bracketed.
    nonisolated static func urlHost(_ host: String) -> String {
        let isIPv6 = host.contains(":")
        if isIPv6 { return "[\(host)]" }
        return host.split(separator: "%").first.map(String.init) ?? host
    }

    /// Everything worth trying, best first.
    func candidates(pinned: String?) -> [String] {
        var hosts: [String] = []
        if let pinned, !pinned.isEmpty { hosts.append(pinned) }
        hosts.append(contentsOf: discovered.compactMap(\.host))
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }
}


/// A continuation that tolerates being finished more than once.
///
/// The connection can go ready and time out in either order, and resuming a
/// checked continuation twice is a crash, not a warning.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<String?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
