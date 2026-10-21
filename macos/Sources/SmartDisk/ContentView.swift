import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewFolder = false
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        // Every split-view column gets a fixed minimum size. Otherwise a column's
        // minimum follows its content, and content that changes while AppKit
        // updates constraints (status arriving at launch) loops until it crashes.
        NavigationSplitView {
            SidebarView(showingNewFolder: $showingNewFolder)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(minWidth: 360, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search by meaning, e.g. huurcontract")
        .onSubmit(of: .search) {
            model.selection = .search
            Task { await model.runSearch() }
        }
        .onChange(of: model.searchText) { _, text in
            if text.isEmpty, model.selection == .search {
                model.selection = model.status?.folders.first.map { .folder($0.name) }
            }
        }
        .onChange(of: model.selection) { _, _ in
            Task { await model.reloadSelection() }
        }
        .onChange(of: model.selectedItemID) { _, _ in
            Task { await model.explain(model.selectedItem) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                StatusPill()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingNewFolder = true
                } label: {
                    Label("New Smart Folder", systemImage: "folder.badge.plus")
                }
                .help("New smart folder: its name is the search query")
                Button {
                    model.openDrive(model.selectedFolder?.name)
                } label: {
                    Label("Show in Finder", systemImage: "macwindow.on.rectangle")
                }
                .help("Open this folder on the drive in Finder")
                .disabled(model.drivePath == nil)
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Why", systemImage: "sidebar.trailing")
                }
                .help("Show why a file is here")
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            NewSmartFolderSheet()
        }
        .focusedSceneValue(\.newSmartFolder) { showingNewFolder = true }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.client == nil {
            ContentUnavailableView {
                Label("The slim command was not found", systemImage: "terminal")
            } description: {
                Text("Build it with `cargo build --release` in the project folder, or set SLIM_BIN.")
            }
        } else if model.status == nil {
            ProgressView("Connecting to the drive…")
        } else if model.selection == .search {
            SearchResultsView()
        } else if let folder = model.selectedFolder {
            FolderDetailView(folder: folder)
        } else {
            WelcomeView(showingNewFolder: $showingNewFolder)
        }
    }
}

// MARK: - Status

struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A fixed size: a toolbar item that resizes while the window lays out
        // can send AppKit into an update-constraints loop.
        HStack(spacing: 8) {
            if let s = model.status {
                if s.isIndexing {
                    ProgressView(value: Double(s.progressDone), total: Double(max(s.progressTotal, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("Indexing \(s.progressDone) of \(s.progressTotal)")
                } else {
                    Circle()
                        .fill(color(for: s.state))
                        .frame(width: 8, height: 8)
                    Text(label(for: s))
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(width: 230, height: 28, alignment: .leading)
    }

    private func color(for state: String) -> Color {
        switch state {
        case "idle": .green
        case "paused", "battery": .orange
        default: .red
        }
    }

    private func label(for s: DriveStatus) -> String {
        switch s.state {
        case "idle": "\(s.filesIndexed.formatted()) files · up to date"
        case "paused": "Paused"
        case "battery": "Paused on battery"
        case "stopped": "Drive stopped"
        default: s.state.capitalized
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewFolder: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating)
            VStack(spacing: 8) {
                Text("Folders that fill themselves")
                    .font(.largeTitle.weight(.semibold))
                Text("Your files stay exactly where they are. The Smart Disk only shows views.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                PromiseCard(symbol: "arrow.left.arrow.right.circle", title: "Never moved", text: "Originals are never moved, copied or changed.")
                PromiseCard(symbol: "lock.laptopcomputer", title: "Stays on your Mac", text: "Text recognition and search run on device.")
                PromiseCard(symbol: "person.crop.circle.badge.xmark", title: "No account", text: "No sign-up, no telemetry, no cloud.")
            }
            .frame(maxWidth: 720)
            Button {
                showingNewFolder = true
            } label: {
                Label("Make a Smart Folder", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PromiseCard: View {
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
