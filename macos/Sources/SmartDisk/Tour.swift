import SwiftUI

// MARK: - Steps

/// The parts of the window the tour can point at.
enum TourTarget: Hashable {
    case categories, fileList, fileSummary, why, facts, correction, searchPage, newFolder, driveStatus, driveFooter
}

/// One short stop on the first-run tour. The tour drives the real window:
/// it opens the folder and the file each step talks about.
enum TourStep: Int, CaseIterable {
    case welcome, preparing, categories, fileList, fileSummary, why, facts, correction, search, smartFolder, drive, finish

    var targets: [TourTarget] {
        switch self {
        case .welcome, .preparing, .finish: []
        case .categories: [.categories]
        case .fileList: [.fileList]
        case .fileSummary: [.fileSummary]
        case .why: [.why]
        case .facts: [.facts]
        case .correction: [.correction]
        case .search: [.searchPage]
        case .smartFolder: [.newFolder]
        case .drive: [.driveStatus, .driveFooter]
        }
    }

    /// The steps that explain the window, numbered for the person.
    static let guided: [TourStep] = allCases.filter { !$0.targets.isEmpty }

    var next: TourStep? { TourStep(rawValue: rawValue + 1) }
    var previous: TourStep? {
        // Going back never redoes the examples.
        rawValue - 1 > TourStep.preparing.rawValue ? TourStep(rawValue: rawValue - 1) : nil
    }
}

/// A point in a step's explanation: an icon, a few bold words and a sentence.
struct TourPoint: Identifiable {
    var symbol: String
    var title: String
    var text: String
    var id: String { title }
}

// MARK: - Driving the window

extension AppModel {
    /// The search the tour types for the person.
    static let tourSearch = "invoices over 100 euro"

