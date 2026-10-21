import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewFolder: Bool
    @State private var renaming: Folder?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if let status = model.status {
                Section("Categories") {
                    ForEach(status.categories) { folder in
                        row(folder)
                    }
                }
                Section {
                    ForEach(status.smartFolders) { folder in
                        row(folder)
                            .contextMenu { smartFolderMenu(folder) }
                    }
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("New Smart Folder…", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Smart Folders")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            DriveCard()
                .padding(10)
        }
        .alert("Rename Smart Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Folder name", text: $newName)
            Button("Rename") {
                if let folder = renaming {
                    Task { await model.renameSmartFolder(folder.name, to: newName) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The new name becomes the new query; the contents are recomputed.")
        }
    }

    private func row(_ folder: Folder) -> some View {
        Label {
            Text(folder.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: folder.symbol)
                .foregroundStyle(folder.isSmart ? AnyShapeStyle(.purple) : AnyShapeStyle(.tint))
        }
        .badge(folder.count)
        .tag(SidebarItem.folder(folder.name))
    }

    @ViewBuilder
    private func smartFolderMenu(_ folder: Folder) -> some View {
        Button("Show in Finder") { model.openDrive(folder.name) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.drivePath(for: folder.name) ?? folder.name, forType: .string)
        }
        Divider()
        Button("Rename…") {
            newName = folder.name
            renaming = folder
        }
        Button("Remove Smart Folder", role: .destructive) {
            Task { await model.deleteSmartFolder(folder.name) }
        }
    }
}

/// The drive itself, pinned to the bottom of the sidebar.
struct DriveCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.status
        HStack(spacing: 10) {
            Image(systemName: status?.mount?.backend == "fuse" ? "externaldrive.fill" : "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slim")
                    .font(.headline)
                Text(subtitle(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if status?.mount != nil {
                Button {
                    model.openDrive()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open the drive in Finder")
            } else if status?.daemonRunning == false {
                Button("Start") { model.startDaemon() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func subtitle(_ status: DriveStatus?) -> String {
        guard let status else { return "Connecting…" }
        if let mount = status.mount {
            return (mount.path as NSString).abbreviatingWithTildeInPath
        }
        return status.daemonRunning ? "Not mounted" : "Not running"
    }
}
