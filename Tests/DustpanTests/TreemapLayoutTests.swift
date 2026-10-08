import CoreGraphics
import Testing

@testable import Dustpan

@Suite("Treemap layout")
struct TreemapLayoutTests {
    @Test("Areas are proportional, inside the bounds, and don't overlap")
    func squarified() {
        let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = TreemapLayout.squarify(sizes, in: bounds)
        #expect(rects.count == sizes.count)
        let total = sizes.reduce(0, +)
        for (size, rect) in zip(sizes, rects) {
            let expected = Double(bounds.width * bounds.height) * size / total
            #expect(abs(Double(rect.width * rect.height) - expected) < 1)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
        // Squarified: the worst aspect ratio stays modest for this classic example.
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 3)
    }

    @Test("Empty and degenerate input")
    func degenerate() {
        #expect(TreemapLayout.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(TreemapLayout.squarify([1, 2], in: .zero) == [.zero, .zero])
        let single = TreemapLayout.squarify([5], in: CGRect(x: 2, y: 3, width: 10, height: 20))
        #expect(single == [CGRect(x: 2, y: 3, width: 10, height: 20)])
    }
}
