import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Folders", systemImage: "folder") { FoldersSettings() }
            Tab("Categories", systemImage: "square.grid.2x2") { CategoriesSettings() }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettings() }
            Tab("Drive", systemImage: "externaldrive") { DriveSettings() }
            Tab("Appearance", systemImage: "circle.lefthalf.filled") { AppearanceSettings() }
            Tab("Activity", systemImage: "list.bullet.rectangle") { ActivitySettings() }
        }
        .frame(width: 560, height: 440)
    }
}

/// Binding that writes a setting through the CLI.
@MainActor
private func setting(_ model: AppModel, _ key: String, _ get: @escaping (DriveConfig) -> Bool) -> Binding<Bool> {
    Binding(get: { model.status.map { get($0.config) } ?? false }, set: { model.set(key, $0) })
}

struct FoldersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?

    var body: some View {
        Form {
            Section {
                List(selection: $selected) {
                    ForEach(model.status?.config.folders ?? [], id: \.self) { path in
                        Label {
                            VStack(alignment: .leading) {
                                Text((path as NSString).lastPathComponent)
                                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        .tag(path)
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Button("Add Folder…") { model.addWatchedFolder() }
                    Button("Remove") {
                        if let s = selected { model.removeWatchedFolder(s) }
                    }
                    .disabled(selected == nil)
                }
            } header: {
                Text("Indexed folders")
            } footer: {
                Text("Only these folders are read. Files in iCloud that are not downloaded are skipped, so indexing never starts a download.")
                    .foregroundStyle(.secondary)
            }
            Section("Indexing") {
                Toggle("Pause while on battery", isOn: setting(model, "pause-on-battery") { $0.pauseOnBattery })
                Toggle("Pause indexing", isOn: setting(model, "paused") { $0.paused })
            }
        }
        .formStyle(.grouped)
    }
}

/// Turn built-in categories on and off. Off removes the folder; files keep their labels.
struct CategoriesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.categories.filter { !$0.sensitive }) { category in
                    Toggle(isOn: Binding(
                        get: { !category.hidden },
                        set: { on in
                            Task {
                                if on {
                                    await model.restoreCategory(category.id)
                                } else {
                                    await model.removeFolder(category.name)
                                }
                            }
                        }
                    )) {
                        Label(category.name, systemImage: category.symbol)
                    }
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Switched off, a category's folder disappears from the sidebar and the drive. Your files are never touched, and switching it back on brings it back right away. ID documents are under Privacy.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: model.status?.config.hiddenCategories) { await model.loadCategories() }
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(isOn: setting(model, "sensitive") { $0.sensitiveEnabled }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show ID documents")
                        Text("Identity cards, passports and driving licences. Off by default: any app that can read the drive could see them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sensitive categories")
            }
            Section {
                Toggle(isOn: setting(model, "full-text") { $0.storeFullText }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep document text in the index")
                        Text("When off, only vectors and facts (dates, amounts) are stored. Explanations become shorter. Applies to newly indexed files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: setting(model, "apple-intelligence") { $0.useAppleIntelligence }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Apple Intelligence to read folder names")
                        Text(fmText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Index")
            } footer: {
                HStack {
                    Text("Index location: \((model.status?.dataDir ?? "") as NSString).abbreviatingWithTildeInPath)")
                    Spacer()
                    Button("Show") {
                        if let dir = model.status?.dataDir { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
                    }
                }
                .foregroundStyle(.secondary)
            }
            Section {
                Label("No telemetry. No network traffic. No account.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var fmText: String {
        guard let caps = model.capabilities else { return "Checking availability…" }
        if caps.foundationModels { return "Runs on device. Dates and amounts are still read by rules." }
        return "Not available on this Mac (\(caps.foundationModelsReason ?? "unknown")). A built-in keyword parser is used instead."
    }
}

struct DriveSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Show the drive as", selection: $model.driveMode) {
                    ForEach(DriveMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                if model.driveMode == .fuse && model.capabilities?.fuse != true {
                    Label("This build has no FUSE support. Install FUSE-T or macFUSE, then rebuild with `cargo build --release --features fuse`.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Folder", value: ((model.status?.config.mirrorPath ?? "") as NSString).abbreviatingWithTildeInPath)
                LabeledContent("Drive", value: model.status?.config.fuseMountPoint ?? "")
                LabeledContent("New files go to", value: ((model.status?.config.inboxPath ?? "") as NSString).abbreviatingWithTildeInPath)
                HStack {
                    Spacer()
                    Button("Restart Drive") { model.restartDaemon() }
                }
            } header: {
                Text("Drive")
            } footer: {
                Text("Both show the same folders. Tip: drag the folder to Finder's sidebar to reach it from every open and save panel.")
                    .foregroundStyle(.secondary)
            }
            Section("Capabilities") {
                LabeledContent("Text recognition (OCR)", value: model.capabilities?.ocr == true ? "On device" : "Helper not found")
                LabeledContent("Embedding model", value: model.capabilities?.embedder ?? "—")
                LabeledContent("Apple Intelligence", value: model.capabilities?.foundationModels == true ? "Available" : "Not available")
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows the setting in macOS. Light and Dark apply to Smart Disk only.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ActivitySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.log) { row in
            HStack(alignment: .firstTextBaseline) {
                Text(Date(timeIntervalSince1970: TimeInterval(row.ts)), format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: row.level == "info" ? "info.circle" : "exclamationmark.triangle")
                    .foregroundStyle(row.level == "info" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Text(row.message).font(.callout).textSelection(.enabled)
            }
        }
        .overlay {
            if model.log.isEmpty { ContentUnavailableView("No activity yet", systemImage: "clock") }
        }
        .task {
            while !Task.isCancelled {
                await model.loadLog()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
