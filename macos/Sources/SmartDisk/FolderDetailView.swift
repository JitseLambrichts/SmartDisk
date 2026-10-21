import SwiftUI

struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    var folder: Folder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderHeader(folder: folder)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)
            if model.items.isEmpty && !model.isLoadingItems {
                emptyState
            } else {
                ItemTable(items: model.items, folder: folder.name)
            }
        }
        .navigationTitle(folder.name)
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
            ContentUnavailableView("No \(folder.name.lowercased()) yet", systemImage: folder.symbol, description: Text("Files appear here once they are indexed and recognised."))
        }
    }
}

struct FolderHeader: View {
    @Environment(AppModel.self) private var model
    var folder: Folder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: folder.symbol)
                    .font(.title)
                    .foregroundStyle(folder.isSmart ? AnyShapeStyle(.purple) : AnyShapeStyle(.tint))
                Text(folder.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let path = model.drivePath(for: folder.name) {
                    TerminalPath(path: path)
                }
            }
            HStack(spacing: 6) {
                Text(folder.count == 1 ? "1 file" : "\(folder.count) files")
                    .foregroundStyle(.secondary)
                if folder.isSmart {
                    Text("·").foregroundStyle(.tertiary)
                    ChipRow(chips: folder.chips)
                } else {
                    Text("· fills itself from your indexed folders").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}

/// The same folder, as agents and scripts see it.
struct TerminalPath: View {
    var path: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("ls \"\(path)\"", forType: .string)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "ls \"…/\((path as NSString).lastPathComponent)\"", systemImage: copied ? "checkmark" : "terminal")
                .font(.callout.monospaced())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .help("Copy a terminal command for this folder: \(path)")
    }
}

struct ChipRow: View {
    var chips: [String]

    var body: some View {
        if chips.isEmpty {
            Text("no filters understood yet — try a clearer name").foregroundStyle(.secondary)
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
                Text(parts[0]).foregroundStyle(.secondary)
                Text(parts[1]).fontWeight(.medium)
            } else {
                Text(text).fontWeight(.medium)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular.tint(.purple.opacity(0.18)), in: .capsule)
    }
}

// MARK: - File table

struct ItemTable: View {
    @Environment(AppModel.self) private var model
    var items: [Item]
    /// Folder the items are shown in; nil for search results.
    var folder: String?
    @State private var sortOrder = [KeyPathComparator(\Item.score, order: .reverse)]

    var body: some View {
        @Bindable var model = model
        Table(items.sorted(using: sortOrder), selection: $model.selectedItemID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    FileIcon(path: item.original)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        Text("from \(item.origin)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 160, ideal: 340)
            TableColumn("Date", value: \.displayDate) { item in
                Text(formatDate(item.displayDate))
                    .foregroundStyle(item.docDate == nil ? .secondary : .primary)
                    .help(item.docDate == nil ? "File date (no date found in the document)" : "Date found in the document")
            }
            .width(min: 70, ideal: 110)
            TableColumn("Amount") { item in
                if let amount = item.amount {
                    Text(amount, format: .currency(code: item.currency ?? "EUR"))
                        .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 60, ideal: 90)
            TableColumn("Match", value: \.score) { item in
                ScoreBar(score: item.score)
            }
            .width(min: 70, ideal: 100)
        }
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                Button("Open") { model.open(item) }
                Button("Show Original in Finder") { model.reveal(item) }
                if let folder {
                    Divider()
                    Button("Doesn't Belong Here") {
                        Task { await model.label(item, in: folder, belongs: false) }
                    }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) { model.open(item) }
        }
    }
}

struct ScoreBar: View {
    var score: Double

    var body: some View {
        HStack(spacing: 6) {
            Gauge(value: min(max(score, 0), 1)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(score >= 0.75 ? .green : score >= 0.5 ? .yellow : .orange)
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
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("“\(model.searchText)”")
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
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
                    .buttonStyle(.glassProminent)
                    .disabled(saving || model.searchText.isEmpty)
                }
                HStack(spacing: 6) {
                    Text("\(model.searchResult?.items.count ?? 0) results").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    ChipRow(chips: model.searchResult?.chips ?? [])
                }
                .font(.callout)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            if let result = model.searchResult, !result.items.isEmpty {
                ItemTable(items: result.items, folder: nil)
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .navigationTitle("Search")
    }
}
