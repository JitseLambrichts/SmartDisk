import SwiftUI

/// The small status window behind the menu bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let s = model.status, s.isIndexing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(s.progressDone), total: Double(max(s.progressTotal, 1)))
                    Text(s.current.flatMap { $0.isEmpty ? nil : $0 } ?? "Reading files…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let folders = model.status?.folders, !folders.isEmpty {
                VStack(spacing: 2) {
                    ForEach(folders.prefix(9)) { folder in
                        Button {
                            model.openDrive(folder.name)
                        } label: {
                            HStack {
                                Image(systemName: folder.symbol)
                                    .foregroundStyle(folder.isSmart ? AnyShapeStyle(.purple) : AnyShapeStyle(.tint))
                                    .frame(width: 20)
                                Text(folder.name).lineLimit(1)
                                Spacer()
                                Text("\(folder.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(.rect)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(MenuRowStyle())
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Label("Open Smart Disk", systemImage: "macwindow")
                }
                .buttonStyle(.glassProminent)
                Button {
                    model.openDrive()
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .buttonStyle(.glass)
                .disabled(model.drivePath == nil)
                Spacer()
                Button {
                    model.set("paused", !(model.status?.config.paused ?? false))
                } label: {
                    Image(systemName: model.status?.config.paused == true ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.glass)
                .help(model.status?.config.paused == true ? "Resume indexing" : "Pause indexing")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.glass)
                .help("Quit and unmount the drive")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Disk").font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        guard let s = model.status else { return "Connecting…" }
        switch s.state {
        case "indexing": return "Indexing \(s.progressDone) of \(s.progressTotal)"
        case "paused": return "Paused · \(s.filesIndexed.formatted()) files"
        case "battery": return "Waiting for power · \(s.filesIndexed.formatted()) files"
        case "stopped": return "Drive is not running"
        default: return "Up to date · \(s.filesIndexed.formatted()) files"
        }
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(hovering || configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}
