import SwiftUI

struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    var folder: Folder
    @Binding var showingNewFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                eyebrow: folder.isSmart ? "Smart Folder" : "Category",
                eyebrowSymbol: folder.isSmart ? "sparkle.magnifyingglass" : folder.symbol,
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
            }
            FilesCard(items: model.items, folder: folder.name, isLoading: model.isLoadingItems) {
                emptyState
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
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
            ContentUnavailableView("No \(folder.name.lowercased()) yet", systemImage: folder.symbol, description: Text("Files appear here once they are read and recognised."))
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

enum FileSort: Equatable {
    case name, date, amount, match
}

/// Fixed column widths, shared by the header and every row so they line up.
private enum Column {
    static let date: CGFloat = 116
    static let amount: CGFloat = 100
    static let match: CGFloat = 96
    static let actions: CGFloat = 128
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
    @State private var sort = FileSort.match
    @State private var ascending = false
    @State private var width: CGFloat = 1000

    /// Narrow (e.g. with file details open): date and amount move under the name.
    private var compact: Bool { width < 820 }

    var body: some View {
        let shown = sorted(filtered)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Files").font(.headline)
                        CountBadge(text: "\(items.count.formatted()) total", highlighted: true)
                    }
                    Text("Click a file to see why it is here. Double-click to open it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SearchField(prompt: "Filter by name…", text: $filter)
                    .frame(maxWidth: 240)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(Theme.border).frame(height: 1)
            header
            Rectangle().fill(Theme.border).frame(height: 1)

            if items.isEmpty && isLoading {
                ProgressView("Looking…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty && !filter.isEmpty {
                ContentUnavailableView.search(text: filter)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { item in
                            FileRow(item: item, folder: folder, compact: compact)
                            Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .card()
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
        guard !text.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.origin.localizedCaseInsensitiveContains(text) }
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

struct FileRow: View {
    @Environment(AppModel.self) private var model
    var item: Item
    var folder: String?
    var compact = false
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
                FileTypeIcon(name: item.name, kind: item.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

            HStack(spacing: 14) {
                if let folder {
                    Button("Not here") {
                        Task { await model.label(item, in: folder, belongs: false) }
                    }
                    .buttonStyle(TextActionStyle(color: Theme.danger))
                    .help("Remove it from this folder only. The original file stays where it is.")
                }
                Button("Open") { model.open(item) }
                    .buttonStyle(TextActionStyle(color: Theme.accent))
            }
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
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
        .padding(.top, 40)
        .padding(.bottom, 24)
    }
}
