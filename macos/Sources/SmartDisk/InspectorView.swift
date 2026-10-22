import QuickLookThumbnailing
import SwiftUI

/// "Why is this file here?" — every placement with its evidence, and one click to correct it.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = model.selectedItem {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("File details").font(.headline)
                            Spacer()
                            Button {
                                model.selectedItemID = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .background(Theme.surfaceMuted, in: .circle)
                                    .overlay(Circle().strokeBorder(Theme.border))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .help("Close")
                        }
                        .padding(.top, 30)
                        FileSummary(item: item)
                            .tourTarget(.fileSummary)
                            .id(TourTarget.fileSummary)
                        if let e = model.explanation, e.fileId == item.fileId {
                            WhySection(explanation: e, item: item)
                                .tourTarget(.why)
                                .id(TourTarget.why)
                            FactsSection(explanation: e)
                                .tourTarget(.facts)
                                .id(TourTarget.facts)
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                    .padding(18)
                }
                // The tour scrolls to the part it talks about.
                .onChange(of: model.tourStep) { _, step in
                    guard let target = step?.targets.first else { return }
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: target == .fileSummary ? .top : .center) }
                }
                .onChange(of: model.explanation) { _, _ in
                    guard let target = model.tourStep?.targets.first, target != .fileSummary else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Why is it here?", systemImage: "questionmark.text.page")
            } description: {
                Text("Select a file to see the text, date and score that put it in this folder.")
            }
        }
    }
}

struct FileSummary: View {
    @Environment(AppModel.self) private var model
    var item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Thumbnail(url: item.url)
                .frame(maxWidth: .infinity)
                .frame(height: 170)
            Text(item.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Button {
                model.reveal(item)
            } label: {
                Label((item.original as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("The original stays here. The drive only shows it.")
            HStack {
                Button("Open") { model.open(item) }
                    .buttonStyle(.primary)
                Button("Show Original") { model.reveal(item) }
                    .buttonStyle(.secondary)
            }
        }
    }
}

struct WhySection: View {
    @Environment(AppModel.self) private var model
    var explanation: Explanation
    var item: Item

    private var currentFolder: String? {
        if case .folder(let name) = model.selection { return name }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Why it's here")
            ForEach(explanation.placements.filter(\.included)) { p in
                PlacementCard(placement: p, highlighted: p.folder == currentFolder)
            }
            if !explanation.snippets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(explanation.snippets, id: \.self) { s in
                        Text("“\(s)”")
                            .font(.callout)
                            .italic()
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceMuted, in: .rect(cornerRadius: 10))
                    }
                }
            }
            let excluded = explanation.placements.filter { !$0.included }
            if !excluded.isEmpty {
                DisclosureGroup("Considered, but kept out (\(excluded.count))") {
                    ForEach(excluded) { p in
                        PlacementCard(placement: p, highlighted: false)
                    }
                }
                .font(.callout)
            }
            if let folder = currentFolder {
                correction(folder)
            }
        }
    }

    @ViewBuilder
    private func correction(_ folder: String) -> some View {
        let userSaidNo = explanation.placements.contains { $0.folder == folder && $0.source == "user_no" }
        if userSaidNo {
            Button {
                Task { await model.label(item, in: folder, belongs: nil) }
            } label: {
                Label("Undo “doesn't belong here”", systemImage: "arrow.uturn.backward")
            }
            .tourTarget(.correction)
            .id(TourTarget.correction)
        } else {
            Button(role: .destructive) {
                Task { await model.label(item, in: folder, belongs: false) }
            } label: {
                Label("Doesn't belong in \(folder)", systemImage: "minus.circle")
            }
            .help("Removes the file from this folder only. The original is not touched, and the drive learns from it.")
            .tourTarget(.correction)
            .id(TourTarget.correction)
        }
    }
}

struct PlacementCard: View {
    var placement: Placement
    var highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(placement.included ? Theme.success : .secondary)
                Text(placement.folder).font(.headline)
                Spacer()
                if placement.source != "auto" {
                    Text(placement.source == "user_yes" ? "added by you" : "removed by you")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ScoreBar(score: placement.score)
            }
            ForEach(placement.reasons, id: \.self) { reason in
                Label(reason, systemImage: "smallcircle.filled.circle")
                    .labelStyle(ReasonLabelStyle())
            }
        }
        .padding(12)
        .background(highlighted ? Theme.accentSoft : Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? Theme.accent.opacity(0.35) : Theme.border))
    }

    private var icon: String {
        switch placement.source {
        case "user_no": "hand.raised.fill"
        case "user_yes": "hand.thumbsup.fill"
        default: placement.included ? "checkmark.circle.fill" : "circle.dashed"
        }
    }
}

struct ReasonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.tertiary)
            configuration.title.font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct FactsSection: View {
    var explanation: Explanation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("What the drive read")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                fact("Text", "\(describeMethod(explanation.textMethod)) · \(explanation.textChars.formatted()) characters")
                if let a = explanation.facts.mainAmount {
                    fact("Amount", a.value.formatted(.currency(code: a.currency)) + (a.isTotal ? " (total)" : ""))
                }
                if let d = explanation.facts.docDate {
                    fact("Date", formatDate(d))
                }
                if !explanation.facts.vatNumbers.isEmpty {
                    fact("VAT", explanation.facts.vatNumbers.joined(separator: ", "))
                }
                if !explanation.facts.ibans.isEmpty {
                    fact("IBAN", explanation.facts.ibans.prefix(2).joined(separator: ", "))
                }
                if let sender = explanation.facts.emails.first {
                    fact("Sender", sender)
                }
                if explanation.facts.hasCode {
                    fact("Code", "contains a code")
                }
            }
            Text("Dates and amounts are read by rules, never guessed by a model.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

/// Quick Look thumbnail of the original file.
struct Thumbnail: View {
    var url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
            }
        }
        .task(id: url) {
            image = nil
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 340), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}
