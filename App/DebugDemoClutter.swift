#if DEBUG
    import AppKit
    import CoreGraphics
    import Darwin
    import Foundation

    /// DEBUG only. Made-up big files and duplicate photos/documents for the Clutter screenshots
    /// (`-junkDemo YES -snapshotClutter YES`). Everything lives in the demo's temp home.
    enum DemoClutter {
        static func add(home: URL) throws {
            let mb: Int64 = 1_048_576
            // Big files: space is reserved (F_PREALLOCATE), not written, so this is quick.
            let big: [(String, Int64, Double)] = [
                ("Movies/Holiday 2024/raw-footage.mov", 980 * mb, 430),
                ("Downloads/ubuntu-24.04-desktop-arm64.iso", 720 * mb, 260),
                ("Documents/Old projects/site-backup-2023.zip", 540 * mb, 610),
                ("Music/Sessions/live-take-03.wav", 380 * mb, 330),
                ("Downloads/Install Synthwave Pro.dmg", 260 * mb, 200),
                ("Pictures/Edits/poster-layers.psd", 170 * mb, 500),
                ("Documents/Manuals/camera-manual-scans.pdf", 130 * mb, 720),
                (".models/llama-small.gguf", 112 * mb, 240),
                // Opened lately: filtered out at 6 months.
                ("Projects/film-edit/renders/final.mov", 610 * mb, 9),
            ]
            for (relative, bytes, ageDays) in big {
                try reserve(home.appendingPathComponent(relative), bytes: bytes, ageDays: ageDays)
            }

            // Duplicates: real images and a PDF, so Quick Look thumbnails have something to show.
            let palette: [(CGFloat, CGFloat, CGFloat)] = [
                (1.0, 0.29, 0.17), (1.0, 0.76, 0.10), (0.15, 0.28, 1.0), (0.12, 0.81, 0.56), (1.0, 0.48, 0.78),
            ]
            let beach = try image(seed: 1, colors: [palette[1], palette[2], palette[3]])
            let dunes = try image(seed: 2, colors: [palette[0], palette[1], palette[4]])
            let lease = try pdf(image: try image(seed: 3, colors: [palette[2], palette[4]]))
            let archive = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) })
            let copies: [(Data, [(String, Double)])] = [
                (
                    beach,
                    [
                        ("Pictures/Trip 2025/IMG_2041.png", 120), ("Downloads/IMG_2041.png", 60),
                        ("Desktop/IMG_2041 copy.png", 14),
                    ]
                ),
                (dunes, [("Pictures/Wallpapers/dunes.png", 300), ("Downloads/dunes.png", 45)]),
                (
                    lease,
                    [
                        ("Documents/Home/lease-2025.pdf", 200), ("Downloads/lease-2025.pdf", 210),
                        ("Downloads/lease-2025 (1).pdf", 190),
                    ]
                ),
                (archive, [("Documents/Backups/notes-export.zip", 90), ("Desktop/notes-export.zip", 30)]),
            ]
            for (data, places) in copies {
                for (relative, ageDays) in places {
                    let url = home.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                    let date = Date().addingTimeInterval(-ageDays * 86_400)
                    try FileManager.default.setAttributes(
                        [.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
                }
            }
        }

        /// Sweep screenshots: one file over 1 GB untouched for a year, so the Large & old tile has
        /// something to count (space reserved, not written; removed with the demo folder).
        static func addSweepExtras(home: URL) throws {
            try reserve(
                home.appendingPathComponent("Movies/Old exports/wedding-4k-master.mov"), bytes: 1_400 * 1_048_576,
                ageDays: 540)
        }

        /// A file of `bytes` with its space allocated but not written.
        private static func reserve(_ url: URL, bytes: Int64, ageDays: Double) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            var store = fstore_t(
                fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE, fst_offset: 0, fst_length: off_t(bytes),
                fst_bytesalloc: 0)
            _ = fcntl(fd, F_PREALLOCATE, &store)
            guard ftruncate(fd, off_t(bytes)) == 0 else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: url.path)
        }

        /// A bold, flat poster: big circles on paper, with fine grain so the PNG is a few hundred KB.
        private static func image(seed: Int, colors: [(CGFloat, CGFloat, CGFloat)]) throws -> Data {
            let width = 960
            let height = 640
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(CGColor(red: 0.96, green: 0.945, blue: 0.906, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (index, color) in colors.enumerated() {
                let size = CGFloat(260 + 90 * ((index + seed) % 3))
                let x = CGFloat((index * 290 + seed * 70) % (width - 200))
                let y = CGFloat((index * 170 + seed * 110) % (height - 160))
                let rect = CGRect(x: x, y: y, width: size, height: size)
                context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
                context.fillEllipse(in: rect)
                context.setStrokeColor(CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1))
                context.setLineWidth(10)
                context.strokeEllipse(in: rect.insetBy(dx: 5, dy: 5))
            }
            // Grain.
            var state = UInt32(truncatingIfNeeded: seed &* 7_919 &+ 1)
            for _ in 0..<60_000 {
                state = state &* 1_664_525 &+ 1_013_904_223
                let x = Int(state % UInt32(width))
                let y = Int((state >> 12) % UInt32(height))
                context.setFillColor(CGColor(gray: CGFloat(state % 255) / 255, alpha: 0.18))
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
            guard let cgImage = context.makeImage(),
                let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            return png
        }

        /// A two-page PDF with the image on its first page.
        private static func pdf(image png: Data) throws -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                let context = CGContext(consumer: consumer, mediaBox: &box, nil),
                let image = NSBitmapImageRep(data: png)?.cgImage
            else { throw CocoaError(.fileWriteUnknown) }
            for page in 0..<2 {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(red: 0.96, green: 0.945, blue: 0.906, alpha: 1))
                context.fill(box)
                if page == 0 { context.draw(image, in: CGRect(x: 56, y: 360, width: 500, height: 333)) }
                context.setFillColor(CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1))
                for line in 0..<14 {
                    context.fill(CGRect(x: 56, y: 320 - line * 20, width: 500 - (line % 3) * 60, height: 6))
                }
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }
    }
#endif
