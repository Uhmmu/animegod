import AnimeGodCore
import SwiftUI

/// Settings → Online Sources: which rules are installed, and the shop they
/// come from.
///
/// Separate from the Online section itself because installing a rule is
/// configuration, while searching is a thing you do — and because the
/// section's empty state has to be able to point somewhere.
struct OnlineSourceSettings: View {
    @ObservedObject var online: OnlineCoordinator
    @State private var showingShop = false
    @State private var showingImport = false
    @State private var importText = ""
    @State private var updateSummary: String?
    @State private var isUpdating = false

    var body: some View {
        Section("Online Sources") {
            Text("A source is a short rule describing how one site lists its shows — at most five selectors and a URL. Rules are shared in the format Kazumi uses, so one written for that app works here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if online.rules.isEmpty {
                Text("None installed.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(online.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                            Text(ruleSummary(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if rule.requiresNewerClient {
                            Label("Needs a newer AnimeGod", systemImage: "arrow.up.circle")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.blue)
                                .help(String(localized: "This rule is written for schema \(rule.api); this build reads \(OnlineSourceRule.supportedAPILevel)."))
                        }
                        Button(role: .destructive) {
                            Task { await online.remove(rule) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if online.unreadableRules > 0 {
                // Said rather than swallowed: a source that silently vanishes
                // looks like the app lost it.
                Label(
                    "^[\(online.unreadableRules) rule](inflect: true) in the rules file could not be read and was left alone.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                Button("Browse Rules…") {
                    showingShop = true
                    Task { await online.refreshCatalog() }
                }
                Button("Update All") {
                    isUpdating = true
                    Task {
                        let result = await online.updateAll()
                        isUpdating = false
                        updateSummary = result.updated == 0 && result.failed == 0
                            ? String(localized: "Every rule is already up to date.")
                            : String(localized: "Updated \(result.updated); \(result.failed) failed.")
                    }
                }
                .disabled(online.rules.isEmpty || isUpdating)
                if isUpdating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Import…") { showingImport = true }
            }

            if let updateSummary {
                Text(updateSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingShop) { shop }
        .sheet(isPresented: $showingImport) { importSheet }
    }

    private func ruleSummary(_ rule: OnlineSourceRule) -> String {
        let host = URL(string: rule.baseURL)?.host ?? rule.baseURL
        return "v\(rule.version) · \(host)"
    }

    // MARK: - The shop

    private var shop: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Rules").font(.headline)
                Spacer()
                if online.isLoadingCatalog { ProgressView().controlSize(.small) }
                Button("Done") { showingShop = false }
            }
            .padding(12)

            Divider()

            if online.catalogItems.isEmpty, !online.isLoadingCatalog {
                ContentUnavailableView {
                    Label("The rule catalog could not be reached", systemImage: "icloud.slash")
                } description: {
                    Text("The catalog is a file on GitHub, which is not reachable from every network. Try the mirror, or import a rule by hand.")
                } actions: {
                    Button("Try the Mirror") { Task { await online.refreshCatalog(useMirror: true) } }
                }
            } else {
                List(online.catalogItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            if let updated = item.updatedAt {
                                Text("v\(item.version) · updated \(updated.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("v\(item.version)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if online.hasUpdate(item) {
                            Button("Update") { Task { await online.install(item) } }
                        } else if online.isInstalled(item) {
                            Text("Installed").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Install") { Task { await online.install(item) } }
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 420)
    }

    // MARK: - Importing

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a rule").font(.headline)
            Text("A rule is shared as JSON, as a list of them, or as a base64 blob out of a chat message. Any of the three works.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $importText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 200)
                .border(.separator)
            HStack {
                Button("Copy Installed Rules") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(online.exportRules(), forType: .string)
                }
                .disabled(online.rules.isEmpty)
                Spacer()
                Button("Cancel") { showingImport = false; importText = "" }
                Button("Import") {
                    let text = importText
                    Task {
                        await online.importRules(from: text)
                        importText = ""
                        showingImport = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
