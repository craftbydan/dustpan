import SwiftUI

/// Original section illustrations, drawn in code: flat fills, 2.5 pt ink outlines,
/// solid offset ink shadows. Each is designed on a 240 × 180 grid and scales to fit.
enum Illustration: String, CaseIterable, Sendable {
    case sweep, junk, apps, spaceMap, clutter, history, settings
    /// Onboarding: dust going into a bin — everything goes to the Trash first.
    case welcome
    /// Onboarding: the mini guide — Dustpan's tile dragged into a settings list of switches.
    case accessGuide
    /// Onboarding: an open padlock and a check.
    case accessDone
}

struct IllustrationView: View {
    let kind: Illustration

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / Self.grid.width, size.height / Self.grid.height)
            context.translateBy(
                x: (size.width - Self.grid.width * scale) / 2,
                y: (size.height - Self.grid.height * scale) / 2
            )
            context.scaleBy(x: scale, y: scale)
            var pen = InkPen(context: context)
            switch kind {
            case .sweep: Self.sweep(&pen)
            case .junk: Self.junk(&pen)
            case .apps: Self.apps(&pen)
            case .spaceMap: Self.spaceMap(&pen)
            case .clutter: Self.clutter(&pen)
            case .history: Self.history(&pen)
            case .settings: Self.settings(&pen)
            case .welcome: Self.welcome(&pen)
            case .accessGuide: Self.accessGuide(&pen)
            case .accessDone: Self.accessDone(&pen)
            }
        }
        .aspectRatio(Self.grid.width / Self.grid.height, contentMode: .fit)
    }

    static let grid = CGSize(width: 240, height: 180)

    // MARK: Drawings

    /// A dustpan with three dust dots in front of it — the app icon's mark.
    private static func sweep(_ pen: inout InkPen) {
        pen.rotated(by: -16, around: CGPoint(x: 130, y: 92)) { pen in
            pen.shape(
                Path(roundedRect: CGRect(x: 120, y: 12, width: 24, height: 62), cornerRadius: 10), fill: Palette.sun)
            var pan = Path()
            pan.move(to: CGPoint(x: 88, y: 74))
            pan.addQuadCurve(to: CGPoint(x: 176, y: 74), control: CGPoint(x: 132, y: 48))
            pan.addLine(to: CGPoint(x: 198, y: 138))
            pan.addLine(to: CGPoint(x: 66, y: 138))
            pan.closeSubpath()
            pen.shape(pan, fill: Palette.sun)
            var seams = Path()
            seams.move(to: CGPoint(x: 94, y: 90))
            seams.addQuadCurve(to: CGPoint(x: 170, y: 90), control: CGPoint(x: 132, y: 70))
            seams.move(to: CGPoint(x: 72, y: 124))
            seams.addLine(to: CGPoint(x: 192, y: 124))
            pen.stroke(seams)
        }
        pen.circle(center: CGPoint(x: 42, y: 156), radius: 13, fill: Palette.tomato)
        pen.circle(center: CGPoint(x: 76, y: 162), radius: 10, fill: Palette.tomato)
        pen.circle(center: CGPoint(x: 104, y: 160), radius: 7, fill: Palette.tomato)
    }

    /// An open box overflowing with cache sheets and a crumpled ball.
    private static func junk(_ pen: inout InkPen) {
        pen.rotated(by: -8, around: CGPoint(x: 100, y: 70)) { pen in
            pen.shape(
                Path(roundedRect: CGRect(x: 70, y: 28, width: 64, height: 80), cornerRadius: 6), fill: Palette.paper)
            pen.line(from: CGPoint(x: 82, y: 46), to: CGPoint(x: 120, y: 46))
            pen.line(from: CGPoint(x: 82, y: 60), to: CGPoint(x: 112, y: 60))
        }
        pen.rotated(by: 10, around: CGPoint(x: 140, y: 70)) { pen in
            pen.shape(
                Path(roundedRect: CGRect(x: 118, y: 30, width: 58, height: 74), cornerRadius: 6), fill: Palette.mint)
        }
        // Box
        var box = Path()
        box.move(to: CGPoint(x: 44, y: 86))
        box.addLine(to: CGPoint(x: 196, y: 86))
        box.addLine(to: CGPoint(x: 186, y: 166))
        box.addLine(to: CGPoint(x: 54, y: 166))
        box.closeSubpath()
        pen.shape(box, fill: Palette.sun)
        // Flaps
        var flapL = Path()
        flapL.move(to: CGPoint(x: 44, y: 86))
        flapL.addLine(to: CGPoint(x: 18, y: 70))
        flapL.addLine(to: CGPoint(x: 30, y: 104))
        flapL.addLine(to: CGPoint(x: 48, y: 110))
        flapL.closeSubpath()
        pen.shape(flapL, fill: Palette.sun)
        var flapR = Path()
        flapR.move(to: CGPoint(x: 196, y: 86))
        flapR.addLine(to: CGPoint(x: 224, y: 66))
        flapR.addLine(to: CGPoint(x: 214, y: 102))
        flapR.addLine(to: CGPoint(x: 193, y: 110))
        flapR.closeSubpath()
        pen.shape(flapR, fill: Palette.sun)
        // Crumpled ball
        pen.circle(center: CGPoint(x: 182, y: 150), radius: 20, fill: Palette.bubblegum)
        var crease = Path()
        crease.move(to: CGPoint(x: 170, y: 142))
        crease.addLine(to: CGPoint(x: 182, y: 152))
        crease.addLine(to: CGPoint(x: 178, y: 164))
        crease.move(to: CGPoint(x: 182, y: 152))
        crease.addLine(to: CGPoint(x: 196, y: 146))
        pen.stroke(crease)
    }

    /// A fan of app blocks; one lifts away trailing its leftover files.
    private static func apps(_ pen: inout InkPen) {
        pen.rotated(by: -10, around: CGPoint(x: 70, y: 110)) { pen in
            pen.shape(
                Path(roundedRect: CGRect(x: 30, y: 74, width: 72, height: 72), cornerRadius: 18), fill: Palette.cobalt)
        }
        pen.shape(Path(roundedRect: CGRect(x: 74, y: 80, width: 72, height: 72), cornerRadius: 18), fill: Palette.mint)
        pen.rotated(by: 14, around: CGPoint(x: 176, y: 56)) { pen in
            pen.shape(
                Path(roundedRect: CGRect(x: 140, y: 20, width: 72, height: 72), cornerRadius: 18), fill: Palette.tomato)
            pen.circle(center: CGPoint(x: 176, y: 56), radius: 14, fill: Palette.paper)
        }
        // Leftovers following it out
        pen.shape(
            Path(roundedRect: CGRect(x: 160, y: 116, width: 18, height: 22), cornerRadius: 3), fill: Palette.paper)
        pen.shape(
            Path(roundedRect: CGRect(x: 186, y: 132, width: 14, height: 18), cornerRadius: 3), fill: Palette.paper)
        pen.shape(
            Path(roundedRect: CGRect(x: 208, y: 146, width: 11, height: 14), cornerRadius: 3), fill: Palette.paper)
    }

    /// A treemap: the disk as blocks sized by what they hold.
    private static func spaceMap(_ pen: inout InkPen) {
        let blocks: [(CGRect, Color)] = [
            (CGRect(x: 24, y: 20, width: 110, height: 140), Palette.cobalt),
            (CGRect(x: 134, y: 20, width: 82, height: 74), Palette.sun),
            (CGRect(x: 134, y: 94, width: 48, height: 66), Palette.mint),
            (CGRect(x: 182, y: 94, width: 34, height: 34), Palette.bubblegum),
            (CGRect(x: 182, y: 128, width: 34, height: 32), Palette.tomato),
        ]
        let frame = Path(roundedRect: CGRect(x: 24, y: 20, width: 192, height: 140), cornerRadius: 10)
        pen.shadow(frame)
        pen.clipped(to: frame) { pen in
            for (rect, color) in blocks {
                pen.shape(Path(rect), fill: color, shadow: false)
            }
            // Sub-folders inside the big block
            pen.line(from: CGPoint(x: 24, y: 104), to: CGPoint(x: 134, y: 104))
            pen.line(from: CGPoint(x: 84, y: 104), to: CGPoint(x: 84, y: 160))
        }
        pen.stroke(frame)
    }

    /// One oversized file behind two exact duplicates.
    private static func clutter(_ pen: inout InkPen) {
        pen.rotated(by: -6, around: CGPoint(x: 80, y: 90)) { pen in
            pen.shape(Self.document(CGRect(x: 26, y: 16, width: 104, height: 140)), fill: Palette.sun)
            pen.line(from: CGPoint(x: 44, y: 70), to: CGPoint(x: 108, y: 70))
            pen.line(from: CGPoint(x: 44, y: 88), to: CGPoint(x: 112, y: 88))
            pen.line(from: CGPoint(x: 44, y: 106), to: CGPoint(x: 96, y: 106))
        }
        pen.shape(Self.document(CGRect(x: 128, y: 46, width: 60, height: 80)), fill: Palette.mint)
        pen.shape(Self.document(CGRect(x: 154, y: 74, width: 60, height: 80)), fill: Palette.mint)
        pen.line(from: CGPoint(x: 168, y: 106), to: CGPoint(x: 200, y: 106))
        pen.line(from: CGPoint(x: 168, y: 120), to: CGPoint(x: 200, y: 120))
    }

    /// A bin with an arrow bringing a file back out.
    private static func history(_ pen: inout InkPen) {
        // Can
        var can = Path()
        can.move(to: CGPoint(x: 40, y: 72))
        can.addLine(to: CGPoint(x: 128, y: 72))
        can.addLine(to: CGPoint(x: 118, y: 166))
        can.addLine(to: CGPoint(x: 50, y: 166))
        can.closeSubpath()
        pen.shape(can, fill: Palette.stone)
        pen.line(from: CGPoint(x: 66, y: 90), to: CGPoint(x: 70, y: 150))
        pen.line(from: CGPoint(x: 84, y: 90), to: CGPoint(x: 84, y: 150))
        pen.line(from: CGPoint(x: 102, y: 90), to: CGPoint(x: 98, y: 150))
        pen.shape(Path(roundedRect: CGRect(x: 30, y: 56, width: 108, height: 16), cornerRadius: 6), fill: Palette.stone)
        // Return arrow
        var arc = Path()
        arc.move(to: CGPoint(x: 96, y: 48))
        arc.addQuadCurve(to: CGPoint(x: 178, y: 66), control: CGPoint(x: 128, y: 2))
        pen.thickStroke(arc, color: Palette.tomato)
        var head = Path()
        head.move(to: CGPoint(x: 164, y: 56))
        head.addLine(to: CGPoint(x: 194, y: 62))
        head.addLine(to: CGPoint(x: 176, y: 86))
        head.closeSubpath()
        pen.shape(head, fill: Palette.tomato)
        // The file, safe again
        pen.rotated(by: 8, around: CGPoint(x: 186, y: 128)) { pen in
            pen.shape(Self.document(CGRect(x: 160, y: 96, width: 52, height: 66)), fill: Palette.paper)
        }
    }

    /// Three sliders.
    private static func settings(_ pen: inout InkPen) {
        let rows: [(y: CGFloat, knob: CGFloat, color: Color)] = [
            (44, 150, Palette.tomato), (92, 74, Palette.sun), (140, 178, Palette.cobalt),
        ]
        for row in rows {
            pen.shape(
                Path(roundedRect: CGRect(x: 26, y: row.y - 7, width: 188, height: 14), cornerRadius: 7),
                fill: Palette.paper)
            pen.shape(
                Path(roundedRect: CGRect(x: 26, y: row.y - 7, width: row.knob - 26, height: 14), cornerRadius: 7),
                fill: row.color, shadow: false)
            pen.circle(center: CGPoint(x: row.knob, y: row.y), radius: 17, fill: Palette.paper)
        }
    }

    /// A small dustpan tipping three dust dots into a bin.
    private static func welcome(_ pen: inout InkPen) {
        // Bin
        var bin = Path()
        bin.move(to: CGPoint(x: 138, y: 96))
        bin.addLine(to: CGPoint(x: 214, y: 96))
        bin.addLine(to: CGPoint(x: 205, y: 168))
        bin.addLine(to: CGPoint(x: 147, y: 168))
        bin.closeSubpath()
        pen.shape(bin, fill: Palette.stone)
        pen.line(from: CGPoint(x: 160, y: 112), to: CGPoint(x: 163, y: 154))
        pen.line(from: CGPoint(x: 176, y: 112), to: CGPoint(x: 176, y: 154))
        pen.line(from: CGPoint(x: 192, y: 112), to: CGPoint(x: 189, y: 154))
        pen.shape(Path(roundedRect: CGRect(x: 130, y: 82, width: 92, height: 14), cornerRadius: 6), fill: Palette.stone)
        // Dustpan, tipped toward the bin
        pen.rotated(by: 22, around: CGPoint(x: 64, y: 96)) { pen in
            pen.shape(
                Path(roundedRect: CGRect(x: 54, y: 18, width: 20, height: 50), cornerRadius: 9), fill: Palette.sun)
            var pan = Path()
            pan.move(to: CGPoint(x: 26, y: 68))
            pan.addQuadCurve(to: CGPoint(x: 102, y: 68), control: CGPoint(x: 64, y: 46))
            pan.addLine(to: CGPoint(x: 120, y: 122))
            pan.addLine(to: CGPoint(x: 8, y: 122))
            pan.closeSubpath()
            pen.shape(pan, fill: Palette.sun)
            pen.line(from: CGPoint(x: 14, y: 108), to: CGPoint(x: 114, y: 108))
        }
        // Dust on its way in
        pen.circle(center: CGPoint(x: 112, y: 150), radius: 9, fill: Palette.tomato)
        pen.circle(center: CGPoint(x: 124, y: 112), radius: 7, fill: Palette.tomato)
        pen.circle(center: CGPoint(x: 142, y: 62), radius: 6, fill: Palette.tomato)
    }

    /// The Full Disk Access mini guide: a settings panel with a list of apps and switches,
    /// an empty dashed slot, and Dustpan's tile being dragged into it.
    private static func accessGuide(_ pen: inout InkPen) {
        let panel = Path(roundedRect: CGRect(x: 72, y: 12, width: 160, height: 156), cornerRadius: 12)
        pen.shape(panel, fill: Palette.paper)
        pen.line(from: CGPoint(x: 72, y: 34), to: CGPoint(x: 232, y: 34))
        for x in [86.0, 98, 110] {
            pen.shape(Path(ellipseIn: CGRect(x: x - 4, y: 19, width: 8, height: 8)), fill: Palette.stone, shadow: false)
        }
        // Two apps already in the list: one on, one off.
        let rows: [(y: CGFloat, icon: Color, on: Bool)] = [(46, Palette.cobalt, true), (78, Palette.bubblegum, false)]
        for row in rows {
            pen.shape(
                Path(roundedRect: CGRect(x: 86, y: row.y, width: 22, height: 22), cornerRadius: 6), fill: row.icon,
                shadow: false)
            pen.line(from: CGPoint(x: 118, y: row.y + 11), to: CGPoint(x: 172, y: row.y + 11))
            Self.toggle(&pen, x: 186, y: row.y + 3, on: row.on)
        }
        // The empty slot Dustpan goes into, with its switch to turn on.
        pen.dashed(Path(roundedRect: CGRect(x: 80, y: 114, width: 144, height: 34), cornerRadius: 8))
        Self.toggle(&pen, x: 186, y: 123, on: true)
        // Dustpan's tile, mid-drag, below and left of the panel.
        pen.rotated(by: -10, around: CGPoint(x: 32, y: 148)) { pen in
            pen.shape(
                Path(roundedRect: CGRect(x: 8, y: 124, width: 48, height: 48), cornerRadius: 12), fill: Palette.sun)
            var mark = Path()
            mark.move(to: CGPoint(x: 20, y: 144))
            mark.addQuadCurve(to: CGPoint(x: 44, y: 144), control: CGPoint(x: 32, y: 136))
            mark.addLine(to: CGPoint(x: 48, y: 160))
            mark.addLine(to: CGPoint(x: 16, y: 160))
            mark.closeSubpath()
            pen.shape(mark, fill: Palette.paper, shadow: false)
        }
        // A short drag arrow from the tile up into the slot.
        var arc = Path()
        arc.move(to: CGPoint(x: 30, y: 116))
        arc.addQuadCurve(to: CGPoint(x: 92, y: 124), control: CGPoint(x: 44, y: 84))
        pen.thickStroke(arc, color: Palette.tomato, width: 7)
        var head = Path()
        head.move(to: CGPoint(x: 84, y: 112))
        head.addLine(to: CGPoint(x: 106, y: 131))
        head.addLine(to: CGPoint(x: 80, y: 134))
        head.closeSubpath()
        pen.shape(head, fill: Palette.tomato)
    }

    /// A switch in the guide's list.
    private static func toggle(_ pen: inout InkPen, x: CGFloat, y: CGFloat, on: Bool) {
        pen.shape(
            Path(roundedRect: CGRect(x: x, y: y, width: 34, height: 16), cornerRadius: 8),
            fill: on ? Palette.mint : Palette.paper, shadow: false)
        let knob = on ? x + 26 : x + 8
        pen.shape(
            Path(ellipseIn: CGRect(x: knob - 6, y: y + 2, width: 12, height: 12)), fill: Palette.paper, shadow: false)
    }

    /// An open padlock with a check badge.
    private static func accessDone(_ pen: inout InkPen) {
        // Shackle, swung open (right leg lifted out of the body).
        var shackle = Path()
        shackle.move(to: CGPoint(x: 96, y: 92))
        shackle.addLine(to: CGPoint(x: 96, y: 58))
        shackle.addArc(
            center: CGPoint(x: 124, y: 58), radius: 28, startAngle: .degrees(180), endAngle: .degrees(0),
            clockwise: false)
        shackle.addLine(to: CGPoint(x: 152, y: 66))
        pen.thickStroke(shackle, color: Palette.stone, width: 10)
        // Body
        pen.shape(Path(roundedRect: CGRect(x: 72, y: 88, width: 104, height: 78), cornerRadius: 14), fill: Palette.sun)
        pen.circle(center: CGPoint(x: 124, y: 118), radius: 8, fill: Palette.ink)
        pen.line(from: CGPoint(x: 124, y: 124), to: CGPoint(x: 124, y: 142))
        // Check badge
        pen.circle(center: CGPoint(x: 182, y: 140), radius: 26, fill: Palette.mint)
        var check = Path()
        check.move(to: CGPoint(x: 169, y: 140))
        check.addLine(to: CGPoint(x: 179, y: 151))
        check.addLine(to: CGPoint(x: 197, y: 128))
        pen.thickStroke(check, color: Palette.paperFixed, width: 6)
        // A little sparkle
        pen.circle(center: CGPoint(x: 44, y: 52), radius: 7, fill: Palette.bubblegum)
        pen.circle(center: CGPoint(x: 200, y: 56), radius: 5, fill: Palette.cobalt)
        pen.circle(center: CGPoint(x: 40, y: 140), radius: 5, fill: Palette.tomato)
    }

    /// A page with a folded corner.
    private static func document(_ r: CGRect) -> Path {
        let fold = min(r.width, r.height) * 0.24
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        return p
    }
}

