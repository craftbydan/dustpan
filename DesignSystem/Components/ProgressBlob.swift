import SwiftUI

/// A wobbly ink circle that fills from the bottom as a scan progresses. No spinner.
/// With Reduce Motion on, the wobble stops and the fill changes without animation.
struct ProgressBlob: View {
    /// 0…1.
    let progress: Double
    var tone: Tone = .sweep
    var size: CGFloat = Metric.blob

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                BlobBody(progress: progress, phase: 0, tone: tone)
            } else {
                TimelineView(.animation) { context in
                    BlobBody(
                        progress: progress,
                        phase: context.date.timeIntervalSinceReferenceDate,
                        tone: tone
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : Motion.fill, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
    }
}

private struct BlobBody: View {
    let progress: Double
    let phase: Double
    let tone: Tone

    var body: some View {
        let blob = WobblyCircle(phase: phase)
        ZStack {
            blob.fill(Palette.ink).offset(x: Stroke.shadowOffset, y: Stroke.shadowOffset)
            blob.fill(Palette.paper)
            FillLevel(level: min(max(progress, 0), 1), phase: phase)
                .fill(tone.fill)
                .clipShape(blob)
            blob.stroke(Palette.ink, style: StrokeStyle(lineWidth: Stroke.outline * 1.2, lineJoin: .round))
        }
    }
}

/// A circle whose radius wobbles slightly with `phase` (seconds).
struct WobblyCircle: Shape {
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2 * 0.92
        let steps = 96
        var path = Path()
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let wobble =
                sin(a * 3 + phase * 1.6) * 0.035
                + sin(a * 5 - phase * 1.1) * 0.02
            let r = base * (1 + wobble)
            let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// The liquid inside the blob: fills to `level` with a gently moving top edge.
private struct FillLevel: Shape {
    var level: Double
    var phase: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = rect.maxY - rect.height * level
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        let steps = 40
        let amplitude = level <= 0 || level >= 1 ? 0 : rect.height * 0.025
        for i in 0...steps {
            let x = rect.minX + rect.width * Double(i) / Double(steps)
            let y = top + sin(Double(i) / Double(steps) * 2 * .pi * 1.5 + phase * 2) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
