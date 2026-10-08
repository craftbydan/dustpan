import SwiftUI

/// A flat, outlined bar showing `value` out of `total`.
struct SizeBar: View {
    /// The filled part (e.g. bytes used).
    let value: Int64
    let total: Int64
    var tone: Tone = .sweep
    var height: CGFloat = Metric.sizeBarHeight

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(max(Double(value) / Double(total), 0), 1))
    }

    var body: some View {
        let shape = Capsule()
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                shape.fill(Palette.paper)
                Rectangle()
                    .fill(tone.fill)
                    .frame(width: proxy.size.width * fraction)
                    .overlay(alignment: .trailing) {
                        // The ink edge where filled meets empty.
                        Rectangle().fill(Palette.ink).frame(width: fraction > 0 && fraction < 1 ? Stroke.outline : 0)
                    }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
