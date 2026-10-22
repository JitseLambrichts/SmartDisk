import AppKit
import SwiftUI

/// One calm look for the whole app: white cards on a soft canvas, one violet accent.
/// Every color has a light and a dark value, so the app follows the system appearance.
enum Theme {
    static let accent = Color(light: 0x5B4FE9, dark: 0x8B82FF)
    static let accentSoft = Color(light: 0xEFEDFD, dark: 0x2B2850)
    static let canvas = Color(light: 0xF6F6F9, dark: 0x161618)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1F1F22)
    static let surfaceMuted = Color(light: 0xF9F9FB, dark: 0x252528)
    static let border = Color(light: 0xE6E6EC, dark: 0x323236)
    static let danger = Color(light: 0xE5484D, dark: 0xFF6369)
    static let success = Color(light: 0x18A058, dark: 0x3DD68C)
    static let warning = Color(light: 0xD97706, dark: 0xF5A524)

    static let cardRadius: CGFloat = 16
}

extension Color {
    /// A color that switches with light and dark mode, from two hex values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Surfaces

/// A white rounded card with a hairline border, like every panel in the main window.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cardRadius

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border))
    }
}

extension View {
    func card(radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

// MARK: - Buttons

/// The one filled button on a screen: what most people want to do next.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: .capsule)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.capsule)
    }
}

/// Outlined, quieter button next to the primary one.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(configuration.isPressed ? Theme.surfaceMuted : Theme.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.border))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.capsule)
    }
}

/// A colored word that acts as a button, like "Open" and "Not here" in the file list.
struct TextActionStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Small pieces

/// "940 total", "29": a small outlined count.
struct CountBadge: View {
    var text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(highlighted ? Theme.accent : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(highlighted ? Theme.accentSoft : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(highlighted ? Theme.accent.opacity(0.35) : Theme.border))
    }
}

/// A rounded text field with a magnifying glass, used for search and filtering.
struct SearchField: View {
    var prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

/// A soft colored circle with a symbol, the way each file type is shown.
struct FileTypeIcon: View {
    var name: String
    var kind: String
    var size: CGFloat = 34

    var body: some View {
        let style = FileTypeStyle(name: name, kind: kind)
        ZStack {
            Circle().fill(style.color.opacity(0.12))
            VStack(spacing: 0) {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
                Text(style.label)
                    .font(.system(size: size * 0.2, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(style.color)
        }
        .frame(width: size, height: size)
    }
}

struct FileTypeStyle {
    var symbol: String
    var label: String
    var color: Color

    init(name: String, kind: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        label = ext.isEmpty ? kind.uppercased() : String(ext.prefix(4)).uppercased()
        switch (kind, ext) {
        case ("pdf", _):
            symbol = "doc.richtext"; color = Color(light: 0xE5484D, dark: 0xFF6369)
        case ("image", _):
            symbol = "photo"; color = Color(light: 0xE68A00, dark: 0xFFB224)
        case (_, "doc"), (_, "docx"), (_, "pages"), (_, "rtf"), (_, "odt"):
            symbol = "doc.text"; color = Color(light: 0x3E63DD, dark: 0x6E8DFF)
        case (_, "xls"), (_, "xlsx"), (_, "numbers"), (_, "csv"):
            symbol = "tablecells"; color = Color(light: 0x18A058, dark: 0x3DD68C)
        case (_, "html"), (_, "htm"), (_, "css"), (_, "js"), (_, "ts"), (_, "tsx"), (_, "swift"), (_, "rs"), (_, "py"), (_, "json"):
            symbol = "chevron.left.forwardslash.chevron.right"; color = Color(light: 0x8E4EC6, dark: 0xBF7AF0)
        default:
            symbol = "doc"; color = Color(light: 0x6F6F78, dark: 0xA0A0AB)
        }
    }
}

/// How sure the drive is that a file belongs somewhere, in three plain words.
enum Confidence: CaseIterable {
    case sure, likely, maybe

    init(score: Double) {
        self = switch score {
        case 0.75...: .sure
        case 0.5...: .likely
        default: .maybe
        }
    }

    var word: String {
        switch self {
        case .sure: "Sure"
        case .likely: "Likely"
        case .maybe: "Maybe"
        }
    }

    var color: Color {
        switch self {
        case .sure: Theme.success
        case .likely: Theme.warning
        case .maybe: .secondary
        }
    }
}

/// How sure the drive is, in words instead of a percentage.
struct ConfidenceTag: View {
    var score: Double

    var body: some View {
        let confidence = Confidence(score: score)
        HStack(spacing: 6) {
            Circle().fill(confidence.color).frame(width: 7, height: 7)
            Text(confidence.word)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .help("Smart Disk is \(score.formatted(.percent.precision(.fractionLength(0)))) sure this file belongs here")
    }
}