    var hasSeenTour: Bool {
        get { UserDefaults.standard.bool(forKey: "tourSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "tourSeen") }
    }

    /// Whether some folder already has files, so the tour can use the person's own.
    var hasOwnFiles: Bool {
        status?.categories.contains { $0.count > 0 } ?? false
    }

    func startTour() {
        tourError = nil
        tourCorrected = false
        tourStep = .welcome
    }

    func endTour(removeExamples: Bool = false) {
        tourStep = nil
        hasSeenTour = true
        leaveTourSearch()
        if removeExamples { Task { await self.removeExamples() } }
    }

    /// Writes the examples, has the drive read them and opens the tour on them.
    func prepareExamples() async {
        guard let client else { return }
        tourError = nil
        tourStep = .preparing
        tourProgress = .writing
        do {
            try await Task.detached { try ExampleFiles.write() }.value
            tourProgress = .adding
            if status?.daemonRunning == false { startDaemon() }
            try await client.addFolder(ExampleFiles.folder.path)
            try? await client.rescan()
            await refreshStatus()
            tourProgress = .reading
            let path = ExampleFiles.showcase.resolvingSymlinksInPath().path
            // Scans go through OCR first; a minute is plenty for eleven small files.
            let deadline = ContinuousClock.now + .seconds(90)
            while ContinuousClock.now < deadline {
                guard tourStep == .preparing else { return } // skipped meanwhile
                if let e = try? await client.why(path), e.placements.contains(where: \.included) {
                    await useForTour(e)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            tourError = "Smart Disk did not finish reading the examples. Check that the drive is running, then try again."
        } catch {
            tourError = error.localizedDescription
        }
    }

    /// Runs the tour on a file the person already has.
    func prepareOwnFiles() async {
        guard let client, let folder = status?.categories.first(where: { $0.count > 0 }),
              let item = try? await client.list(folder.name).first,
              let e = try? await client.why(item.original)
        else {
            tourError = "Smart Disk could not open one of your files. Try the example files instead."
            return
        }
        await useForTour(e, preferring: folder.name)
    }

    private func useForTour(_ e: Explanation, preferring folder: String? = nil) async {
        let folders = e.placements.filter(\.included).map(\.folder)
        tourFile = e.original
        tourFolders = folders
        tourFolder = folder.flatMap { folders.contains($0) ? $0 : nil }
            ?? folders.first { $0 == "Invoices" }
            ?? folders.first
        await refreshStatus()
        go(to: .categories)
    }

    /// Puts the tour's file back after the person tried "Doesn't belong".
    func undoTourCorrection() async {
        guard let client, let file = tourFile, let folder = tourFolder, tourCorrected else { return }
        do {
            try await client.label(file, folder: folder, belongs: nil)
            tourCorrected = false
            await refreshStatus()
            if let step = tourStep { go(to: step) } // shows the file again
        } catch { errorMessage = error.localizedDescription }
    }

    func removeExamples() async {
        if let client { try? await client.removeFolder(ExampleFiles.folder.resolvingSymlinksInPath().path) }
        do { try ExampleFiles.remove() } catch { errorMessage = error.localizedDescription }
        await refreshStatus()
        if selectedFolder == nil { selection = status?.folders.first.map { .folder($0.name) } }
    }

    /// Moves to a step and sets the window up for it.
    func go(to step: TourStep) {
        tourStep = step
        sidebarExpanded = true
        switch step {
        case .welcome, .preparing, .finish:
            break
        case .categories, .fileList, .smartFolder, .drive:
            leaveTourSearch()
            selectedItemID = nil
            showTourFolder()
        case .fileSummary, .why, .facts, .correction:
            leaveTourSearch()
            showTourFolder(selectingFile: true)
        case .search:
            selectedItemID = nil
            searchText = Self.tourSearch
            selection = .search
        }
    }

    /// Clears the search the tour typed, but never one of the person's own.
    private func leaveTourSearch() {
        if searchText == Self.tourSearch { searchText = "" }
    }

    private func showTourFolder(selectingFile: Bool = false) {
        guard let folder = tourFolder else { return }
        if selectingFile, let file = tourFile {
            if selectedItem?.original == file, selection == .folder(folder) { return }
            itemToSelect = file
        }
        if selection == .folder(folder) {
            if selectingFile { Task { await reloadSelection() } }
        } else {
            selection = .folder(folder) // the window reloads it, and selects the file once listed
        }
    }
}

// MARK: - Pointing at parts of the window

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as something the tour can point at. Adds to what its
    /// children marked, so a target may sit inside another (the correction inside "Why").
    func tourTarget(_ target: TourTarget) -> some View {
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { $0[target] = $1 }
    }
}

/// A dark veil over the window with a rounded hole around what a step talks about.
struct Spotlight: Shape {
    var hole: CGRect
    var cornerRadius: CGFloat = 14

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if !hole.isEmpty {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        }
        return path
    }
}

/// The veil and the card, laid over the whole window while the tour runs.
struct TourOverlay: View {
    @Environment(AppModel.self) private var model
    var anchors: [TourTarget: Anchor<CGRect>]
    @Environment(\.colorScheme) private var colorScheme
    @State private var cardSize = CGSize(width: 360, height: 260)

    var body: some View {
        if let step = model.tourStep {
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let rects = step.targets.compactMap { anchors[$0].map { proxy[$0] } }
                let target = rects.dropFirst().reduce(rects.first) { $0?.union($1) }
                    .map { $0.insetBy(dx: -8, dy: -8).intersection(bounds.insetBy(dx: 4, dy: 4)) }
                let hole = target ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
                ZStack(alignment: .topLeading) {
                    Spotlight(hole: hole)
                        .fill(.black.opacity(veilOpacity(spotlit: target != nil)), style: FillStyle(eoFill: true))
                        // Clicks inside the hole reach the window, so people can try things out.
                        .contentShape(Spotlight(hole: hole), eoFill: true)
                        .onTapGesture {}
                    if let target {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .frame(width: target.width, height: target.height)
                            .offset(x: target.minX, y: target.minY)
                            .allowsHitTesting(false)
                    }
                    TourCard(step: step)
                        .frame(width: step.targets.isEmpty ? 460 : cardWidth(for: target, in: bounds))
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .position(position(for: target, in: bounds))
                }
            }
            .animation(.snappy(duration: 0.35), value: step)
            .transition(.opacity)
        }
    }

    /// A dark window needs a darker veil before the highlighted part stands out.
    private func veilOpacity(spotlit: Bool) -> Double {
        (colorScheme == .dark ? 0.62 : 0.4) + (spotlit ? 0 : 0.08)
    }

    private static let gap: CGFloat = 18, margin: CGFloat = 16, width: CGFloat = 360

    /// Whether a full-width card fits beside or below the highlighted part.
    private func fitsOutside(_ t: CGRect, in bounds: CGRect) -> Bool {
        let gap = Self.gap, margin = Self.margin, w = Self.width
        return t.maxX + gap + w <= bounds.maxX - margin
            || t.minX - gap - w >= margin
            || t.maxY + gap + cardSize.height <= bounds.maxY - margin
    }

    /// A part as big as the file list leaves no room beside it. The card then narrows to
    /// sit over the sidebar, so it hides as little as possible of what it explains.
    private func cardWidth(for target: CGRect?, in bounds: CGRect) -> CGFloat {
        guard let t = target, !fitsOutside(t, in: bounds), t.minX >= 220 else { return Self.width }
        return min(Self.width, t.minX + 40)
    }

    /// Beside the highlighted part when there is room, else below it, else over the sidebar.
    private func position(for target: CGRect?, in bounds: CGRect) -> CGPoint {
        let w = cardSize.width, h = cardSize.height, gap = Self.gap, margin = Self.margin
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, margin + h / 2), bounds.maxY - margin - h / 2) }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, margin + w / 2), bounds.maxX - margin - w / 2) }
        guard let t = target else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        if t.maxX + gap + w <= bounds.maxX - margin {
            return CGPoint(x: t.maxX + gap + w / 2, y: clampY(t.midY))
        }
        if t.minX - gap - w >= margin {
            return CGPoint(x: t.minX - gap - w / 2, y: clampY(t.midY))
        }
        if t.maxY + gap + h <= bounds.maxY - margin {
            return CGPoint(x: clampX(t.midX), y: t.maxY + gap + h / 2)
        }
        if t.minX >= 220 {
            return CGPoint(x: margin + w / 2, y: clampY(.infinity))
        }
        return CGPoint(x: clampX(t.maxX - w / 2 - 24), y: clampY(t.maxY - h / 2 - 24))
    }
}

