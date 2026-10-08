import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk).
///
/// Adapted from MacDirStat's `TreemapLayoutEngine.squarify` (MIT, Copyright (c) 2026 Josh
/// Auriemma, https://github.com/phalladar/MacDirStat) — see THIRD_PARTY_NOTICES.md. Changes:
/// works on CGRect, keeps the row's worst aspect ratio from running sums instead of rebuilding
/// the row, lays a row along the shorter side, and returns rects in input order.
enum TreemapLayout {
    /// Rects for `sizes` (biggest first, all > 0) filling `bounds`. Areas are proportional to
    /// the sizes; the result has one rect per size, in the same order.
    static func squarify(_ sizes: [Double], in bounds: CGRect) -> [CGRect] {
        guard !sizes.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return Array(repeating: .zero, count: sizes.count)
        }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return Array(repeating: .zero, count: sizes.count) }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = sizes.map { $0 * scale }

        var rects = [CGRect](repeating: .zero, count: sizes.count)
        var remaining = bounds
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var sum = areas[start]
            var best = worst(sum: sum, largest: areas[start], smallest: areas[start], side: side)
            while end < areas.count {
                let nextSum = sum + areas[end]
                // Sizes come biggest first, so the row's largest is its first, its smallest the new one.
                let ratio = worst(sum: nextSum, largest: areas[start], smallest: areas[end], side: side)
                if ratio > best { break }
                best = ratio
                sum = nextSum
                end += 1
            }

            let remainingArea = Double(remaining.width * remaining.height)
            let fraction = remainingArea > 0 ? sum / remainingArea : 0
            if remaining.width >= remaining.height {
                // Row as a column on the left.
                let width = remaining.width * CGFloat(fraction)
                var y = remaining.minY
                for i in start..<end {
                    let height = sum > 0 ? remaining.height * CGFloat(areas[i] / sum) : 0
                    rects[i] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(
                    x: remaining.minX + width, y: remaining.minY, width: max(remaining.width - width, 0),
                    height: remaining.height)
            } else {
                // Row along the top.
                let height = remaining.height * CGFloat(fraction)
                var x = remaining.minX
                for i in start..<end {
                    let width = sum > 0 ? remaining.width * CGFloat(areas[i] / sum) : 0
                    rects[i] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(
                    x: remaining.minX, y: remaining.minY + height, width: remaining.width,
                    height: max(remaining.height - height, 0))
            }
            start = end
        }
        return rects
    }

    /// The worst aspect ratio in a row of total area `sum` laid along a side of length `side`.
    private static func worst(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        guard side > 0, sum > 0, smallest > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}
