import AppKit
import CoreText
import SwiftUI
import os

/// Type scale. Display faces are Archivo (variable, SIL OFL 1.1, bundled); body text is SF Pro.
enum Typo {
    /// Archivo 64 black, tracking −2 %.
    static let display = archivo(size: 64, weight: 900)
    /// Archivo 28 bold.
    static let title = archivo(size: 28, weight: 700)
    /// SF Pro 17 semibold.
    static let headline = Font.system(size: 17, weight: .semibold)
    /// SF Pro 14.
    static let body = Font.system(size: 14)
    /// SF Pro 12 — pair with `Palette.secondaryText` (see `.textStyle(.caption)`).
    static let caption = Font.system(size: 12)
    /// Archivo 96 black, monospaced digits.
    static let bigNumber = archivo(size: 96, weight: 900).monospacedDigit()

    /// Archivo 44 black, monospaced digits — the size figure on a `Tile`.
    static let tileNumber = archivo(size: 44, weight: 900).monospacedDigit()
    /// Archivo 30 black, monospaced digits — a compact `Tile`.
    static let tileNumberCompact = archivo(size: 30, weight: 900).monospacedDigit()
    /// Archivo 22 black, monospaced digits — a menu-bar gauge's value.
    static let gaugeNumber = archivo(size: 22, weight: 900).monospacedDigit()
    /// Archivo 15 bold — button labels and pills.
    static let label = archivo(size: 15, weight: 700)
    /// Archivo 12 heavy — risk pills.
    static let pill = archivo(size: 12, weight: 800)
    /// SF Pro 14 medium — sidebar rows.
    static let sidebar = Font.system(size: 14, weight: .medium)

    /// Tracking for `display`: −2 % of 64 pt.
    static let displayTracking: CGFloat = -64 * 0.02
    /// Tracking for `bigNumber`: −3 % of 96 pt.
    static let bigNumberTracking: CGFloat = -96 * 0.03

    /// Archivo at an exact weight on the variable `wght` axis (100…900).
    /// Falls back to SF Pro if the bundled font cannot be loaded.
    static func archivo(size: CGFloat, weight: CGFloat) -> Font {
        if let font = archivoNSFont(size: size, weight: weight) {
            return Font(font as CTFont)
        }
        return .system(size: size, weight: weight >= 800 ? .black : .bold)
    }

    /// The `NSFont` behind `archivo(size:weight:)`. Non-nil means the bundled font resolved.
    static func archivoNSFont(size: CGFloat, weight: CGFloat) -> NSFont? {
        guard FontRegistry.isRegistered else { return nil }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: FontRegistry.archivoFamily,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [
                FontRegistry.weightAxis: weight
            ],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size),
            font.familyName == FontRegistry.archivoFamily
        else { return nil }
        return font
    }
}

/// Registers the bundled Archivo variable font for this process.
enum FontRegistry {
    static let archivoFamily = "Archivo"
    static let fileName = "Archivo-Variable"
    /// OpenType tag 'wght' as a four-char code.
    static let weightAxis: UInt32 = 0x7767_6874

    /// Registers once, on first use. Safe from any thread.
    static let isRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "ttf") else {
            Logger(subsystem: "app.dustpan", category: "design").error("Archivo font missing from bundle")
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Already registered for this process counts as success.
        if let cfError = error?.takeRetainedValue(),
            CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue
        {
            return true
        }
        Logger(subsystem: "app.dustpan", category: "design").error("Archivo font registration failed")
        return false
    }()
}

/// Named text styles: font + tracking + colour together.
enum TextStyle {
    case display, title, headline, body, caption, bigNumber
}

extension View {
    /// Applies a complete text style from the type scale.
    func textStyle(_ style: TextStyle) -> some View {
        modifier(TextStyleModifier(style: style))
    }
}

private struct TextStyleModifier: ViewModifier {
    let style: TextStyle

    func body(content: Content) -> some View {
        switch style {
        case .display:
            content.font(Typo.display).tracking(Typo.displayTracking).foregroundStyle(Palette.ink)
        case .title:
            content.font(Typo.title).foregroundStyle(Palette.ink)
        case .headline:
            content.font(Typo.headline).foregroundStyle(Palette.ink)
        case .body:
            content.font(Typo.body).foregroundStyle(Palette.ink)
        case .caption:
            content.font(Typo.caption).foregroundStyle(Palette.secondaryText)
        case .bigNumber:
            content.font(Typo.bigNumber).tracking(Typo.bigNumberTracking).foregroundStyle(Palette.ink)
        }
    }
}