// MARK: - The card

struct TourCard: View {
    @Environment(AppModel.self) private var model
    var step: TourStep
    @State private var removeExamples = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            footer
        }
        .padding(22)
        .background(Theme.surface, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .tint(Theme.accent)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let index = TourStep.guided.firstIndex(of: step) {
            HStack {
                Text("Step \(index + 1) of \(TourStep.guided.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button("Skip Tour") { model.endTour() }
                    .buttonStyle(TextActionStyle(color: .secondary))
                    .font(.caption)
            }
        } else {
            Image(systemName: step == .finish ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: .circle)
        }
        Text(title)
            .font(.title3.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let text {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if step == .preparing {
            preparing
        }
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(points) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: point.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18)
                        Text("\(Text(point.title).fontWeight(.semibold)) \(Text("— " + point.text).foregroundStyle(.secondary))")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if let tip {
            Label(tip, systemImage: "hand.point.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceMuted, in: .rect(cornerRadius: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.tourError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        if step == .correction, model.tourCorrected {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text("\(fileName) left \(model.tourFolder ?? "the folder"). The original is untouched.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Undo") { Task { await model.undoTourCorrection() } }
                    .buttonStyle(.secondary)
            }
            .padding(10)
            .background(Theme.accentSoft, in: .rect(cornerRadius: 10))
        }
        if step == .finish, model.tourUsedExamples {
            Toggle("Remove the example files", isOn: $removeExamples)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
    }

    private var preparing: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(TourProgress.allCases, id: \.self) { phase in
                HStack(spacing: 10) {
                    Group {
                        if model.tourProgress.rawValue > phase.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        } else if model.tourProgress == phase && model.tourError == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    Text(phase.title)
                        .font(.callout)
                        .foregroundStyle(model.tourProgress.rawValue >= phase.rawValue ? .primary : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .welcome:
            HStack(spacing: 8) {
                Button("Skip Tour") { model.endTour() }
                    .buttonStyle(.secondary)
                Spacer()
                if model.hasOwnFiles {
                    Button("Use My Files") { Task { await model.prepareOwnFiles() } }
                        .buttonStyle(.secondary)
                }
                Button {
                    model.tourUsedExamples = true
                    Task { await model.prepareExamples() }
                } label: {
                    Label("Add Example Files", systemImage: "doc.on.doc")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        case .preparing:
            HStack(spacing: 8) {
                Button("Skip Tour") { model.endTour() }
                    .buttonStyle(.secondary)
                Spacer()
                if model.tourError != nil {
                    Button("Try Again") { Task { await model.prepareExamples() } }
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 6)
        case .finish:
            HStack(spacing: 8) {
                Button("Finish") { model.endTour(removeExamples: removeExamples) }
                    .buttonStyle(.secondary)
                Spacer()
                Button {
                    model.endTour(removeExamples: removeExamples)
                    model.addWatchedFolder()
                } label: {
                    Label("Choose My Folders…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        default:
            HStack(spacing: 8) {
                dots
                Spacer()
                if let previous = step.previous {
                    Button("Back") {
                        Task {
                            // The earlier steps explain the file in its folder, so it goes back first.
                            await model.undoTourCorrection()
                            model.go(to: previous)
                        }
                    }
                        .buttonStyle(.secondary)
                }
                Button(step.next == .finish ? "Done" : "Next") {
                    if let next = step.next { model.go(to: next) }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(TourStep.guided, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Theme.accent : Theme.border)
                    .frame(width: s == step ? 14 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Words

    private var fileName: String {
        model.tourFile.map { ($0 as NSString).lastPathComponent } ?? "this file"
    }

    /// Where the drive's folders show up in Finder; it can be moved in Settings.
    private var slimFolder: String {
        model.drivePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/Slim"
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Smart Disk"
        case .preparing: model.tourError == nil ? "Preparing the examples…" : "The examples are not ready"
        case .categories: "Folders that fill themselves"
        case .fileList: "Every file, with what was found inside"
        case .fileSummary: "The original stays where it is"
        case .why: "Why it’s here"
        case .facts: "What the drive read"
        case .correction: "Correct it in one click"
        case .search: "Search the way you think"
        case .smartFolder: "Make your own folders"
        case .drive: "Always up to date, also in Finder"
        case .finish: "You’re ready"
        }
    }

    private var text: String? {
        switch step {
        case .welcome:
            return "Smart Disk reads what is inside your files and shows each one in the folders where it belongs. Your originals never move.\n\nThis short tour adds a few made-up documents — invoices, contracts, scans and screenshots — so you can see everything at work without touching your own files."
        case .preparing:
            return "The examples are fictitious and stay on this Mac, in Application Support. Smart Disk reads nothing else."
        case .categories:
            let folders = model.tourFolders
            let place = folders.count > 1
                ? "\(fileName) is in \(ListFormatter.localizedString(byJoining: folders)) at the same time."
                : "Click a folder to see what is in it."
            return "These folders are built in. Smart Disk files every document into them by reading its text, not its name or location.\n\nOne file can be in several folders: \(place)"
        case .fileList:
            return nil
        case .fileSummary:
            return "Smart Disk only shows files; it never moves, copies or changes them. The path under the name is where the original lives — click it or Show Original to find it in Finder.\n\nOpen opens the original itself, so changes you make are saved there."
        case .why:
            return "Smart Disk always tells you why a file is in a folder:"
        case .facts:
            return "How the text was obtained — the text inside a PDF, or on-device OCR for scans and screenshots — and the facts found in it: total amount, document date, VAT number, IBAN and sender.\n\nDates and amounts are read by fixed rules, never guessed by an AI model."
        case .correction:
            return "Is a file in the wrong folder? Click Doesn’t belong. Only this folder forgets it: the original is not touched, and Smart Disk learns from your choice for similar files."
        case .search:
            return "Type in the search field at the top of the sidebar. Smart Disk understands words, years and amounts — here it searched for “\(AppModel.tourSearch)”. The chips show how it understood you.\n\nSave as Smart Folder keeps a search as a folder that refills itself with every new match."
        case .smartFolder:
            return "The name of a smart folder is its search. Call one “tenancy agreement” or “invoices 2026” and it fills itself, now and whenever a matching file arrives. Narrow it down with filters for type or year if you like.\n\nRemoving a smart folder only removes the search, never a file."
        case .drive:
            return nil
        case .finish:
            return "That’s all of Smart Disk. Now choose the folders it may read — Documents, Downloads and Desktop are good places to start. Nothing outside them is ever read.\n\nYou can take this tour again from Help ▸ Smart Disk Tour."
        }
    }

    private var points: [TourPoint] {
        switch step {
        case .welcome:
            [
                TourPoint(symbol: "arrow.left.arrow.right", title: "Never moved", text: "originals are never moved, copied or changed."),
                TourPoint(symbol: "lock", title: "Stays on your Mac", text: "reading and searching happen here, without an account."),
                TourPoint(symbol: "clock", title: "Two minutes", text: "nine short steps through every part of the window."),
            ]
        case .fileList:
            [
                TourPoint(symbol: "calendar", title: "Date", text: "the date written in the document. Gray means none was found, so the file’s own date is shown."),
                TourPoint(symbol: "eurosign", title: "Amount", text: "the total read from invoices and receipts."),
                TourPoint(symbol: "circle.fill", title: "Fits", text: "how sure Smart Disk is that the file belongs here: Sure, Likely or Maybe."),
                TourPoint(symbol: "line.3.horizontal.decrease", title: "Search and Filter", text: "the field searches names and the text inside documents; filters narrow by type, year or amount."),
                TourPoint(symbol: "ellipsis", title: "Actions", text: "open the file, show the original in Finder, or take it out of this folder."),
            ]
        case .why:
            [
                TourPoint(symbol: "checkmark.circle.fill", title: "Each folder it is in", text: "with a score for how sure the drive is."),
                TourPoint(symbol: "smallcircle.filled.circle", title: "The reasons", text: "the words, dates and amounts that matched."),
                TourPoint(symbol: "quote.opening", title: "Quotes", text: "the exact text in the file that counted."),
                TourPoint(symbol: "circle.dashed", title: "Considered, but kept out", text: "folders it almost went to. When in doubt, a file stays out."),
            ]
        case .drive:
            [
                TourPoint(symbol: "arrow.triangle.2.circlepath", title: "Status", text: "shows when Smart Disk is reading. New and changed files are picked up by themselves; the arrow checks everything again."),
                TourPoint(symbol: "folder.fill", title: "The Slim folder", text: "every folder here also exists in \(slimFolder). Drag it to Finder’s sidebar to use it in Finder and in every Open and Save dialog."),
                TourPoint(symbol: "gearshape", title: "Settings", text: "choose which folders are read, show sensitive folders like ID Documents, and pause on battery."),
            ]
        default:
            []
        }
    }

    private var tip: String? {
        switch step {
        case .categories: "Right-click a folder to change its icon or hide it."
        case .fileList: "Click a file to see its details; double-click opens it."
        case .correction: model.tourCorrected ? nil : "Try it now — you can undo it right here."
        case .smartFolder: "Shortcut: ⇧⌘N, from anywhere in the window."
        default: nil
        }
    }
}

/// What the tour is doing while it prepares the examples.
enum TourProgress: Int, CaseIterable {
    case writing, adding, reading

    var title: String {
        switch self {
        case .writing: "Writing eleven example documents"
        case .adding: "Adding them to Smart Disk"
        case .reading: "Reading them — scans with on-device OCR"
        }
    }
}
