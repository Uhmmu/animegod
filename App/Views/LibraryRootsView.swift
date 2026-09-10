import SwiftUI

struct LibraryRootsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            ForEach(model.roots) { root in
                HStack {
                    Image(systemName: "externaldrive")
                    VStack(alignment: .leading) {
                        Text(root.displayName)
                        Text(root.lastKnownPath).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Scan") { Task { await model.scan(root) } }
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
