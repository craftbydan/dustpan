#!/usr/bin/env swift
// Draws the DMG window background — paper, a headline, and a chunky ink arrow from where
// Dustpan sits to where the Applications link sits — at 1x and 2x, into Scripts/dmg/.
// Colours come from DesignSystem/Colors.xcassets, the headline font is the bundled Archivo.
// Icon centres must match `make dmg` (Dustpan at x 170, Applications at x 490, y 220).
//
// Usage (from the repo root):  swift Scripts/make-dmg-background.swift

import AppKit
import CoreGraphics
import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let colorsDir = root.appendingPathComponent("DesignSystem/Colors.xcassets")
let outDir = root.appendingPathComponent("Scripts/dmg")

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
let tomato = token("tomato")
let sun = token("sun")

// Register Archivo and build the black and medium weights from the variable font.
let fontURL = root.appendingPathComponent("DesignSystem/Fonts/Archivo-Variable.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
func archivo(_ size: CGFloat, weight: CGFloat) -> CTFont {
    let wght = 0x7767_6874  // 'wght'
    let base = CTFontDescriptorCreateWithAttributes(
        [kCTFontNameAttribute: "Archivo"] as CFDictionary)
    let varied = CTFontDescriptorCreateCopyWithVariation(base, wght as CFNumber, weight)
    return CTFontCreateWithFontDescriptor(varied, size, nil)
}

let width: CGFloat = 660
let height: CGFloat = 400

/// Draws a line of text centred on `x`, with its baseline at `y` (y down).
func text(_ s: String, font: CTFont, color: CGColor, x: CGFloat, y: CGFloat, in ctx: CGContext) {
    let attr = NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: -0.4,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x - w / 2, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// The arrow: a slightly wobbly hand-made shaft with a fat head, ink outline, solid offset shadow.
func arrowPath() -> CGPath {
    let p = CGMutablePath()
    // Shaft (top edge), from left to the head.
    p.move(to: CGPoint(x: 262, y: 206))
    p.addCurve(to: CGPoint(x: 372, y: 200), control1: CGPoint(x: 300, y: 196), control2: CGPoint(x: 338, y: 206))
    // Head.
    p.addLine(to: CGPoint(x: 368, y: 180))
    p.addLine(to: CGPoint(x: 410, y: 214))
    p.addLine(to: CGPoint(x: 370, y: 250))
    p.addLine(to: CGPoint(x: 373, y: 228))
    // Shaft (bottom edge), back to the left.
    p.addCurve(to: CGPoint(x: 264, y: 234), control1: CGPoint(x: 338, y: 236), control2: CGPoint(x: 300, y: 226))
    p.closeSubpath()
    return p
}

func draw(in ctx: CGContext) {
    // Paper.
    ctx.setFillColor(paper)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Headline and one quiet line under it.
    text("Drag Dustpan into Applications", font: archivo(30, weight: 900), color: ink,
        x: width / 2, y: 74, in: ctx)
    text("Then open it from your Applications folder.", font: archivo(14, weight: 500),
        color: ink.copy(alpha: 0.6)!, x: width / 2, y: 102, in: ctx)

    // Soft sun "landing pads" under both icon spots, ink-outlined, so the eye reads left → right.
    for cx in [170.0, 490.0] {
        let pad = CGRect(x: cx - 84, y: 136, width: 168, height: 168)
        let shape = CGPath(roundedRect: pad, cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.addPath(shape)
        ctx.setFillColor(sun.copy(alpha: 0.18)!)
        ctx.fillPath()
        ctx.addPath(shape)
        ctx.setStrokeColor(ink.copy(alpha: 0.12)!)
        ctx.setLineWidth(2.5)
        ctx.setLineDash(phase: 0, lengths: [8, 7])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // Arrow with the solid 4-pt offset ink shadow used across Dustpan.
    let arrow = arrowPath()
    ctx.saveGState()
    ctx.translateBy(x: 4, y: 4)
    ctx.addPath(arrow)
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow)
    ctx.setFillColor(tomato)
    ctx.fillPath()
    ctx.addPath(arrow)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(2.5)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

func render(scale: CGFloat, to url: URL) {
    let w = Int(width * scale), h = Int(height * scale)
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("No context") }
    // Flip to y-down, then scale.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    draw(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: width, height: height)  // 72 dpi at 1x, 144 dpi at 2x
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
render(scale: 1, to: outDir.appendingPathComponent("background.png"))
render(scale: 2, to: outDir.appendingPathComponent("background@2x.png"))
print("Wrote Scripts/dmg/background.png and background@2x.png")
