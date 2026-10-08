import SwiftUI

/// A row of outlined tabs; the chosen one is filled with the screen's colour.
struct InkTabs<Value: Hashable>: View {
    let tabs: [(value: Value, title: String)]
    @Binding var selection: Value
    var tone: Tone = .apps

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One row when it fits; otherwise two rows (never widens the screen in a narrow window).
        ViewThatFits(in: .horizontal) {
            row(tabs[...])
            VStack(alignment: .leading, spacing: Space.xs) {
                row(tabs[..<((tabs.count + 1) / 2)])
                row(tabs[((tabs.count + 1) / 2)...])
            }
        }
        .animation(reduceMotion ? nil : Motion.select, value: selection)
        .accessibilityElement(children: .contain)
    }

    private func row(_ part: ArraySlice<(value: Value, title: String)>) -> some View {
        HStack(spacing: Space.xs) {
            ForEach(Array(part), id: \.value) { tab in
                let isOn = tab.value == selection
                let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                Button {
                    selection = tab.value
                } label: {
                    Text(tab.title)
                        .font(Typo.label)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isOn ? tone.onFill : Palette.ink)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.xs)
                        .background(shape.fill(isOn ? tone.fill : Palette.paper))
                        .overlay(shape.strokeBorder(Palette.ink, lineWidth: isOn ? Stroke.outline : Stroke.hairline))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : [.isButton])
            }
        }
    }
}

/// A small outlined label on a colour, e.g. "Unused 6 months". Text, never colour alone.
struct InkBadge: View {
    let text: String
    var systemImage: String?
    var tone: Tone = .sweep

    var body: some View {
        HStack(spacing: Space.xxs) {
            if let systemImage { Image(systemName: systemImage).fontWeight(.heavy) }
            Text(text).lineLimit(1)
        }
        .font(Typo.pill)
        .foregroundStyle(tone.onFill)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .background(Capsule().fill(tone.fill))
        .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: Stroke.outline * 0.8))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
