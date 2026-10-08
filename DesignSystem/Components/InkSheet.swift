import SwiftUI

/// A confirmation card over a dimmed screen, drawn inside the window (not a separate sheet
/// window). Escape or a click on the backdrop cancels. Content supplies its own buttons.
struct InkSheet<Content: View>: View {
    let title: String
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Palette.inkFixed.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.l) {
                Text(title)
                    .font(Typo.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
            .padding(Space.xl)
            .frame(width: Metric.sheetWidth, alignment: .leading)
            .inkSurface(Palette.paper, radius: Radius.large)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel(title)
        }
        .onExitCommand(perform: onCancel)
    }
}
