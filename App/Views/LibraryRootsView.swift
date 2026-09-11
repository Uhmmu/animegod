import AnimeGodCore
import SwiftUI

struct LibraryRootsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            ForEach(model.roots) { root in
                let isAvailable = model.availableRootIDs.contains(root.id)
                HStack {
                    Image(systemName: isAvailable ? "externaldrive" : "externaldrive.badge.exclamationmark")
                        .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
                    VStack(alignment: .leading) {
                        Text(root.displayName)
                        if isAvailable {
                            Text(root.lastKnownPath).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not connected — entries stay indexed; playback needs the drive or a cached copy.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Scan") { Task { await model.scan(root) } }
                        .disabled(!isAvailable)
                    Button(role: .destructive) { Task { await model.remove(root) } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this source from AnimeGod. Files are never deleted.")
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Library Folders")
        .overlay {
            if model.roots.isEmpty {
                ContentUnavailableView {
                    Label("No Library Folders", systemImage: "folder")
                } actions: {
                    Button("Add Folder…") { model.chooseLibraryRoot() }
                }
            }
        }
    }
}
