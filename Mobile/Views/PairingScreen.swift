import AnimeGodCore
import SwiftUI

/// Pairing: find the Mac, type the code it is showing.
struct PairingScreen: View {
    @EnvironmentObject private var model: MobileModel
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var code = ""
    @State private var probe: LinkHealth?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.resolver.discovered.isEmpty {
                        HStack {
                            Text("Looking for Macs on this Wi-Fi…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        ForEach(model.resolver.discovered) { found in
                            Button {
                                guard let address = found.host else { return }
                                host = address
                                Task { await check() }
                            } label: {
                                HStack {
                                    Label(found.name, systemImage: "desktopcomputer")
                                    Spacer()
                                    if found.host == nil {
                                        ProgressView().controlSize(.small)
                                    } else if host == found.host {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .disabled(found.host == nil)
                        }
                    }
                } header: {
                    Text("Found nearby")
                } footer: {
                    Text("Nothing here? Plenty of networks block the discovery this uses — student halls especially. Type the address AnimeGod shows on your Mac instead.")
                }

                Section("Address") {
                    TextField("192.168.1.10:47380", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { Task { await check() } }
                    if let probe {
                        LabeledContent(probe.name) {
                            Label(
                                probe.isPairing ? "Ready to pair" : "Not pairing",
                                systemImage: probe.isPairing ? "checkmark.circle" : "exclamationmark.circle"
                            )
                            .foregroundStyle(probe.isPairing ? .green : .orange)
                        }
                    }
                }

                Section {
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .monospaced))
                } header: {
                    Text("Code")
                } footer: {
                    Text("On your Mac: AnimeGod → Settings → iPhone → Pair a Phone.")
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Pair")
                            Spacer()
                            if isWorking { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(host.isEmpty || code.count != 6 || isWorking)
                }
            }
            .navigationTitle("Pair with a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                model.resolver.startBrowsing()
            }
            .onDisappear { model.resolver.stopBrowsing() }
        }
    }

    private func check() async {
        probe = try? await LinkClient.probe(host: host)
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.pair(host: host, code: code)
            dismiss()
        } catch let failure as LinkError {
            error = failure.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}
