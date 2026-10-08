import SwiftUI

/// Illustration, one sentence, and (optionally) the action that fills the screen.
struct EmptyState<Illustration: View>: View {
    let message: String
    var actionTitle: String?
    var actionSymbol: String?
    var action: (() -> Void)?
    @ViewBuilder let illustration: () -> Illustration

    init(
        _ message: String,
        actionTitle: String? = nil,
        actionSymbol: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder illustration: @escaping () -> Illustration
    ) {
        self.message = message
        self.actionTitle = actionTitle
        self.actionSymbol = actionSymbol
        self.action = action
        self.illustration = illustration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            illustration()
                .frame(width: Metric.illustration.width, height: Metric.illustration.height)
                .accessibilityHidden(true)
            Text(message)
                .font(Typo.title)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Metric.emptyStateTextWidth, alignment: .leading)
            if let actionTitle, let action {
                InkButton(actionTitle, systemImage: actionSymbol, action: action)
                    .padding(.top, Space.xs)
            }
        }
    }
}
