import AppKit
import Foundation
import Observation

enum DriveMode: String, CaseIterable, Identifiable {
    case mirror, fuse
    var id: String { rawValue }
    var title: String { self == .mirror ? "Folder in your home" : "Virtual drive (FUSE)" }
}

/// What the sidebar has selected.
enum SidebarItem: Hashable {
    case folder(String)
    case search
}

@MainActor
@Observable
final class AppModel {
    var client: SlimClient?
    var status: DriveStatus?
    var capabilities: Capabilities?
    var selection: SidebarItem?
    var items: [Item] = []
    var isLoadingItems = false
    var selectedItemID: Item.ID?
    var explanation: Explanation?
    var searchText = ""
    var searchResult: QueryResult?
    var isSearching = false
    var errorMessage: String?
    /// A folder waiting for the user to confirm its removal.
    var folderToRemove: Folder?
    var categories: [CategoryInfo] = []
    var log: [LogRow] = []

    var driveMode: DriveMode {
        didSet { UserDefaults.standard.set(driveMode.rawValue, forKey: "driveMode") }
    }

    private var daemon: Process?
    private var lastGeneration = -1
    private var timer: Timer?

    init() {
        driveMode = DriveMode(rawValue: UserDefaults.standard.string(forKey: "driveMode") ?? "") ?? .mirror
        client = SlimClient.locate()
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        Task {
            await refreshStatus()
            capabilities = try? await client?.capabilities()
            if status?.daemonRunning == false { startDaemon() }
            if selection == nil, let first = status?.folders.first { selection = .folder(first.name) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Only signal the drive; it shuts itself down. Waiting for it here blocked the quit.
            MainActor.assumeIsolated { self?.daemon?.terminate() }
        }
    }

    private func tick() async {
        await refreshStatus()
        guard let status else { return }
        if status.generation != lastGeneration {
            lastGeneration = status.generation
            await reloadSelection(keepExplanation: true)
        }
    }

    func refreshStatus() async {
        guard let client else { return }
        do {
            let s = try await client.status()
            if s != status { status = s }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Daemon

    func startDaemon() {
        guard let client, daemon == nil else { return }
        let process = Process()
        process.executableURL = client.binary
        let useFuse = driveMode == .fuse && capabilities?.fuse == true
        process.arguments = ["daemon", useFuse ? "--fuse" : "--mirror"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let id = ObjectIdentifier(ended)
            // A restart may already have started the next drive; leave that one alone.
            Task { @MainActor in
                if let self, let daemon = self.daemon, ObjectIdentifier(daemon) == id { self.daemon = nil }
            }
        }
        do {
            try process.run()
            daemon = process
        } catch {
            errorMessage = "Could not start the drive: \(error.localizedDescription)"
        }
    }

    /// Stops the drive and returns once it has exited, or after `timeout`.
    /// Polls instead of `waitUntilExit()`: on the main thread that can hang even after the drive is gone.
    func stopDaemon(timeout: Duration = .seconds(120)) async {
        guard let process = daemon else { return }
        daemon = nil
        process.terminate()
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func restartDaemon() {
        Task {
            await stopDaemon()
            startDaemon()
            await refreshStatus()
        }
    }

    // MARK: Folders & items

    var selectedFolder: Folder? {
        guard case .folder(let name) = selection else { return nil }
        return status?.folders.first { $0.name == name }
    }

    var selectedItem: Item? {
        let pool = selection == .search ? (searchResult?.items ?? []) : items
        return pool.first { $0.id == selectedItemID }
    }

    func reloadSelection(keepExplanation: Bool = false) async {
        guard let client else { return }
        switch selection {
        case .folder(let name):
            if !keepExplanation { isLoadingItems = true }
            items = (try? await client.list(name)) ?? []
            isLoadingItems = false
        case .search:
            await runSearch()
        case nil:
            items = []
        }
        if keepExplanation, let id = selectedItemID, let item = selectedItem, item.id == id {
            await explain(item)
        } else if !keepExplanation {
            selectedItemID = nil
            explanation = nil
        }
    }

    func explain(_ item: Item?) async {
        guard let client, let item else { explanation = nil; return }
        explanation = try? await client.why(item.original)
    }

    func runSearch() async {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard let client, !text.isEmpty else { searchResult = nil; return }
        isSearching = true
        searchResult = try? await client.query(text)
        isSearching = false
    }

    func createSmartFolder(_ name: String, filters: FileFilters = FileFilters()) async -> Bool {
        guard let client else { return false }
        do {
            try await client.mkdir(name, filters: filters)
            await refreshStatus()
            selection = .folder(name)
            await reloadSelection()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes a smart folder or hides a category. No file is touched either way.
    func removeFolder(_ name: String) async {
        guard let client else { return }
        do {
            try await client.rmdir(name)
            await refreshStatus()
            if selection == .folder(name) { selection = status?.folders.first.map { .folder($0.name) } }
            await reloadSelection()
            await loadCategories()
        } catch { errorMessage = error.localizedDescription }
    }

    func loadCategories() async {
        categories = (try? await client?.categories()) ?? categories
    }

    /// Brings a removed category back.
    func restoreCategory(_ id: String) async {
        guard let client else { return }
        do {
            try await client.showCategory(id)
            await refreshStatus()
            await loadCategories()
        } catch { errorMessage = error.localizedDescription }
    }

    func renameSmartFolder(_ name: String, to newName: String) async {
        guard let client, !newName.isEmpty, newName != name else { return }
        do {
            try await client.rename(name, to: newName)
            await refreshStatus()
            selection = .folder(newName)
            await reloadSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    /// "Doesn't belong here" (false), "Belongs here" (true) or undo (nil).
    func label(_ item: Item, in folder: String, belongs: Bool?) async {
        guard let client else { return }
        do {
            try await client.label(item.original, folder: folder, belongs: belongs)
            await refreshStatus()
            await reloadSelection(keepExplanation: belongs == nil)
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Settings

    func set(_ key: String, _ value: Bool) {
        set(key, value ? "true" : "false")
    }

    func set(_ key: String, _ value: String) {
        guard let client else { return }
        Task {
            do { try await client.set(key, value) } catch { errorMessage = error.localizedDescription }
            await refreshStatus()
        }
    }

    func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Include Folder"
        panel.message = "Choose folders for the Smart Disk to read. Nothing outside them is ever read."
        guard panel.runModal() == .OK else { return }
        addWatchedFolders(panel.urls)
    }

    /// Folders chosen in the open panel or dropped onto the window.
    func addWatchedFolders(_ urls: [URL]) {
        guard let client, !urls.isEmpty else { return }
        Task {
            for url in urls { try? await client.addFolder(url.path) }
            await refreshStatus()
        }
    }

    func removeWatchedFolder(_ path: String) {
        guard let client else { return }
        Task {
            try? await client.removeFolder(path)
            await refreshStatus()
        }
    }

    func loadLog() async {
        log = (try? await client?.log()) ?? []
    }

    // MARK: Finder

    var drivePath: String? { status?.mount?.path }

    func drivePath(for folder: String) -> String? {
        drivePath.map { ($0 as NSString).appendingPathComponent(folder) }
    }

    func openDrive(_ folder: String? = nil) {
        guard let path = folder.flatMap(drivePath(for:)) ?? drivePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }
}
