import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewFolder: Bool
    @State private var renaming: Folder?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            AppLogo()
                .padding(.top, 46) // clears the window buttons
                .padding(.bottom, 30)
            SearchField(prompt: "Search all files…", text: $model.searchText) {
                guard !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                model.selection = .search
                Task { await model.runSearch() }
            }
            .help("Search by meaning, e.g. huurcontract")
            .padding(.bottom, 28)
            .task(id: model.searchText) {
                // Search while typing, once the user pauses.
                guard !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                if model.selection == .search {
                    await model.runSearch()
                } else {
                    model.selection = .search // reloading the selection runs the search
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if let status = model.status {
                        SidebarSection("General")
                        ForEach(status.categories) { folder in
                            NavRow(folder: folder)
                                .contextMenu {
                                    Button("Show in Finder") { model.openDrive(folder.name) }
                                    Divider()
                                    Button("Remove Category…", role: .destructive) { model.folderToRemove = folder }
                                }
                        }
                        SidebarSection("My Smart Folders")
                            .padding(.top, 26)
                        ForEach(status.smartFolders) { folder in
                            NavRow(folder: folder)
                                .contextMenu { smartFolderMenu(folder) }
                        }
                        NewFolderRow { showingNewFolder = true }
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 10)
            IndexingCard()
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.vertical, 10)
            DriveFooter()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity)
        .background(Theme.canvas)
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
            Text("The new name becomes the new search; the folder refills itself.")
        }
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
        Button("Remove Smart Folder…", role: .destructive) { model.folderToRemove = folder }
    }
}

struct AppLogo: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(colors: [Color(light: 0x80D7B4, dark: 0x80D7B4), Theme.accentFill], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .circle
                )
            Text("Smart Disk")
                .font(.system(size: 22, weight: .bold))
        }
        .padding(.leading, 4)
    }
}

struct SidebarSection: View {
    var title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }
}

/// One folder in the sidebar: icon, name and how many files are in it.
struct NavRow: View {
    @Environment(AppModel.self) private var model
    var folder: Folder
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == .folder(folder.name)
        Button {
            model.selection = .folder(folder.name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: folder.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(folder.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if folder.count > 0 {
                    Text(folder.count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(selected ? Theme.navigationSelection : hovering ? Theme.surfaceMuted : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct NewFolderRow: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                Text("New Smart Folder")
                Spacer()
            }
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(hovering ? Theme.surfaceMuted : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Type what you are looking for; the folder fills itself")
    }
}

/// What the drive is doing right now, in one sentence.
struct IndexingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol(s))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color(s))
                    .frame(width: 24, height: 24)
                    .background(color(s).opacity(0.12), in: .circle)
                Text(title(s))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .help(s.map(detail) ?? "")
            if let s, s.isIndexing {
                let fraction = Double(s.progressDone) / Double(max(s.progressTotal, 1))
                Capsule()
                    .fill(Theme.border)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Theme.accent)
                                .frame(width: max(6, proxy.size.width * min(fraction, 1)))
                        }
                    }
                    .animation(.snappy, value: fraction)
                Text("\(s.progressDone.formatted()) of \(s.progressTotal.formatted()) files read")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if s?.daemonRunning == false {
                Button("Start Smart Disk") { model.startDaemon() }
                    .buttonStyle(.primary)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surfaceMuted, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func symbol(_ s: DriveStatus?) -> String {
        switch s?.state {
        case "indexing": "arrow.triangle.2.circlepath"
        case "idle": "checkmark"
        case "paused", "battery": "pause.fill"
        default: "exclamationmark"
        }
    }

    private func color(_ s: DriveStatus?) -> Color {
        switch s?.state {
        case "indexing": Theme.accent
        case "idle": Theme.success
        case "paused", "battery": Theme.warning
        default: Theme.danger
        }
    }

    private func title(_ s: DriveStatus?) -> String {
        switch s?.state {
        case nil: "Connecting…"
        case "indexing": "Reading your files"
        case "idle": "Everything is up to date"
        case "paused": "Paused"
        case "battery": "Paused on battery"
        case "stopped": "Smart Disk is stopped"
        default: s!.state.capitalized
        }
    }

    private func detail(_ s: DriveStatus) -> String {
        switch s.state {
        case "idle": return "\(s.filesIndexed.formatted()) files sorted. New files are picked up by themselves."
        case "paused", "battery": return "Resume reading in Settings."
        default: return "Start it to keep your folders filled."
        }
    }
}

/// The drive itself, pinned to the bottom of the sidebar.
struct DriveFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.status
        HStack(spacing: 10) {
            Image(systemName: status?.mount?.backend == "fuse" ? "externaldrive.fill" : "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text("Slim drive")
                    .font(.callout.weight(.semibold))
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
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open the drive in Finder")
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private func subtitle(_ status: DriveStatus?) -> String {
        guard let status else { return "Connecting…" }
        if let mount = status.mount {
            return (mount.path as NSString).abbreviatingWithTildeInPath
        }
        return status.daemonRunning ? "Not mounted" : "Not running"
    }
}
