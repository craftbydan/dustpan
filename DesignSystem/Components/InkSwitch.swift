import SwiftUI

/// An on/off switch in the Dustpan style: an outlined capsule, mint when on, with a paper knob.
struct InkSwitch: View {
    @Binding var isOn: Bool
    let label: String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.mint : Palette.line)
                Circle()
                    .fill(Palette.paperFixed)
                    .overlay(Circle().strokeBorder(Palette.inkFixed, lineWidth: Stroke.outline))
                    .padding(Space.xxs)
            }
            .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: Stroke.outline))
            .frame(width: Metric.switchSize.width, height: Metric.switchSize.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : Fade.disabled)
        .animation(reduceMotion ? nil : Motion.select, value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