/// Draws in the house style: solid offset shadow, flat fill, ink outline.
struct InkPen {
    var context: GraphicsContext
    /// Applied to every path before drawing, so shadows always fall right and down
    /// even on rotated shapes.
    private var transform: CGAffineTransform = .identity

    init(context: GraphicsContext) {
        self.context = context
    }

    private var outline: StrokeStyle {
        StrokeStyle(lineWidth: Stroke.outline, lineCap: .round, lineJoin: .round)
    }

    mutating func shape(_ path: Path, fill: Color, shadow: Bool = true) {
        let path = path.applying(transform)
        if shadow { shadowRaw(path) }
        context.fill(path, with: .color(fill))
        context.stroke(path, with: .color(Palette.ink), style: outline)
    }

    mutating func circle(center: CGPoint, radius: CGFloat, fill: Color) {
        shape(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            fill: fill)
    }

    mutating func shadow(_ path: Path) {
        shadowRaw(path.applying(transform))
    }

    private func shadowRaw(_ path: Path) {
        context.fill(
            path.offsetBy(dx: Stroke.shadowOffset, dy: Stroke.shadowOffset), with: .color(Palette.ink))
    }

    mutating func stroke(_ path: Path) {
        context.stroke(path.applying(transform), with: .color(Palette.ink), style: outline)
    }

