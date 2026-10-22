import AppKit
import SwiftUI

@main
struct SmartDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Smart Disk", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 560)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                NewSmartFolderCommand()
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .onAppear { model.start() }
        } label: {
            MenuBarIcon(status: model.status)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .onAppear { model.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run`, the process is not a bundled app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // the menu bar icon keeps the drive alive
    }
}

/// Menu bar icon reflects whether the drive is indexing.
struct MenuBarIcon: View {
    var status: DriveStatus?

    var body: some View {
        let symbol = switch status?.state {
        case "indexing": "externaldrive.badge.timemachine"
        case "paused", "battery": "externaldrive.badge.minus"
        case "stopped", nil: "externaldrive.badge.xmark"
        default: "externaldrive.fill.badge.checkmark"
        }
        Image(systemName: symbol)
    }
}

/// File ▸ New Smart Folder… (⇧⌘N), like Finder's own shortcut.
struct NewSmartFolderCommand: View {
    @FocusedValue(\.newSmartFolder) private var action

    var body: some View {
        Button("New Smart Folder…") { action?() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(action == nil)
    }
}

struct NewSmartFolderKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newSmartFolder: (() -> Void)? {
        get { self[NewSmartFolderKey.self] }
        set { self[NewSmartFolderKey.self] = newValue }
    }
}
