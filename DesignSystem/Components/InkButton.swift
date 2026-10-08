import SwiftUI

/// The primary control. A flat block with an ink outline sitting on a solid ink shadow;
/// pressing pushes it 2 pt down into the shadow.
struct InkButton: View {
    enum Kind: Sendable {
        /// Tomato fill — one per screen.
        case primary
        /// Paper fill.
        case secondary
    }

    enum Size: Sendable {
        case regular
        /// Tighter padding and a shallower shadow, for inside rows and bars.
        case small
    }

    let title: String
    var systemImage: String?
    var kind: Kind = .primary
    var size: Size = .regular
    let action: () -> Void

    init(
        _ title: String, systemImage: String? = nil, kind: Kind = .primary, size: Size = .regular,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage).fontWeight(.bold)
                }
                Text(title)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(InkButtonStyle(kind: kind, size: size))
        .accessibilityLabel(title)
    }
}

/// Style behind `InkButton`; also usable on any `Button`.
struct InkButtonStyle: ButtonStyle {
    var kind: InkButton.Kind = .primary
    var size: InkButton.Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        InkButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct InkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: InkButton.Kind
    var size: InkButton.Size = .regular

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var pressed: Bool { configuration.isPressed && isEnabled }

    private var fill: Color { kind == .primary ? Palette.tomato : Palette.paper }
    private var text: Color { kind == .primary ? Palette.inkFixed : Palette.ink }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        let small = size == .small
        let shadow = small ? Stroke.pressDepth : Stroke.shadowOffset
        let travel = pressed ? (small ? shadow : Stroke.pressDepth) : (hovering && isEnabled ? -1 : 0)
        configuration.label
            .font(small ? Typo.pill : Typo.label)
            .foregroundStyle(text)
            .padding(.horizontal, small ? Space.s : Space.l)
            .padding(.vertical, small ? Space.xxs + Space.xxs / 2 : Space.s)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
            .offset(x: travel, y: travel)
            .background(
                shape.fill(Palette.ink)
                    .offset(x: shadow, y: shadow)
            )
            .overlay(
                // Keyboard focus: a second ring outside the outline, in cobalt.
                shape.inset(by: -Space.xxs - Stroke.outline)
                    .stroke(Palette.cobalt, lineWidth: Stroke.outline)
                    .opacity(focused ? 1 : 0)
            )
            .contentShape(shape)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : Fade.disabled)
            .animation(reduceMotion ? nil : Motion.press, value: pressed)
            .animation(reduceMotion ? nil : Motion.press, value: hovering)
    }
}
