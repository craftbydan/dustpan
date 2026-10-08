import SwiftUI

// Dustpan design tokens. "Loud, honest, hand-made": warm paper, thick ink outlines,
// flat saturated fills, solid offset shadows. Feature views use these tokens only —
// never raw colours, sizes or radii.
//
// Colour values live in `DesignSystem/Colors.xcassets` (light / dark):
//   paper #F6F1E7 / #17140F   ink #141210 / #F6F1E7
//   tomato #FF4B2B  sun #FFC21A  cobalt #2648FF  mint #1FCF8F  bubblegum #FF7AC6
//   stone #8C857A
//   secondaryText #6B6459 / #8C857A — stone darkened in light mode for 4.5:1 body contrast
//   inkFixed #141210, paperFixed #F6F1E7 — text on saturated fills, same in both modes

/// Colour tokens.
enum Palette {
    static let paper = Color(.paper)
    static let ink = Color(.ink)
    static let tomato = Color(.tomato)
    static let sun = Color(.sun)
    static let cobalt = Color(.cobalt)
    static let mint = Color(.mint)
    static let bubblegum = Color(.bubblegum)
    static let stone = Color(.stone)

    /// Secondary text (captions, metadata). Stone in dark mode; a darker stone in light
    /// mode so 12 pt text keeps a 5:1 contrast on paper.
    static let secondaryText = Color(.secondaryText)
    /// Hairlines and dividers: ink at 12 %.
    static let line = Color(.ink).opacity(0.12)
    /// Ink that stays dark in both modes — for text and outlines on saturated fills.
    static let inkFixed = Color(.inkFixed)
    /// Paper that stays light in both modes — for text on cobalt.
    static let paperFixed = Color(.paperFixed)

    /// Every swatch, for `DesignPreview`.
    static let all: [(name: String, color: Color)] = [
        ("paper", paper), ("ink", ink), ("tomato", tomato), ("sun", sun),
        ("cobalt", cobalt), ("mint", mint), ("bubblegum", bubblegum), ("stone", stone),
        ("secondaryText", secondaryText), ("line", line),
    ]
}

/// A colour family used for tiles, sidebar glyphs, illustrations and bars.
/// The category → colour map from the design brief lives here.
enum Tone: String, CaseIterable, Sendable {
    // Scan categories
    case userCache, logs, savedState, dev, ai, installers, trash, xcode
    // Screens
    case sweep, apps, spaceMap, clutter, history, settings

    var fill: Color {
        switch self {
        case .userCache, .savedState, .sweep: Palette.sun
        case .logs, .spaceMap: Palette.cobalt
        case .dev, .ai, .xcode: Palette.bubblegum
        case .installers, .clutter: Palette.mint
        case .trash, .history, .settings: Palette.stone
        case .apps: Palette.tomato
        }
    }

    /// Text / icon colour that reads on `fill` (≥ 4.5:1 for all fills).
    var onFill: Color {
        switch self {
        case .logs, .spaceMap: Palette.paperFixed
        default: Palette.inkFixed
        }
    }
}

/// Corner radii, by role.
enum Radius {
    /// Pills, checkboxes, small controls.
    static let small: CGFloat = 10
    /// Buttons, rows, tiles.
    static let medium: CGFloat = 18
    /// Large surfaces and panels.
    static let large: CGFloat = 28
}

/// The one spacing scale.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64

    static let scale: [CGFloat] = [xxs, xs, s, m, l, xl, xxl, xxxl]
}

/// Outline and shadow geometry.
enum Stroke {
    /// Every ink outline.
    static let outline: CGFloat = 2.5
    /// Thin rules inside components.
    static let hairline: CGFloat = 1
    /// The solid ink shadow: offset right and down, no blur.
    static let shadowOffset: CGFloat = 4
    /// How far a pressed control travels into its shadow.
    static let pressDepth: CGFloat = 2
}

