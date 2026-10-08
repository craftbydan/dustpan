import SwiftUI

/// The frame every section screen sits in: a poster-size title with its colour block,
/// then content on paper.
struct Screen<Content: View>: View {
    let title: String
    let tone: Tone
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    ToneGlyph(tone: tone, size: Space.l)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(title)
                        .textStyle(.display)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityAddTraits(.isHeader)
                }
                content()
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.paper)
    }
}

/// The small outlined colour square used in the sidebar and screen titles.
struct ToneGlyph: View {
    let tone: Tone
    var size: CGFloat = Metric.sidebarGlyph

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        shape.fill(tone.fill)
            .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
