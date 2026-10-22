import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewFolder: Bool
    @State private var renaming: Folder?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        // Collapsed: a rail of icons; names show as tooltips.
        let compact = !model.sidebarExpanded
        VStack(alignment: .leading, spacing: 0) {
            AppLogo(compact: compact)
                .padding(.top, 46) // clears the window buttons
                .padding(.bottom, 30)
            Group {
                if compact {
                    RailButton(symbol: "magnifyingglass", help: "Search all files") { model.sidebarExpanded = true }
                } else {
                    SearchField(prompt: "Search all files…", text: $model.searchText) {
                        guard !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        model.selection = .search
                        Task { await model.runSearch() }
                    }
                    .help("Search by meaning, e.g. huurcontract")
                }
            }
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
                        VStack(alignment: .leading, spacing: 5) {
                            SidebarSection("General", compact: compact)
                            ForEach(status.categories) { folder in
                                NavRow(folder: folder, compact: compact)
                                    .contextMenu {
                                        Button("Show in Finder") { model.openDrive(folder.name) }
                                        Button("Change Icon…") { model.folderToChangeIcon = folder }
                                        Divider()
                                        Button("Remove Category…", role: .destructive) { model.folderToRemove = folder }
                                    }
                            }
                        }
                        .tourTarget(.categories)
                        SidebarSection("My Smart Folders", compact: compact)
                            .padding(.top, 26)
                        ForEach(status.smartFolders) { folder in
                            NavRow(folder: folder, compact: compact)
                                .contextMenu { smartFolderMenu(folder) }
                        }
                        NewFolderRow(compact: compact) { showingNewFolder = true }
                            .tourTarget(.newFolder)
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 10)
            IndexingCard(compact: compact)
                .tourTarget(.driveStatus)
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.vertical, 10)
            DriveFooter(compact: compact)
                .tourTarget(.driveFooter)
        }
        .padding(.horizontal, compact ? 12 : 14)
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
        Button("Change Icon…") { model.folderToChangeIcon = folder }
        Button("Remove Smart Folder…", role: .destructive) { model.folderToRemove = folder }
    }
}

struct AppLogo: View {
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            // The brand logo ships in the app bundle; `swift run` has no bundle, so it gets a stand-in.
            if let logo = NSImage(named: "SmartDiskLogo") {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [Color(light: 0x80D7B4, dark: 0x80D7B4), Theme.accentFill], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
            }
            if !compact {
                Text("Smart Disk")
                    .font(.system(size: 22, weight: .bold))
                    .fixedSize()
            }
        }
        .padding(.leading, compact ? 0 : 4)
    }
}

struct SidebarSection: View {
    var title: String
    var compact: Bool
    init(_ title: String, compact: Bool = false) {
        self.title = title
        self.compact = compact
    }

    var body: some View {
        if compact {
            // No room for words: a short rule keeps the groups apart.
            Rectangle().fill(Theme.border)
                .frame(width: 20, height: 1)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
        } else {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .fixedSize()
        }
    }
}

/// A square icon button for the collapsed sidebar.
struct RailButton: View {
    var symbol: String
    var help: String
    var color: Color = .secondary
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 44, height: 38)
                .background(hovering ? Theme.navigationSelection : Theme.surfaceMuted, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One folder in the sidebar: icon, name and how many files are in it.
struct NavRow: View {
    @Environment(AppModel.self) private var model
    var folder: Folder
    var compact = false
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == .folder(folder.name)
        Button {
            model.selection = .folder(folder.name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: model.symbol(for: folder))
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(compact && selected ? .primary : .secondary)
                if !compact {
                    Text(folder.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if folder.count > 0 {
                        Text(folder.count.formatted())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 0 : 12)
            .frame(maxWidth: compact ? .infinity : nil)
            .frame(height: 42)
            .background(selected ? Theme.navigationSelection : hovering ? Theme.surfaceMuted : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(compact ? "\(folder.name) (\(folder.count.formatted()))" : "")
        .accessibilityLabel(folder.name)
    }
}

struct NewFolderRow: View {
    var compact = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                if !compact {
                    Text("New Smart Folder")
                    Spacer()
                }
            }
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, compact ? 0 : 10)
            .frame(maxWidth: compact ? .infinity : nil)
            .frame(height: 36)
            .background(hovering ? Theme.surfaceMuted : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(compact ? "New Smart Folder" : "Type what you are looking for; the folder fills itself")
        .accessibilityLabel("New Smart Folder")
    }
}

/// What the drive is doing right now, in one sentence.
struct IndexingCard: View {
    @Environment(AppModel.self) private var model
    var compact = false
    /// Between asking for a check and the drive starting it.
    @State private var checking = false

    var body: some View {
        let s = model.status
        if compact {
            // Just the status dot; a stopped drive starts with a click.
            Button {
                if s?.daemonRunning == false { model.startDaemon() }
            } label: {
                Image(systemName: symbol(s))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color(s))
                    .frame(width: 24, height: 24)
                    .background(color(s).opacity(0.12), in: .circle)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceMuted, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            }
            .buttonStyle(.plain)
            .help(s?.daemonRunning == false ? "\(title(s)). Click to start it." : title(s))
        } else {
            card(s)
        }
    }

    private func card(_ s: DriveStatus?) -> some View {
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
                    .minimumScaleFactor(0.85) // keeps the whole sentence next to the refresh button
                Spacer(minLength: 0)
                if s?.daemonRunning == true && s?.isIndexing == false {
                    refreshButton
                }
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

    /// Checks every folder again now, instead of at the drive's next pass.
    private var refreshButton: some View {
        Button {
            checking = true
            Task {
                await model.rescan()
                // The drive picks the request up within a few seconds; then the card shows its progress.
                try? await Task.sleep(for: .seconds(6))
                checking = false
            }
        } label: {
            Group {
                if checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(checking)
        .help("Check all folders again")
        .accessibilityLabel("Check all folders again")
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
    var compact = false

    var body: some View {
        let status = model.status
        if compact {
            VStack(spacing: 8) {
                RailButton(symbol: status?.mount?.backend == "fuse" ? "externaldrive.fill" : "folder.fill",
                           help: "Open the drive in Finder", color: Theme.accent) { model.openDrive() }
                    .disabled(status?.mount == nil)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        } else {
            row(status)
        }
    }

    private func row(_ status: DriveStatus?) -> some View {
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
