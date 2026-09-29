import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: MobileModel

    var body: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    LabeledContent("Status") {
                        Text(model.isPaired ? "Mirror seeded by hand" : "Not paired")
                            .foregroundStyle(model.isPaired ? .orange : .secondary)
                    }
                    Button("Pair with a Mac…") {}
                        .disabled(true)
                }

                Section {
                    TransportRow(name: "Bonjour / same Wi-Fi", icon: "wifi", rank: 1)
                    TransportRow(name: "Pinned LAN address", icon: "network", rank: 2)
                    TransportRow(name: "Tailscale", icon: "lock.shield", rank: 3)
                    TransportRow(name: "Peer-to-peer Wi-Fi", icon: "dot.radiowaves.left.and.right", rank: 4)
                } header: {
                    Text("Transports")
                } footer: {
                    Text("Every transport produces the same thing: a URL that reaches the Mac. The resolver races them and keeps the first that answers. None are implemented yet — Phase 1 and Phase 6.")
                }

                Section("Library") {
                    LabeledContent("Works", value: "\(model.library.count)")
                    LabeledContent("In progress", value: "\(model.continueWatching.count)")
                }

                Section {
                    LabeledContent("Build", value: "Preview — Phase 2 screens only")
                    LabeledContent("Playback", value: "Not built (Phase 3)")
                } footer: {
                    Text("Design: docs/IOS_COMPANION_PLAN.md")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct TransportRow: View {
    let name: String
    let icon: String
    let rank: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            Text(name)
            Spacer()
            Text("#\(rank)").font(.caption2).foregroundStyle(.tertiary)
            Image(systemName: "circle").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
