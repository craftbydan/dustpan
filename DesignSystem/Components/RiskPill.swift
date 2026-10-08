import SwiftUI

/// How safe an item is to remove. Mirrors `Rule.risk` (.never items never reach the UI).
enum RiskLevel: String, Sendable, CaseIterable {
    case safe, review

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        }
    }

    var fill: Color {
        switch self {
        case .safe: Palette.mint
        case .review: Palette.sun
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark"
        case .review: "eye"
        }
    }
}

/// A small outlined label: "Safe" or "Review". Text + symbol, never colour alone.
struct RiskPill: View {
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: risk.symbol).fontWeight(.heavy)
            Text(risk.label)
        }
        .font(Typo.pill)
        .foregroundStyle(Palette.inkFixed)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .background(Capsule().fill(risk.fill))
        .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: Stroke.outline * 0.8))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Risk: \(risk.label)")
    }
}

/// A tomato pill for something that needs the user first, e.g. "Quit Chrome first".
/// Text + symbol, never colour alone.
struct NoticePill: View {
    let text: String
    var systemImage = "power"

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: systemImage).fontWeight(.heavy)
            Text(text).lineLimit(1)
        }
        .font(Typo.pill)
        .foregroundStyle(Palette.inkFixed)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .background(Capsule().fill(Palette.tomato))
        .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: Stroke.outline * 0.8))
        // Not fixed-size: in a narrow list the text truncates instead of widening the row.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
