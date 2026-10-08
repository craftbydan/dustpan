import SwiftUI

/// One found item: checkbox, icon, name, size, a one-line reason, and its risk.
///
/// Optional extras: `detail` (a caption under the size, e.g. the date), `selectable: false`
/// (shown for information only; the checkbox is dimmed and does nothing), `help` (full text
/// shown on hover) and `info` (an ⓘ button, e.g. to open a details popover; VoiceOver users get
/// the same through the caller's named accessibility actions). `blocker` marks an item that
/// waits on an open app: a tomato "Quit Chrome first" pill, an inline "Quit Chrome" button, and
/// a checkbox that can't be ticked until the app is closed.
struct ExplainRow: View {
    /// The open app an item waits on.
    struct Blocker {
        let appName: String
        /// Nil hides the Quit button (e.g. the app can't be named by bundle ID).
        var quit: (() -> Void)?
        var isQuitting = false
    }

    @Binding var isSelected: Bool
    let systemImage: String
    let tone: Tone
    let name: String
    let bytes: Int64
    /// Plain words, ≤ 140 characters.
    let why: String
    let risk: RiskLevel
    var detail: String?
    var selectable = true
    var help: String?
    var info: (() -> Void)?
    var blocker: Blocker?

    private var canTick: Bool { selectable && blocker == nil }

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            InkCheckbox(isOn: $isSelected, label: name)
                .disabled(!canTick)
                .opacity(canTick ? 1 : 0.35)
                .accessibilityHint(blocker.map { "Can't be ticked while \($0.appName) is open" } ?? "")
            Image(systemName: systemImage)
                .fontWeight(.semibold)
                .foregroundStyle(tone.onFill)
                .frame(width: Metric.rowIcon, height: Metric.rowIcon)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(tone.fill))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .strokeBorder(Palette.ink, lineWidth: Stroke.outline * 0.8)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(name).textStyle(.headline).lineLimit(1)
                    RiskPill(risk: risk)
                }
                // A blocked row leads its reason line with the tomato pill, so the title stays readable.
                if let blocker {
                    // Pill and Quit side by side; stacked when the list is too narrow for both.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.xs) { blockerParts(blocker) }
                        VStack(alignment: .leading, spacing: Space.xxs) { blockerParts(blocker) }
                    }
                } else {
                    Text(why).textStyle(.caption).lineLimit(1).truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Space.m)
            VStack(alignment: .trailing, spacing: Space.xxs) {
                Text(ByteFormat.string(bytes))
                    .font(Typo.headline.monospacedDigit())
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).textStyle(.caption).lineLimit(1)
                }
            }
            .fixedSize()
            if let info {
                Button(action: info) {
                    Image(systemName: "info.circle")
                        .font(Typo.headline)
                        .foregroundStyle(Palette.ink)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(name)")
            }
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.m)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.line).frame(height: Stroke.hairline)
        }
        .contentShape(Rectangle())
        .onTapGesture { if canTick { isSelected.toggle() } }
        .help(help ?? "")
        // One VoiceOver element per row: what it is, its size and risk, why, then whether it's
        // ticked. Activating the row ticks it; callers add named actions (details, ignore, …).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(spokenValue)
        .accessibilityHint(blocker.map { "Quit \($0.appName) first, then tick it" } ?? "")
        .accessibilityAddTraits(canTick ? .isToggle : [])
        .accessibilityAction { if canTick { isSelected.toggle() } }
        .accessibilityActions {
            if let blocker, let quit = blocker.quit, !blocker.isQuitting {
                Button("Quit \(blocker.appName)", action: quit)
            }
        }
    }

    @ViewBuilder
    private func blockerParts(_ blocker: Blocker) -> some View {
        NoticePill(text: "Quit \(blocker.appName) first")
        // Right by the pill (not in the trailing column) so the row fits a narrow list.
        if let quit = blocker.quit {
            InkButton(blocker.isQuitting ? "Quitting…" : "Quit", kind: .secondary, size: .small, action: quit)
                .disabled(blocker.isQuitting)
                .accessibilityLabel("Quit \(blocker.appName)")
        }
    }

    private var spokenValue: String {
        if let blocker { return "Can't be ticked while \(blocker.appName) is open" }
        return selectable ? (isSelected ? "Selected" : "Not selected") : "Shown for information only"
    }

    private var spokenLabel: String {
        [name, ByteFormat.string(bytes), risk.label, why, detail].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// A square ink-outlined checkbox.
struct InkCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small / 2, style: .continuous)
        Button {
            isOn.toggle()
        } label: {
            shape.fill(isOn ? Palette.tomato : Palette.paper)
                .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(Typo.pill)
                            .foregroundStyle(Palette.inkFixed)
                    }
                }
                .frame(width: Metric.checkbox, height: Metric.checkbox)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isToggle)
    }
}
