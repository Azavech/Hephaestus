#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The fonts and colors of the editor and of highlighted code. Colors are dynamic: they follow light and dark
/// appearance without highlighting again.
@MainActor public enum EditorTheme {
    #if os(macOS)
    public typealias PlatformColor = NSColor
    public typealias PlatformFont = NSFont
    #else
    public typealias PlatformColor = UIColor
    public typealias PlatformFont = UIFont
    #endif

    public static let fontSize: CGFloat = 13

    /// The font of a token kind; nil is plain text.
    public static func font(for kind: TokenKind?) -> PlatformFont {
        switch kind {
        case .heading?, .strong?: return boldFont
        case .emphasis?: return italicFont
        default: return regularFont
        }
    }

    /// The color of a token kind; nil is plain text.
    public static func color(for kind: TokenKind?) -> PlatformColor {
        guard let kind else { return plainColor }
        return tokenColors[kind] ?? plainColor
    }

    public static var background: PlatformColor { backgroundColor }
    public static var currentLine: PlatformColor { currentLineColor }
    public static var gutterText: PlatformColor { gutterTextColor }
    public static var gutterCurrentText: PlatformColor { gutterCurrentTextColor }
    public static var gutterSeparator: PlatformColor { gutterSeparatorColor }

    // MARK: Fonts

    private static let regularFont = PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    private static let boldFont = PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    private static let italicFont: PlatformFont = {
        #if os(macOS)
        let descriptor = regularFont.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: fontSize) ?? regularFont
        #else
        guard let descriptor = regularFont.fontDescriptor.withSymbolicTraits(.traitItalic) else { return regularFont }
        return UIFont(descriptor: descriptor, size: fontSize)
        #endif
    }()

    // MARK: Colors

    private static let plainColor = dynamic(light: 0x000000, dark: 0xDFDFE0)

    private static let tokenColors: [TokenKind: PlatformColor] = [
        .keyword: dynamic(light: 0x9B2393, dark: 0xFF7AB2),
        .type: dynamic(light: 0x3900A0, dark: 0xD0A8FF),
        .builtin: dynamic(light: 0x6C36A9, dark: 0xA167E6),
        .string: dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        .number: dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        .comment: dynamic(light: 0x5D6C79, dark: 0x6C7986),
        .attribute: dynamic(light: 0x815F03, dark: 0xBF8555),
        .directive: dynamic(light: 0x643820, dark: 0xFD8F3F),
        .key: dynamic(light: 0x0F68A0, dark: 0x41A1C0),
        .heading: dynamic(light: 0x9B2393, dark: 0xFF7AB2),
        .emphasis: dynamic(light: 0x000000, dark: 0xDFDFE0),
        .strong: dynamic(light: 0x000000, dark: 0xDFDFE0),
        .code: dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        .link: dynamic(light: 0x0E0EFF, dark: 0x5482FF),
        .markup: dynamic(light: 0x815F03, dark: 0xBF8555),
    ]

    private static let backgroundColor = dynamic(light: 0xFFFFFF, dark: 0x1F1F24)
    private static let currentLineColor = dynamic(light: 0xECF5FF, dark: 0x23252B)
    private static let gutterTextColor = dynamic(light: 0xA0A0A5, dark: 0x6C6C70)
    private static let gutterCurrentTextColor = dynamic(light: 0x000000, dark: 0xDFDFE0)
    private static let gutterSeparatorColor = dynamic(light: 0xE5E5EA, dark: 0x38383D)

    /// A color that is `light` in light appearance and `dark` in dark appearance (sRGB, `0xRRGGBB`).
    private static func dynamic(light: UInt32, dark: UInt32) -> PlatformColor {
        let lightColor = rgb(light)
        let darkColor = rgb(dark)
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
        #else
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }
        #endif
    }

    private static func rgb(_ value: UInt32) -> PlatformColor {
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        #if os(macOS)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }
}
