import SwiftUI

/// A calm, persistent notice across the top of a screen: a small glyph, one or two lines of
/// plain text and an optional action. For non-fatal states (never a modal).
struct QuietBanner: View {
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    /// An optional second link before the main one (e.g. "Open Trash in Finder" before "OK").
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    init(
        systemImage: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
        secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        HStack(spacing: Space.s) {
            Image(systemName: systemImage)
                .font(Typo.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityHidden(true)
            Text(message)
                .textStyle(.body)
                // No vertical fixedSize: inside a split view, sizing passes propose tiny widths and
                // a fixed-height text would ask for a window-tall banner.
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityLabel(secondaryTitle)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityLabel(actionTitle)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(shape.fill(Palette.line))
        .overlay(shape.strokeBorder(Palette.ink.opacity(0.25), lineWidth: Stroke.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// An underlined ink text button, for low-key actions next to text.
struct QuietLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLinkBody(configuration: configuration)
    }
}

private struct QuietLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(Typo.label)
            .underline(true, color: Palette.ink)
            .foregroundStyle(Palette.ink)
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.4))
            .padding(.vertical, Space.xxs)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .background(
                RoundedRectangle(cornerRadius: Radius.small / 2, style: .continuous)
                    .fill(hovering && isEnabled ? Palette.line : .clear)
                    .padding(-Space.xxs)
            )
    }
}
