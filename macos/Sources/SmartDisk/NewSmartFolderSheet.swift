import SwiftUI

/// Type a name, watch it turn into a query, see what it would contain.
struct NewSmartFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var preview: QueryResult?
    @State private var filters = FileFilters()
    @State private var isCreating = false
    @FocusState private var focused: Bool

    private let examples = [
        "invoices 2026 over 100 euro",
        "facturen 2026 boven 100 euro",
        "contracten met opzegtermijn",
        "alles over mijn kot",
        "screenshots met een code erin",
        "pdf van school deze maand",
        "belastingen 2025",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Smart Folder").font(.title2.weight(.semibold))
                    Text("The name is the search. Dutch or English.").foregroundStyle(.secondary)
                }
            }

            TextField("invoices 2026 over 100 euro", text: $name)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .card(radius: 12)
                .focused($focused)
                .onSubmit(create)

            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions
            } else {
                livePreview
            }

            HStack {
                Text("Removing the folder later only removes the search. No file is ever touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: create) {
                    if isCreating { ProgressView().controlSize(.small) } else { Text("Create Folder") }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { focused = true }
        .task(id: name) {
            let text = name.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { preview = nil; return }
            try? await Task.sleep(for: .milliseconds(280)) // debounce typing
            guard !Task.isCancelled else { return }
            preview = try? await model.client?.query(text)
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Try")
            FlowLayout(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button(example) { name = example }
                        .buttonStyle(.secondary)
                }
            }
        }
    }

    private var livePreview: some View {
        let found = preview?.items ?? []
        let kept = found.filter { filters.matches($0) }
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Understood as")
            ChipRow(chips: preview?.chips ?? [])
                .font(.callout)
                .animation(.snappy, value: preview?.chips)
            if !FilterBar.facets(of: found, filters).isEmpty {
                SectionTitle("Only include")
                    .padding(.top, 4)
                FilterBar(items: found, filters: $filters)
            }
            SectionTitle(preview == nil ? "Looking…" : "Would contain \(kept.count) file\(kept.count == 1 ? "" : "s")")
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(kept.prefix(5)) { item in
                    HStack(spacing: 8) {
                        FileTypeIcon(name: item.name, kind: item.kind, size: 24)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        if let a = item.amount {
                            Text(a, format: .currency(code: item.currency ?? "EUR"))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 5)
                }
            }
            .frame(minHeight: 40, alignment: .top)
        }
    }

    private func create() {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            if await model.createSmartFolder(text, filters: filters) { dismiss() }
            isCreating = false
        }
    }
}

/// Wraps its children onto new lines, like tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