    mutating func line(from a: CGPoint, to b: CGPoint) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        stroke(p)
    }

    /// A fat coloured stroke wrapped in an ink outline.
    mutating func thickStroke(_ path: Path, color: Color, width: CGFloat = 12) {
        let outer = StrokeStyle(lineWidth: width + Stroke.outline * 2, lineCap: .round)
        let inner = StrokeStyle(lineWidth: width, lineCap: .round)
        let path = path.applying(transform)
        context.stroke(
            path.offsetBy(dx: Stroke.shadowOffset, dy: Stroke.shadowOffset), with: .color(Palette.ink), style: outer)
        context.stroke(path, with: .color(Palette.ink), style: outer)
        context.stroke(path, with: .color(color), style: inner)
    }

    /// A dashed ink outline (a drop target), no fill or shadow.
    mutating func dashed(_ path: Path) {
        context.stroke(
            path.applying(transform), with: .color(Palette.ink),
            style: StrokeStyle(lineWidth: Stroke.outline, lineCap: .round, dash: [6, 6]))
    }

    mutating func clipped(to path: Path, _ draw: (inout InkPen) -> Void) {
        let saved = context
        context.clip(to: path.applying(transform))
        draw(&self)
        context = saved
    }

    mutating func rotated(by degrees: Double, around point: CGPoint, _ draw: (inout InkPen) -> Void) {
        let saved = transform
        let radians = degrees * .pi / 180
        transform =
            CGAffineTransform(translationX: -point.x, y: -point.y)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
            .concatenating(saved)
        draw(&self)
        transform = saved
    }
}
