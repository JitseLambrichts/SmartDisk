import SwiftUI

/// Icons that suit folders of files. The built-in folders' own icons come first,
/// so going back to one is just another pick.
enum FolderIcons {
    static let all = [
        "sparkle.magnifyingglass", "folder.fill", "doc.text.fill", "signature",
        "person.text.rectangle.fill", "camera.viewfinder", "photo.fill", "house.fill",
        "building.columns.fill", "banknote.fill", "creditcard.fill", "cart.fill",
        "briefcase.fill", "tray.full.fill", "archivebox.fill", "chart.bar.fill",
        "graduationcap.fill", "book.fill", "heart.fill", "cross.case.fill",
        "pills.fill", "fork.knife", "leaf.fill", "pawprint.fill",
        "car.fill", "airplane", "suitcase.fill", "music.note",
        "film.fill", "gamecontroller.fill", "paintpalette.fill", "hammer.fill",
        "person.fill", "person.2.fill", "gift.fill", "calendar",
        "star.fill", "flag.fill", "tag.fill", "lock.fill",
    ]
}

/// A grid of icons; the chosen one is highlighted.
struct FolderIconGrid: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8), spacing: 6) {
            ForEach(FolderIcons.all, id: \.self) { symbol in
                let chosen = selection == symbol
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(chosen ? Theme.accent : .secondary)
                        .frame(width: 36, height: 36)
                        .background(chosen ? Theme.accentSoft : .clear, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? Theme.accent.opacity(0.5) : .clear))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

/// The square button next to a folder name that shows its icon and opens the grid.
struct FolderIconButton: View {
    @Binding var symbol: String
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 46, height: 46)
                .background(Theme.accentSoft, in: .rect(cornerRadius: 12))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Choose an icon")
        .accessibilityLabel("Choose an icon")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            FolderIconGrid(selection: $symbol)
                .padding(14)
                // The popover's own material follows macOS, not the app's Light/Dark setting.
                .presentationBackground(Theme.surface)
                .onChange(of: symbol) { picking = false }
        }
    }
}

/// Change Icon… for a folder or category that already exists.
struct FolderIconSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var folder: Folder
    @State private var symbol = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 46, height: 46)
                    .background(Theme.accentSoft, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Icon for \(folder.name)").font(.title2.weight(.semibold)).lineLimit(1)
                    Text("Shown in the sidebar and the menu bar.").foregroundStyle(.secondary)
                }
            }
            FolderIconGrid(selection: $symbol)
            HStack {
                Button("Use Default") {
                    model.setSymbol(nil, for: folder.name)
                    dismiss()
                }
                .buttonStyle(.secondary)
                .disabled(model.folderSymbols[folder.name] == nil)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    model.setSymbol(symbol == folder.symbol ? nil : symbol, for: folder.name)
                    dismiss()
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { symbol = model.symbol(for: folder) }
    }
}
