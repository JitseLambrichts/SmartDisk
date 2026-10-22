import SwiftUI

struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    var folder: Folder
    @Binding var showingNewFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                eyebrow: folder.isSmart ? "Smart Folders" : "My Files",
                eyebrowSymbol: model.symbol(for: folder),
                title: folder.name
            ) {
                if folder.isSmart {
                    HStack(spacing: 6) {
                        Text("Looks for")
                        ChipRow(chips: folder.chips)
                    }
                } else {
                    Text("Smart Disk puts files here by itself, after reading what is inside them.")
                }
            } actions: {
                Button {
                    model.openDrive(folder.name)
                } label: {
                    Label("Show in Finder", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.secondary)
                .disabled(model.drivePath == nil)
                .help("Open this folder on the drive in Finder")
                Button {
                    showingNewFolder = true
                } label: {
                    Label("New Smart Folder", systemImage: "plus")
                }
                .buttonStyle(.primary)
                .help("New smart folder: its name is the search")
                Menu {
                    Button("Show in Finder") { model.openDrive(folder.name) }
                        .disabled(model.drivePath == nil)
                    Button("Change Icon…") { model.folderToChangeIcon = folder }
                    Divider()
                    Button(folder.isSmart ? "Remove Smart Folder…" : "Remove Category…", role: .destructive) {
                        model.folderToRemove = folder
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.surface, in: .circle)
                        .overlay(Circle().strokeBorder(Theme.border))
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            FilesCard(items: model.items, folder: folder.name, isLoading: model.isLoadingItems) {
                emptyState
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var emptyState: some View {
        if folder.isSmart {
            ContentUnavailableView {
                Label("Nothing matches yet", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("This folder fills itself as soon as a file matches. When in doubt, a file stays out — a missing file is better than a wrong one.")
            }
        } else if folder.name == "ID Documents" {
            ContentUnavailableView("No ID documents found", systemImage: "person.text.rectangle", description: Text("Scans of identity cards, passports and driving licences appear here."))
        } else {
            ContentUnavailableView("No \(folder.name.lowercased()) yet", systemImage: model.symbol(for: folder), description: Text("Files appear here once they are read and recognised."))
        }
    }
}

struct ChipRow: View {
    var chips: [String]

    var body: some View {
        if chips.isEmpty {
            Text("nothing yet — try a clearer name").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    Chip(text: chip)
                }
            }
        }
    }
}

struct Chip: View {
    var text: String

    var body: some View {
        let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        HStack(spacing: 4) {
            if parts.count == 2 {
                Text(parts[0]).foregroundStyle(Theme.accent.opacity(0.75))
                Text(parts[1]).fontWeight(.semibold)
            } else {
                Text(text).fontWeight(.semibold)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Theme.accentSoft, in: .capsule)
    }
}

// MARK: - File list

enum FileSort: CaseIterable {
    case name, date, amount, match

    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .amount: "Amount"
        case .match: "Fits"
        }
    }
}

/// Tabs only narrow the displayed list; they never change a smart folder's query.
enum FileTab: String, CaseIterable {
    case all = "All Files", documents = "Documents", images = "Images", media = "Media"

    func matches(_ item: Item) -> Bool {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let isImage = item.kind == "image" || ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif", "svg", "bmp", "avif"].contains(ext)
        let isMedia = ["audio", "video"].contains(item.kind) || ["mp3", "m4a", "wav", "aiff", "flac", "ogg", "mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
        switch self {
        case .all: return true
        case .documents:
            return ["pdf", "text", "document"].contains(item.kind) || ["pdf", "txt", "md", "doc", "docx", "pages", "rtf", "odt", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key"].contains(ext)
        case .images: return isImage
        case .media: return isMedia
        }
    }
}

/// A property a file list can be narrowed down by.
enum FileFacet: CaseIterable {
    case type, fits, year, origin

    var title: String {
        switch self {
        case .type: "Type"
        case .fits: "Fits"
        case .year: "Year"
        case .origin: "From"
        }
    }

    var symbol: String {
        switch self {
        case .type: "doc.on.doc"
        case .fits: "checkmark.seal"
        case .year: "calendar"
        case .origin: "folder"
        }
    }

    var flag: String {
        switch self {
        case .type: "--type"
        case .fits: "--fits"
        case .year: "--year"
        case .origin: "--from"
        }
    }

    func value(of item: Item) -> String {
        switch self {
        case .type:
            // "JPG", "PDF", …; files without an extension go by their kind.
            switch (item.name as NSString).pathExtension.uppercased() {
            case "": item.kind.capitalized
            case "JPEG": "JPG"
            case let ext: ext
            }
        case .fits: Confidence(score: item.score).word
        case .year: String(item.displayDate.prefix(4))
        case .origin: item.origin
        }
    }

    /// The order options appear in the menu.
    func sorted(_ values: Set<String>) -> [String] {
        switch self {
        case .fits: Confidence.allCases.map(\.word).filter(values.contains)
        case .year: values.sorted(by: >)
        default: values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}

/// What a file list is narrowed down to. Nothing chosen for a facet means "all".
struct FileFilters: Equatable {
    private var chosen: [FileFacet: Set<String>] = [:]

    var isActive: Bool { chosen.values.contains { !$0.isEmpty } }

    func values(_ facet: FileFacet) -> Set<String> { chosen[facet] ?? [] }

    mutating func toggle(_ value: String, in facet: FileFacet) {
        chosen[facet, default: []].formSymmetricDifference([value])
    }

    mutating func clear(_ facet: FileFacet) { chosen[facet] = nil }

    /// The same choice as `slim mkdir` flags, so a smart folder keeps it.
    var arguments: [String] {
        FileFacet.allCases.flatMap { facet in
            facet.sorted(values(facet)).flatMap { [facet.flag, facet == .origin ? $0 : $0.lowercased()] }
        }
    }

    /// Within one facet any chosen value may match; all facets must match.
    func matches(_ item: Item, ignoring skipped: FileFacet? = nil) -> Bool {
        FileFacet.allCases.allSatisfy { facet in
            facet == skipped || values(facet).isEmpty || values(facet).contains(facet.value(of: item))
        }
    }
}

/// Fixed column widths, shared by the header and every row so they line up.
private enum Column {
    static let date: CGFloat = 116
    static let amount: CGFloat = 100
    static let match: CGFloat = 96
    static let actions: CGFloat = 80
}

/// The white card with the files of a folder or a search.
struct FilesCard<Empty: View>: View {
    @Environment(AppModel.self) private var model
    var items: [Item]
    /// Folder the items are shown in; nil for search results.
    var folder: String?
    var isLoading = false
    @ViewBuilder var empty: Empty
    @State private var filter = ""
    /// Files whose text holds the search words, with a snippet each, and the search they belong to.
    @State private var textHits: (query: String, snippets: [Int64: String]) = ("", [:])
    @State private var searchingText = false
    @State private var filters = FileFilters()
    @State private var sort = FileSort.name
    @State private var ascending = true
    @State private var tab = FileTab.all
    @State private var showingFilters = false
    @State private var width: CGFloat = 1000

    /// Narrow (e.g. with file details open): date and amount move under the name.
    private var compact: Bool { width < 760 }

    var body: some View {
        let named = filtered
        let shown = sorted(named.filter { filters.matches($0) })
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                ForEach(FileTab.allCases, id: \.self) { option in
                    Button {
                        tab = option
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 14, weight: tab == option ? .medium : .regular))
                            .foregroundStyle(tab == option ? .primary : .secondary)
                            .padding(.vertical, 14)
                            .overlay(alignment: .bottom) {
                                if tab == option {
                                    Rectangle().fill(Theme.accent).frame(height: 2)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == option ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1).offset(y: 1)
            }
            .padding(.bottom, 20)

            HStack(spacing: 10) {
                SearchField(prompt: searchPrompt, text: $filter)
                Button {
                    showingFilters.toggle()
                } label: {
                    Label(filters.isActive ? "Filters on" : "Filter", systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(.secondary)
                .accessibilityValue(showingFilters ? "Expanded" : "Collapsed")
                Button {
                    Task {
                        await model.refreshStatus()
                        await model.reloadSelection(keepExplanation: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 38)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Refresh files")
                .accessibilityLabel("Refresh files")
            }
            .padding(.bottom, 18)

            if showingFilters {
                FilterBar(items: named, filters: $filters, showsAllFacets: true)
                    .padding(.bottom, 18)
            }

            HStack(spacing: 10) {
                Text("Sort by:").foregroundStyle(.secondary)
                Menu {
                    ForEach(FileSort.allCases, id: \.self) { option in
                        Button {
                            sort = option
                            ascending = option == .name
                        } label: {
                            if sort == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(sort.title)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button { ascending.toggle() } label: {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(ascending ? "Sort descending" : "Sort ascending")
                .accessibilityLabel(ascending ? "Sort descending" : "Sort ascending")
                Spacer(minLength: 0)
                Text(shown.count == items.count ? "\(shown.count.formatted()) files" : "\(shown.count.formatted()) of \(items.count.formatted()) files")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                Rectangle().fill(Theme.border).frame(height: 1)
                header
                Rectangle().fill(Theme.border).frame(height: 1)

                if items.isEmpty && isLoading {
                    ProgressView("Looking…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    empty.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty && (filters.isActive || tab != .all) {
                    ContentUnavailableView {
                        Label("No files match these filters", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try fewer filters, or show everything again.")
                    } actions: {
                        Button("Clear Filters") {
                            filters = FileFilters()
                            filter = ""
                            tab = .all
                        }
                        .buttonStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else if shown.isEmpty && !filter.isEmpty && searchingText {
                    ProgressView("Searching inside documents…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty && !filter.isEmpty {
                    ContentUnavailableView.search(text: filter)
                        .frame(maxHeight: .infinity)
                } else {
                    let snippets = currentSnippets
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { item in
                                FileRow(item: item, folder: folder, compact: compact, snippet: snippets[item.id])
                                Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: folder) {
            filters = FileFilters()
            filter = ""
            tab = .all
            showingFilters = false
        }
        .task(id: "\(folder ?? "")\u{0}\(filter)") { await searchText() }
    }

    private var searchesText: Bool { model.status?.config.storeFullText != false }

    private var searchPrompt: String {
        switch (searchesText, folder != nil) {
        case (true, true): "Search names and text in this folder…"
        case (true, false): "Search names and text…"
        case (false, true): "Search files in this folder…"
        case (false, false): "Search files…"
        }
    }

    /// Text hits for what is typed now; older ones are dropped so they never show under a new search.
    private var currentSnippets: [Int64: String] {
        textHits.query == filter.trimmingCharacters(in: .whitespaces) ? textHits.snippets : [:]
    }

    /// Looks inside the documents too, once typing pauses. Names still filter right away.
    private func searchText() async {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, searchesText, let client = model.client else {
            textHits = (text, [:])
            searchingText = false
            return
        }
        searchingText = true
        defer { if !Task.isCancelled { searchingText = false } }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let hits = (try? await client.grep(text, folder: folder)) ?? []
        guard !Task.isCancelled else { return }
        textHits = (text, Dictionary(hits.map { ($0.fileId, $0.snippet) }, uniquingKeysWith: { first, _ in first }))
    }

    private var header: some View {
        HStack(spacing: 12) {
            sortButton("File name", .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                sortButton("Date", .date)
                    .frame(width: Column.date, alignment: .leading)
                sortButton("Amount", .amount)
                    .frame(width: Column.amount, alignment: .leading)
            }
            sortButton("Fits", .match)
                .frame(width: Column.match, alignment: .leading)
                .help("How sure Smart Disk is that the file belongs here")
            Text("Actions")
                .frame(width: Column.actions, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(Theme.surfaceMuted)
    }

    private func sortButton(_ title: String, _ key: FileSort) -> some View {
        Button {
            if sort == key {
                ascending.toggle()
            } else {
                sort = key
                ascending = key == .name
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: sort == key ? (ascending ? "chevron.up" : "chevron.down") : "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(sort == key ? Theme.accent : Color.secondary.opacity(0.6))
            }
            .foregroundStyle(sort == key ? .primary : .secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [Item] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        let inText = currentSnippets
        return items.filter {
            tab.matches($0) && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)
                || $0.origin.localizedCaseInsensitiveContains(text) || inText[$0.id] != nil)
        }
    }

    private func sorted(_ items: [Item]) -> [Item] {
        let result: [Item] = switch sort {
        case .name: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: items.sorted { $0.displayDate < $1.displayDate }
        case .amount: items.sorted { ($0.amount ?? -1) < ($1.amount ?? -1) }
        case .match: items.sorted { $0.score < $1.score }
        }
        return ascending ? result : result.reversed()
    }
}

/// One filter pill per facet that has something to choose, and a way to undo them.
/// Shows nothing when every file looks the same, unless `showsAllFacets` is set.
struct FilterBar: View {
    var items: [Item]
    @Binding var filters: FileFilters
    /// Every facet, even when the files all look the same, so people see what they can narrow by.
    var showsAllFacets = false

    /// Facets worth a pill: something is chosen, or the files differ.
    static func facets(of items: [Item], _ filters: FileFilters) -> [FileFacet] {
        FileFacet.allCases.filter { facet in
            !filters.values(facet).isEmpty || Set(items.map(facet.value(of:))).count > 1
        }
    }

    var body: some View {
        let facets = showsAllFacets ? FileFacet.allCases : Self.facets(of: items, filters)
        if !facets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    menus(facets)
                    VStack(alignment: .leading, spacing: 8) {
                        menus(Array(facets.prefix(2)))
                        menus(Array(facets.dropFirst(2)))
                    }
                }
                if filters.isActive {
                    Button("Clear Filters") { filters = FileFilters() }
                        .buttonStyle(TextActionStyle(color: Theme.accent))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func menus(_ facets: [FileFacet]) -> some View {
        HStack(spacing: 8) {
            ForEach(facets, id: \.self) { facet in
                FilterMenu(facet: facet, items: items.filter { filters.matches($0, ignoring: facet) }, filters: $filters)
            }
            if !facets.isEmpty {
                Spacer()
            }
        }
    }
}

/// A pill that opens a panel of one facet's values, with how many files each keeps.
/// The panel stays open while you tick boxes; click outside it to close.
private struct FilterMenu: View {
    var facet: FileFacet
    /// The files the other filters leave, so the counts say what you will get.
    var items: [Item]
    @Binding var filters: FileFilters
    @State private var isOpen = false

    var body: some View {
        let chosen = filters.values(facet)
        Button {
            isOpen.toggle()
        } label: {
            label(chosen)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show only some files, by \(facet.title.lowercased())")
        // Anchored to the pill's fixed left end, so the panel does not move
        // under the pointer when ticking a box changes the pill's width.
        .popover(isPresented: $isOpen, attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: 44, height: 28))), arrowEdge: .bottom) {
            panel
        }
    }

    private var panel: some View {
        let counts = Dictionary(grouping: items, by: facet.value(of:)).mapValues(\.count)
        let chosen = filters.values(facet)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(facet.title).font(.headline)
                Spacer()
                Button("Show All") { filters.clear(facet) }
                    .buttonStyle(TextActionStyle(color: Theme.accent))
                    .disabled(chosen.isEmpty)
                    .opacity(chosen.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(facet.sorted(Set(counts.keys).union(chosen)), id: \.self) { value in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(value) },
                            set: { _ in filters.toggle(value, in: facet) }
                        )) {
                            HStack {
                                Text(value).lineLimit(1)
                                Spacer(minLength: 16)
                                Text(counts[value, default: 0].formatted())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(width: 240)
    }

    private func label(_ chosen: Set<String>) -> some View {
        let active = !chosen.isEmpty
        let text = switch chosen.count {
        case 0: facet.title
        case 1: "\(facet.title): \(chosen.first!)"
        default: "\(facet.title): \(chosen.count)"
        }
        return HStack(spacing: 6) {
            Image(systemName: facet.symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.7)
        }
        .font(.caption.weight(active ? .semibold : .medium))
        .foregroundStyle(active ? Theme.accent : .secondary)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(active ? Theme.accentSoft : Theme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(active ? Theme.accent.opacity(0.35) : Theme.border))
        .contentShape(.capsule)
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    var item: Item
    var folder: String?
    var compact = false
    /// Words around a search hit inside the document.
    var snippet: String?
    @State private var hovering = false

    private var details: String {
        var parts = [item.size.formatted(.byteCount(style: .file))]
        if compact {
            parts.append(formatDate(item.displayDate))
            if let amount = item.amount {
                parts.append(amount.formatted(.currency(code: item.currency ?? "EUR")))
            }
        }
        parts.append("from \(item.origin)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let selected = model.selectedItemID == item.id
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                FileIcon(path: item.original)
                    .scaledToFit()
                    .frame(width: 24, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let snippet, !snippet.isEmpty {
                        Label(snippet, systemImage: "text.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(snippet)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !compact {
                Text(formatDate(item.displayDate))
                    .font(.callout)
                    .foregroundStyle(item.docDate == nil ? .secondary : .primary)
                    .help(item.docDate == nil ? "File date (no date found in the document)" : "Date found in the document")
                    .frame(width: Column.date, alignment: .leading)

                Group {
                    if let amount = item.amount {
                        Text(amount, format: .currency(code: item.currency ?? "EUR"))
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .frame(width: Column.amount, alignment: .leading)
            }

            ConfidenceTag(score: item.score)
                .frame(width: Column.match, alignment: .leading)

            HStack(spacing: 12) {
                Button("Open") { model.open(item) }
                    .buttonStyle(TextActionStyle(color: Theme.accent))
                Menu {
                    Button("Show Original in Finder") { model.reveal(item) }
                    if let folder {
                        Divider()
                        Button("Doesn't Belong Here") {
                            Task { await model.label(item, in: folder, belongs: false) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions for \(item.name)")
            }
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: snippet?.isEmpty == false ? 78 : 64) // a search snippet adds a line
        .background(selected ? Theme.accentSoft.opacity(0.7) : hovering ? Theme.surfaceMuted : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Theme.accent).frame(width: 3)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { model.selectedItemID = selected ? nil : item.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.open(item) })
        .contextMenu {
            Button("Open") { model.open(item) }
            Button("Show Original in Finder") { model.reveal(item) }
            if let folder {
                Divider()
                Button("Doesn't Belong Here") {
                    Task { await model.label(item, in: folder, belongs: false) }
                }
            }
        }
    }
}

struct ScoreBar: View {
    var score: Double

    var body: some View {
        HStack(spacing: 6) {
            Gauge(value: min(max(score, 0), 1)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(score >= 0.75 ? Theme.success : score >= 0.5 ? Theme.warning : .orange)
                .frame(width: 44)
            Text(score, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("How sure the drive is that this file belongs here")
    }
}

struct FileIcon: View {
    var path: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
    }
}

func formatDate(_ iso: String) -> String {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    guard let date = parser.date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .omitted)
}

// MARK: - Search

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewFolder: Bool
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(eyebrow: "Search", eyebrowSymbol: "magnifyingglass", title: "“\(model.searchText)”") {
                HStack(spacing: 6) {
                    Text("Understood as")
                    ChipRow(chips: model.searchResult?.chips ?? [])
                }
            } actions: {
                Button {
                    model.searchText = ""
                } label: {
                    Label("Clear Search", systemImage: "xmark")
                }
                .buttonStyle(.secondary)
                Button {
                    Task {
                        saving = true
                        _ = await model.createSmartFolder(model.searchText)
                        model.searchText = ""
                        saving = false
                    }
                } label: {
                    Label("Save as Smart Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.primary)
                .disabled(saving || model.searchText.isEmpty)
                .help("Keep this search as a folder that fills itself")
            }
            FilesCard(items: model.searchResult?.items ?? [], folder: nil, isLoading: model.isSearching) {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
    }
}