/// Fixed component sizes (kept here so feature views carry no raw numbers).
enum Metric {
    static let sidebarGlyph: CGFloat = 14
    /// The menu-bar item's Dustpan glyph (points, square).
    static let menuBarGlyph: CGFloat = 18
    static let sidebarMinWidth: CGFloat = 200
    static let checkbox: CGFloat = 20
    static let rowIcon: CGFloat = 32
    static let sizeBarHeight: CGFloat = 12
    static let illustration = CGSize(width: 240, height: 180)
    static let emptyStateTextWidth: CGFloat = 420
    static let blob: CGFloat = 160
    static let tileMinWidth: CGFloat = 220
    static let tileHeight: CGFloat = 180
    /// A `Tile` in a column (Junk categories).
    static let tileCompactHeight: CGFloat = 104
    /// The Junk screen's category column.
    static let categoryColumnWidth: CGFloat = 250
    /// The Junk category column in a narrow window, so the item list keeps room to read.
    static let categoryColumnCompactWidth: CGFloat = 200
    /// Below this item-list width the Junk category column uses its compact width.
    static let junkListComfortWidth: CGFloat = 460
    /// Confirmation sheets.
    static let sheetWidth: CGFloat = 480
    /// A scrolling list inside a confirmation sheet (e.g. an app's leftovers).
    static let sheetListMaxHeight: CGFloat = 240
    /// The ink burst behind the freed number.
    static let burst: CGFloat = 280
    /// Search field in list headers.
    static let searchWidth: CGFloat = 200
    /// The search field may shrink to this in a narrow window.
    static let searchMinWidth: CGFloat = 140
    /// Detail popovers (full why, source and path).
    static let popoverWidth: CGFloat = 360
    /// Apps screen: the app list column, and the big icon in the app detail.
    static let appListWidth: CGFloat = 320
    static let appIconLarge: CGFloat = 64
    /// Space map: the side list, the smallest block that gets a label, the hover card, and the
    /// colour swatch in list rows.
    static let spaceListWidth: CGFloat = 300
    static let treemapLabelMin = CGSize(width: 60, height: 24)
    static let tooltipWidth: CGFloat = 260
    static let swatch: CGFloat = 12
    /// Clutter: the Quick Look thumbnail on a duplicate card, and the widest a card or the
    /// Large & old list gets.
    static let clutterThumbnail: CGFloat = 72
    static let clutterMaxWidth: CGFloat = 860
    static let windowMin = CGSize(width: 900, height: 600)
    static let windowDefault = CGSize(width: 1080, height: 720)
    /// Onboarding: the illustration beside each step, and the text column's width.
    static let onboardingIllustration = CGSize(width: 320, height: 240)
    static let onboardingTextWidth: CGFloat = 440
    /// Onboarding: the "step x of 3" dashes.
    static let stepDash = CGSize(width: 28, height: 8)
    /// Onboarding: the numbered circles in the access guide.
    static let guideNumber: CGFloat = 24
    /// Menu-bar popover width, and the thin bar inside its gauges.
    static let menuPopoverWidth: CGFloat = 360
    static let gaugeBarHeight: CGFloat = 8
    /// `InkSwitch`.
    static let switchSize = CGSize(width: 48, height: 28)
    /// Settings: the widest a settings card gets.
    static let settingsMaxWidth: CGFloat = 640
}

/// Opacity for controls that can't be used right now (disabled buttons, switches, rows).
enum Fade {
    static let disabled: Double = 0.4
}

/// Motion. Springs only; callers check `accessibilityReduceMotion`.
enum Motion {
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.6)
    static let fill = Animation.spring(response: 0.5, dampingFraction: 0.75)
    static let select = Animation.spring(response: 0.25, dampingFraction: 0.85)
}

extension View {
    /// The signature surface: flat fill, 2.5 pt ink outline, solid 4 pt offset ink shadow.
    func inkSurface(
        _ fill: Color,
        radius: CGFloat = Radius.medium,
        shadow: CGFloat = Stroke.shadowOffset
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return
            self
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
            .background(shape.fill(Palette.ink).offset(x: shadow, y: shadow))
    }
}
