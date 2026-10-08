import AppKit
import Testing

@testable import Dustpan

@Suite("Design system")
struct DesignSystemTests {
    @Test("Archivo is bundled and resolves at the black and bold weights")
    func archivoResolves() throws {
        #expect(FontRegistry.isRegistered)
        let black = try #require(Typo.archivoNSFont(size: 64, weight: 900))
        #expect(black.familyName == "Archivo")
        let variation = try #require(CTFontCopyVariation(black as CTFont) as? [UInt32: Double])
        #expect(variation[FontRegistry.weightAxis] == 900)
        let bold = try #require(Typo.archivoNSFont(size: 28, weight: 700))
        #expect(bold.familyName == "Archivo")
    }

    @Test("Every colour token resolves in light and dark")
    func colourTokensResolve() throws {
        for name in [
            "paper", "ink", "tomato", "sun", "cobalt", "mint", "bubblegum", "stone", "secondaryText", "inkFixed",
            "paperFixed",
        ] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let color = try #require(NSColor(named: name), "missing colour \(name)")
                var resolved: NSColor?
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    resolved = color.usingColorSpace(.sRGB)
                }
                #expect(resolved != nil, "\(name) did not resolve for \(appearance.rawValue)")
            }
        }
    }

    @Test("Paper and ink swap between light and dark")
    func paperInkSwap() throws {
        func hex(_ name: String, _ appearance: NSAppearance.Name) -> String {
            var out = ""
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let c = NSColor(named: name)!.usingColorSpace(.sRGB)!
                out = String(
                    format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                    Int((c.greenComponent * 255).rounded()),
                    Int((c.blueComponent * 255).rounded()))
            }
            return out
        }
        #expect(hex("paper", .aqua) == "F6F1E7")
        #expect(hex("paper", .darkAqua) == "17140F")
        #expect(hex("ink", .aqua) == "141210")
        #expect(hex("ink", .darkAqua) == "F6F1E7")
        #expect(hex("tomato", .darkAqua) == "FF4B2B")
    }

    @Test("Disk summary reads like the footer")
    func diskSummary() {
        let space = DiskSpace(availableBytes: 214_000_000_000, totalBytes: 494_000_000_000)
        #expect(space.summary == "214 GB free of 494 GB")
        #expect(space.usedBytes == 280_000_000_000)
    }

    @Test("Seven sidebar sections, five tools then two housekeeping")
    func sections() {
        #expect(AppSection.allCases.count == 7)
        #expect(AppSection.tools + AppSection.housekeeping == AppSection.allCases)
    }
}
