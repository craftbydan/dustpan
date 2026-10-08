#!/usr/bin/env swift
// Draws Dustpan's app icon — a tilted sun-yellow dustpan with a thick ink outline and
// three tomato dust dots, on paper — at every macOS size, into
// App/Assets.xcassets/AppIcon.appiconset. Colours are read from DesignSystem/Colors.xcassets.
//
// Usage (from the repo root):  swift Scripts/make-app-icon.swift

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let colorsDir = root.appendingPathComponent("DesignSystem/Colors.xcassets")
let outDir = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

/// Reads the light-appearance colour of a colour set.
func token(_ name: String) -> CGColor {
    let url = colorsDir.appendingPathComponent("\(name).colorset/Contents.json")
    guard let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let colors = json["colors"] as? [[String: Any]],
        let first = colors.first(where: { $0["appearances"] == nil }),
        let color = first["color"] as? [String: Any],
        let c = color["components"] as? [String: String]
    else { fatalError("Missing colour token \(name)") }
    func v(_ key: String) -> CGFloat {
        let s = c[key]!
        return s.hasPrefix("0x") ? CGFloat(Int(s.dropFirst(2), radix: 16)!) / 255 : CGFloat(Double(s)!)
    }
    return CGColor(srgbRed: v("red"), green: v("green"), blue: v("blue"), alpha: 1)
}

let paper = token("paper")
let ink = token("ink")
let sun = token("sun")
let tomato = token("tomato")

/// Draws the icon on a 1024-point canvas (y down).
func draw(in ctx: CGContext) {
    let outline: CGFloat = 30
    let shadow: CGFloat = 26

    func inked(_ path: CGPath, fill: CGColor, drawShadow: Bool = true, shadowOffset: CGFloat = shadow) {
        if drawShadow {
            ctx.saveGState()
            ctx.translateBy(x: shadowOffset, y: shadowOffset)
            ctx.addPath(path)
            ctx.setFillColor(ink)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(outline)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    // Paper plate: Apple's macOS grid — 824 pt body centred on the 1024 canvas.
    let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let plate = CGPath(roundedRect: plateRect.insetBy(dx: outline / 2, dy: outline / 2),
                       cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(plate)
    ctx.setFillColor(paper)
    ctx.fillPath()

    // Dustpan, tilted. Paths are rotated (not the context) so every shadow still falls
    // right and down.
    // Seen from the front and a little above: a wide flat scoop, a hooded back, a handle.
    let handle = CGPath(roundedRect: CGRect(x: 466, y: 190, width: 92, height: 230),
                        cornerWidth: 40, cornerHeight: 40, transform: nil)

    let pan = CGMutablePath()
    pan.move(to: CGPoint(x: 320, y: 430))
    pan.addQuadCurve(to: CGPoint(x: 704, y: 430), control: CGPoint(x: 512, y: 320))
    pan.addLine(to: CGPoint(x: 790, y: 690))
    pan.addLine(to: CGPoint(x: 234, y: 690))
    pan.closeSubpath()

    let seams = CGMutablePath()
    seams.move(to: CGPoint(x: 342, y: 494))
    seams.addQuadCurve(to: CGPoint(x: 682, y: 494), control: CGPoint(x: 512, y: 420))
    seams.move(to: CGPoint(x: 262, y: 636))
    seams.addLine(to: CGPoint(x: 762, y: 636))

    var t = CGAffineTransform(translationX: 512, y: 470)
        .rotated(by: -16 * .pi / 180)
        .scaledBy(x: 0.84, y: 0.84)
        .translatedBy(x: -512, y: -470)
        .translatedBy(x: 20, y: -10)
    inked(handle.copy(using: &t)!, fill: sun)
    inked(pan.copy(using: &t)!, fill: sun)
    ctx.addPath(seams.copy(using: &t)!)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(outline)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Three dust dots in front of the scoop.
    for (c, r) in [(CGPoint(x: 268, y: 784), CGFloat(54)), (CGPoint(x: 410, y: 806), 41), (CGPoint(x: 530, y: 800), 31)] {
        inked(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil),
              fill: tomato, shadowOffset: 16)
    }

    // Plate outline last so it frames everything.
    ctx.addPath(plate)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(outline)
    ctx.strokePath()
}

func render(pixels: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(pixels) / 1024
    // Flip to y-down, then scale the 1024 design.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)
    draw(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in sizes {
    let px = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(pixels: px).write(to: outDir.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outDir.path)")
