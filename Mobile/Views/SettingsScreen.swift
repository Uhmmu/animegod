import AnimeGodCore
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: MobileModel
    @State private var showingPairing = false
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.isPaired {
                        LabeledContent("Paired with", value: model.macName ?? "Mac")
                        // A plain row rather than LabeledContent wrapping a
                        // Label: that combination lays out several hundred
                        // points tall in a Form and leaves a blank gap where
                        // the rest of the section should be.
                        HStack {
                            Text("Status").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: model.isReachable ? "checkmark.circle" : "wifi.slash")
                            Text(model.isReachable ? "Reachable" : "Not reachable")
                        }
                        .foregroundStyle(model.isReachable ? Color.green : Color.orange, Color.primary)
                        if let host = LinkCredentials.host {
                            LabeledContent("Address") {
                                Text(verbatim: host).font(.caption.monospaced())
                            }
                        }
                        if let synced = model.lastSyncedAt {
                            LabeledContent("Last synced") {
                                Text(synced.formatted(.relative(presentation: .named)))
                            }
                        }
                        Button("Refresh Now") { Task { await model.refresh() } }
                            .disabled(model.isRefreshing)
                        Button("Unpair", role: .destructive) { confirmingUnpair = true }
                    } else {
                        Button("Pair with a Mac…") { showingPairing = true }
                    }
                } header: {
                    Text("Mac")
                } footer: {
                    // Explanatory text belongs in a footer, not in a row: a
                    // multi-line row inside a Form lays out at the height of
                    // its first line and the rest is simply not drawn.
                    if LinkCredentials.usedFallback {
                        Text("This build is not signed with a development team, so the pairing token is kept in this app's container rather than the Keychain.")
                    }
                }

                if let error = model.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    TransportRow(name: String(localized: "Bonjour / same Wi-Fi"), icon: "wifi", rank: 1, isLive: model.resolver.isBrowsing)
                    TransportRow(name: String(localized: "Pinned address"), icon: "network", rank: 2, isLive: LinkCredentials.host != nil)
                    TransportRow(name: String(localized: "Tailscale"), icon: "lock.shield", rank: 3, isLive: false)
                    TransportRow(name: String(localized: "Peer-to-peer Wi-Fi"), icon: "dot.radiowaves.left.and.right", rank: 4, isLive: false)
                } header: {
                    Text("Transports")
                } footer: {
                    Text("Every transport produces the same thing: an address that reaches the Mac. They are raced and the first to answer wins. A Tailscale name goes in as an address like any other.")
                }

                Section("Library") {
                    LabeledContent("Works", value: String(model.works.count))
                    LabeledContent("In progress", value: String(model.continueWatching.count))
                    let queued = LinkOutbox.pending().count
                    if queued > 0 {
                        LabeledContent("Waiting to send", value: String(queued))
                    }
                }

                Section {
                    LabeledContent("Playback", value: String(localized: "Not built yet"))
                } footer: {
                    Text("Design: docs/IOS_COMPANION_PLAN.md")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPairing) { PairingScreen() }
            .confirmationDialog("Unpair from this Mac?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { model.unpair() }
            } message: {
                Text("The library on this phone is cleared. Nothing on the Mac changes.")
            }
        }
    }
}

private struct TransportRow: View {
    let name: String
    let icon: String
    let rank: Int
    let isLive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            Text(name)
            Spacer()
            Text(verbatim: "#\(rank)").font(.caption2).foregroundStyle(.tertiary)
            Image(systemName: isLive ? "circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(isLive ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        }
    }
}
