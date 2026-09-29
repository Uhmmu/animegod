import AnimeGodCore
import SwiftUI

/// Settings → iPhone. Turning the server on, pairing a phone, and revoking one.
///
/// The server binds every interface, so it does not come up merely because
/// the app is open — but the switch is remembered, and it defaults to on once
/// a phone has been paired. See `LinkServer.servesAtLaunch`.
struct LinkSettingsSection: View {
    @ObservedObject var link: LinkServer
    @State private var now = Date.now

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            Toggle("Serve this library to AnimeGod on iPhone", isOn: Binding(
                get: { link.isRunning },
                set: { serve in
                    // Remembered, so a paired phone keeps working across
                    // launches instead of waiting on this switch every time.
                    link.servesAtLaunch = serve
                    serve ? link.start() : link.stop()
                }
            ))

            if let error = link.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if link.isRunning {
                if link.endpoints.isEmpty {
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    // Shown because Bonjour is filtered on plenty of networks
                    // (student halls especially), and typing the address is
                    // the fallback that always works.
                    LabeledContent("Reachable at") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(link.endpoints, id: \.self) { endpoint in
                                Text(verbatim: endpoint).font(.caption.monospaced())
                            }
                        }
                    }
                }
                pairing
            }

            if !link.pairedDevices.isEmpty {
                ForEach(link.pairedDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(lastSeen(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { link.revoke(device) }
                            .buttonStyle(.link)
                    }
                }
            }
        } header: {
            Text("iPhone")
        } footer: {
            Text("Your phone mirrors this library and streams episodes from this Mac. Nothing is exposed to the internet: off your own network, reach this Mac through Tailscale.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private var pairing: some View {
        if let code = link.pairingCode, let expiry = link.pairingExpiresAt, expiry > now {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: code)
                        .font(.system(.title, design: .monospaced))
                        .tracking(6)
                    Text("Type this on your phone — \(Int(expiry.timeIntervalSince(now))) s left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { link.cancelPairing() }
            }
        } else {
            Button("Pair a Phone…") { link.beginPairing() }
        }
    }

    private func lastSeen(_ device: LinkPairedDevice) -> String {
        guard let seen = device.lastSeenAt else {
            return String(localized: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "Last seen \(seen.formatted(.relative(presentation: .named)))")
    }
}
