import Foundation

/// How a host was reached.
///
/// The distinction is not cosmetic. A single stored address is overwritten by
/// whatever answered last, so pairing at home and then leaving the building
/// leaves nothing to try — including the Tailscale name that would have
/// worked. Addresses of different kinds therefore occupy different slots and
/// never overwrite each other.
public enum LinkAddressKind: String, Codable, Sendable, CaseIterable {
    /// Reachable only on the same network: a private IPv4, a `.local` name, a
    /// link-local address.
    case lan
    /// Reachable from anywhere the tailnet reaches.
    case tailscale
    /// Something else the user typed — a VPN, a hostname, a port-forward.
    case other

    /// What an address looks like.
    ///
    /// Tailscale hands out addresses in `100.64.0.0/10` (the carrier-grade NAT
    /// range) and MagicDNS names under `.ts.net`, so both are recognisable
    /// without asking. Everything in the private ranges or ending `.local` is
    /// local by definition.
    public static func classify(_ host: String) -> LinkAddressKind {
        let name = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host.lowercased()
        if name.hasSuffix(".ts.net") { return .tailscale }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            // 100.64/10 is Tailscale's range; the rest of 100.x is not.
            if parts[0] == 100, (64...127).contains(parts[1]) { return .tailscale }
            if parts[0] == 10 { return .lan }
            if parts[0] == 192, parts[1] == 168 { return .lan }
            if parts[0] == 172, (16...31).contains(parts[1]) { return .lan }
            if parts[0] == 169, parts[1] == 254 { return .lan }
            if parts[0] == 127 { return .lan }
            return .other
        }
        if name.hasSuffix(".local") { return .lan }
        return .other
    }
}

/// Every address that has ever reached the Mac, by kind.
///
/// Racing all of them is the point: the phone does not know which network it
/// is on, and finding out costs more than trying.
public struct LinkAddressBook: Codable, Sendable, Equatable {
    /// The last local address that answered. Overwritten freely — a DHCP
    /// lease changes and the old one is worthless.
    public var lan: String?
    /// Typed by the user and **never** overwritten by a resolution. It is the
    /// only address that works from outside, so losing it to a LAN win is
    /// exactly the failure this type exists to prevent.
    public var tailscale: String?
    public var other: String?
    /// What worked on a given Wi-Fi network, so walking back into the flat
    /// reconnects on the fast path instead of racing.
    public var byNetwork: [String: String]

    public init(lan: String? = nil, tailscale: String? = nil, other: String? = nil, byNetwork: [String: String] = [:]) {
        self.lan = lan
        self.tailscale = tailscale
        self.other = other
        self.byNetwork = byNetwork
    }

    /// Records an address that answered.
    ///
    /// A Tailscale address is only ever set deliberately, through
    /// `setTailscale`: a successful connection over the tailnet must not be
    /// able to replace a name the user typed with, say, a raw 100.x address
    /// whose lease may move.
    public mutating func remember(_ host: String, network: String? = nil) {
        switch LinkAddressKind.classify(host) {
        case .lan: lan = host
        case .tailscale: if tailscale == nil { tailscale = host }
        case .other: other = host
        }
        if let network, !network.isEmpty { byNetwork[network] = host }
    }

    public mutating func setTailscale(_ host: String?) {
        let trimmed = host?.trimmingCharacters(in: .whitespaces)
        tailscale = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Everything worth racing, best first, without duplicates.
    ///
    /// The order decides ties only: the resolver races them, so a dead entry
    /// costs nothing but a socket. What it must never do is *omit* one —
    /// leaving out Tailscale because a LAN address exists is how the phone
    /// ends up unreachable the moment it leaves the building.
    public func candidates(network: String? = nil, discovered: [String] = []) -> [String] {
        var hosts: [String] = []
        if let network, let remembered = byNetwork[network] { hosts.append(remembered) }
        hosts.append(contentsOf: discovered)
        if let lan { hosts.append(lan) }
        if let other { hosts.append(other) }
        if let tailscale { hosts.append(tailscale) }
        var seen = Set<String>()
        return hosts.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
