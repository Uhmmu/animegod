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
                    let book = LinkCredentials.addresses
                    TransportRow(
                        name: String(localized: "Bonjour / same Wi-Fi"), icon: "wifi", rank: 1,
                        state: model.resolver.activeKind == .lan && model.isReachable ? .active
                            : (model.resolver.isBrowsing ? .available : .idle),
                        detail: book.lan
                    )
                    TransportRow(
                        name: String(localized: "Tailscale"), icon: "lock.shield", rank: 2,
                        state: model.resolver.activeKind == .tailscale && model.isReachable ? .active
                            : (book.tailscale != nil ? .available : .idle),
                        detail: book.tailscale
                    )
                    TransportRow(
                        name: String(localized: "Other address"), icon: "network", rank: 3,
                        state: model.resolver.activeKind == .other && model.isReachable ? .active
                            : (book.other != nil ? .available : .idle),
                        detail: book.other
                    )
                } header: {
                    Text("Transports")
                } footer: {
                    Text("Every transport produces the same thing: an address that reaches your Mac. They are all raced at once and the first to answer wins — a filled dot is the one carrying this connection.")
                }

                Section {
                    TextField("mac.tailnet-abcd.ts.net:47380", text: Binding(
                        get: { model.tailscaleAddress },
                        set: { model.tailscaleAddress = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                } header: {
                    Text("Reaching your Mac from elsewhere")
                } footer: {
                    Text("Nothing here is exposed to the internet. Off your own network, install Tailscale on both devices and put your Mac's name here — it is then an address like any other, and it is never overwritten when a local one works.")
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
                    LabeledContent("Downloaded", value: String(model.offline.entries.count))
                    LabeledContent("On this phone", value: formatBytes(model.offline.totalBytes))
                } header: {
                    Text("Offline")
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
    enum State { case active, available, idle }

    let name: String
    let icon: String
    let rank: Int
    let state: State
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(verbatim: "#\(rank)").font(.caption2).foregroundStyle(.tertiary)
            Image(systemName: state == .idle ? "circle" : "circle.fill")
                .font(.caption2)
                .foregroundStyle(tint)
        }
    }

    private var tint: AnyShapeStyle {
        switch state {
        case .active: AnyShapeStyle(.green)
        case .available: AnyShapeStyle(.secondary)
        case .idle: AnyShapeStyle(.tertiary)
        }
    }
}
