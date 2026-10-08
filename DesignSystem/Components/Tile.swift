import SwiftUI

/// A category block: big size figure, label, chevron. Clicking opens the category.
///
/// `isSelected` (optional) turns it into one of a set: the chosen tile keeps its colour, the
/// others sit on paper with a colour chip. `compact` is the shorter version used in a column.
struct Tile: View {
    let tone: Tone
    let bytes: Int64
    let label: String
    /// A short line under the label, e.g. "3 of 12 selected".
    var detail: String?
    /// Shown instead of the size when there is no size to show (e.g. "Locked").
    var figure: String?
    var isSelected: Bool?
    var compact = false
    var action: () -> Void = {}

    private var filled: Bool { isSelected ?? true }
    private var textColor: Color { filled ? tone.onFill : Palette.ink }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? Space.xxs : Space.xs) {
                HStack(alignment: .center, spacing: Space.xs) {
                    if !filled { ToneGlyph(tone: tone) }
                    Text(figure ?? ByteFormat.string(bytes))
                        .font(compact ? Typo.tileNumberCompact : Typo.tileNumber)
                        .tracking(Typo.displayTracking / 2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(Typo.headline)
                        .lineLimit(compact ? 1 : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: Space.xs)
                    Image(systemName: "chevron.right").fontWeight(.black)
                }
                if let detail {
                    Text(detail)
                        .font(Typo.caption)
                        .lineLimit(2)
                        .opacity(filled ? 0.85 : 1)
                        .foregroundStyle(filled ? textColor : Palette.secondaryText)
                }
            }
            .foregroundStyle(textColor)
            .padding(compact ? Space.m : Space.l)
            .frame(
                minWidth: compact ? nil : Metric.tileMinWidth, maxWidth: .infinity,
                minHeight: compact ? Metric.tileCompactHeight : Metric.tileHeight, alignment: .leading)
        }
        .buttonStyle(TileButtonStyle(fill: filled ? tone.fill : Palette.paper))
        .accessibilityLabel(
            [label, figure ?? ByteFormat.string(bytes), detail.map(Self.spoken)].compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
    }
}

extension Tile {
    /// The detail line without typographic marks VoiceOver reads aloud ("·", "→"):
    /// "3 of 12 safe · Review →" → "3 of 12 safe, Review".
    static func spoken(_ detail: String) -> String {
        detail.replacingOccurrences(of: " →", with: "").replacingOccurrences(of: " · ", with: ", ")
    }
}

private struct TileButtonStyle: ButtonStyle {
    let fill: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let travel = configuration.isPressed ? Stroke.pressDepth : 0
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        configuration.label
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
            .offset(x: travel, y: travel)
            .background(shape.fill(Palette.ink).offset(x: Stroke.shadowOffset, y: Stroke.shadowOffset))
            .contentShape(shape)
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
    }
}

/// Byte formatting used everywhere: allocated sizes, `ByteCountFormatter(.file)`.
enum ByteFormat {
    /// Allocated size as file sizes, always with a number ("0 KB", never "Zero KB").
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
