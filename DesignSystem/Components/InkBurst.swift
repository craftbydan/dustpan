import SwiftUI

/// A wobbly ink splash that bursts out once and then settles: a star-shaped blob with flecks
/// flying out, in the house style (flat fills, ink outlines, offset shadow). With Reduce Motion
/// on, it is drawn once at its final shape with no movement.
struct InkBurst: View {
    var tones: [Tone] = [.sweep, .dev, .installers, .logs]
    var size: CGFloat = Metric.burst

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var settled = false

    /// Seconds until the burst has fully grown; the wobble stops a little after.
    private static let grow: Double = 0.9
    private static let settle: Double = 3

    var body: some View {
        Group {
            if reduceMotion {
                BurstCanvas(progress: 1, phase: 0, tones: tones)
            } else {
                TimelineView(.animation(minimumInterval: nil, paused: settled)) { context in
                    let t = context.date.timeIntervalSince(start)
                    BurstCanvas(
                        progress: Self.easeOut(min(t / Self.grow, 1)),
                        phase: min(t, Self.settle) * 3,
                        tones: tones)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { start = Date() }
        .task {
            // Stop redrawing once it has settled.
            try? await Task.sleep(for: .seconds(Self.settle))
            settled = true
        }
    }

    private static func easeOut(_ x: Double) -> Double {
        // Overshoots slightly, then lands: a springy pop.
        let c = 1.7
        let p = x - 1
        return 1 + (c + 1) * p * p * p + c * p * p
    }
}

private struct BurstCanvas: View {
    let progress: Double
    let phase: Double
    let tones: [Tone]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            let outline = StrokeStyle(lineWidth: Stroke.outline, lineCap: .round, lineJoin: .round)
            let ink = GraphicsContext.Shading.color(Palette.ink)

            // Big splash: 11 wobbly spikes.
            let splash = Self.star(
                center: center, inner: r * 0.42 * progress, outer: r * 0.78 * progress, points: 11,
                wobble: 0.07, phase: phase)
            context.fill(splash.offsetBy(dx: Stroke.shadowOffset, dy: Stroke.shadowOffset), with: ink)
            context.fill(splash, with: .color(tones.first?.fill ?? Palette.sun))
            context.stroke(splash, with: ink, style: outline)

            // Inner blob.
            let blob = Self.star(
                center: center, inner: r * 0.3 * progress, outer: r * 0.36 * progress, points: 7, wobble: 0.05,
                phase: -phase * 0.8)
            context.fill(blob, with: .color(Palette.paper))
            context.stroke(blob, with: ink, style: outline)

            // Flecks flying out.
            for i in 0..<14 {
                let angle = Double(i) / 14 * 2 * .pi + 0.2
                let distance = r * (0.62 + 0.3 * Double((i * 7) % 5) / 4) * progress
                let radius = r * (0.035 + 0.02 * Double(i % 3)) * min(progress * 1.2, 1)
                let wob = sin(phase + Double(i)) * r * 0.012
                let point = CGPoint(
                    x: center.x + cos(angle) * (distance + wob), y: center.y + sin(angle) * (distance + wob))
                let dot = Path(
                    ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                let tone = tones.isEmpty ? Tone.sweep : tones[(i % max(tones.count - 1, 1)) + (tones.count > 1 ? 1 : 0)]
                context.fill(dot.offsetBy(dx: Stroke.shadowOffset / 2, dy: Stroke.shadowOffset / 2), with: ink)
                context.fill(dot, with: .color(tone.fill))
                context.stroke(dot, with: ink, style: outline)
            }
        }
    }

    /// A closed, smooth star whose radius wobbles with `phase`.
    static func star(
        center: CGPoint, inner: Double, outer: Double, points: Int, wobble: Double, phase: Double
    ) -> Path {
        let steps = points * 2
        var vertices: [CGPoint] = []
        for i in 0..<steps {
            let angle = Double(i) / Double(steps) * 2 * .pi - .pi / 2
            let base = i.isMultiple(of: 2) ? outer : inner
            let radius = base * (1 + wobble * sin(phase + Double(i) * 1.7))
            vertices.append(CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        }
        guard vertices.count > 2 else { return Path() }
        // Smooth through midpoints so the spikes look hand-drawn, not geometric.
        var path = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(vertices[vertices.count - 1], vertices[0]))
        for i in 0..<vertices.count {
            let next = vertices[(i + 1) % vertices.count]
            path.addQuadCurve(to: mid(vertices[i], next), control: vertices[i])
        }
        path.closeSubpath()
        return path
    }
}
