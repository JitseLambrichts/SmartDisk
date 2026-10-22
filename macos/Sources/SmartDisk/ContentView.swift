import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewFolder = false

    var body: some View {
        // A plain row of fixed-width columns instead of a split view: nothing here
        // resizes with its content, so AppKit never loops on window constraints.
        HStack(spacing: 0) {
            // Collapsed, the sidebar keeps a narrow rail of icons.
            SidebarView(showingNewFolder: $showingNewFolder)
                .frame(width: model.sidebarExpanded ? 252 : 68)
            HStack(spacing: 0) {
                detail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if model.selectedItemID != nil {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    InspectorView()
                        .frame(width: 292)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Theme.surface)
            .clipShape(.rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
            .padding(.top, 36)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        }
        .background(Theme.canvas)
        .overlay(alignment: .topLeading) {
            SidebarToggle()
                .padding(.leading, 78) // right of the window buttons
                .padding(.top, 3)
        }
        .animation(.snappy(duration: 0.25), value: model.selectedItemID != nil)
        .animation(.snappy(duration: 0.25), value: model.sidebarExpanded)
        .ignoresSafeArea(edges: .top)
        .tint(Theme.accent)
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
        .sheet(isPresented: $showingNewFolder) {
            NewSmartFolderSheet()
        }
        .focusedSceneValue(\.newSmartFolder) { showingNewFolder = true }
        .focusedSceneValue(\.sidebarExpanded, Binding(get: { model.sidebarExpanded }, set: { model.sidebarExpanded = $0 }))
        .alert(
            model.folderToRemove.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { model.folderToRemove != nil }, set: { if !$0 { model.folderToRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let folder = model.folderToRemove {
                    Task { await model.removeFolder(folder.name) }
                }
                model.folderToRemove = nil
            }
            Button("Cancel", role: .cancel) { model.folderToRemove = nil }
        } message: {
            if model.folderToRemove?.isSmart == true {
                Text("Only the folder disappears. Your files stay exactly where they are.")
            } else {
                Text("Only the folder disappears. Your files stay exactly where they are. You can bring it back in Settings → Categories.")
            }
        }
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
            SearchResultsView(showingNewFolder: $showingNewFolder)
        } else if let folder = model.selectedFolder {
            FolderDetailView(folder: folder, showingNewFolder: $showingNewFolder)
        } else {
            WelcomeView(showingNewFolder: $showingNewFolder)
        }
    }
}

/// Collapses the sidebar to its icons or expands it again, next to the window buttons like in Finder.
struct SidebarToggle: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.sidebarExpanded.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(hovering ? Theme.navigationSelection : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(model.sidebarExpanded ? "Collapse Sidebar (⌃⌘S)" : "Expand Sidebar (⌃⌘S)")
        .accessibilityLabel(model.sidebarExpanded ? "Collapse Sidebar" : "Expand Sidebar")
    }
}

// MARK: - Page layout

/// The title block at the top of every page: a small label, a big title and the main actions.
struct PageHeader<Actions: View, Subtitle: View>: View {
    var eyebrow: String
    var eyebrowSymbol: String
    var title: String
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions
    @State private var width: CGFloat = 1000

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Label("On this Mac", systemImage: "lock")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(eyebrow)
            }
            .font(.callout)
            if width >= 740 {
                HStack(spacing: 16) {
                    pageTitle
                    Spacer(minLength: 20)
                    actions
                        .fixedSize()
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    pageTitle
                    HStack(spacing: 8) { actions }
                }
            }
            subtitle
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var pageTitle: some View {
        Text(title)
            .font(.system(size: 28, weight: .bold))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewFolder: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(eyebrow: "Welcome", eyebrowSymbol: "hand.wave", title: "Folders that fill themselves") {
                    Text("Your files stay exactly where they are. Smart Disk reads what is inside them and shows each file in the folders where it belongs.")
                } actions: {
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("New Smart Folder", systemImage: "plus")
                    }
                    .buttonStyle(.primary)
                }
                HStack(spacing: 16) {
                    PromiseCard(symbol: "arrow.left.arrow.right", title: "Never moved", text: "Originals are never moved, copied or changed.")
                    PromiseCard(symbol: "lock", title: "Stays on your Mac", text: "Text recognition and search run on your Mac.")
                    PromiseCard(symbol: "person.crop.circle.badge.xmark", title: "No account", text: "No sign-up, no tracking, no cloud.")
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

struct PromiseCard: View {
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: .circle)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .card()
    }
}
