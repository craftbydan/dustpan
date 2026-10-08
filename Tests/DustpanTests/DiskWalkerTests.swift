import Darwin
import Foundation
import Testing

@testable import Dustpan

/// DiskWalker and SizeTree, always on fixture trees in a temp folder (never the real home).
@Suite("Disk walker")
struct DiskWalkerTests {
    static func walker(_ fixture: FixtureHome, access: Bool = true) -> DiskWalker {
        DiskWalker(home: fixture.url, protectedList: ProtectedList(home: fixture.url), hasFullDiskAccess: { access })
    }

    @Test("Sizes match the allocated sizes written and du -sk")
    func totalsMatch() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        var expected: Int64 = 0
        expected += try fixture.file("Projects/a/one.bin", bytes: 10_000)
        expected += try fixture.file("Projects/a/two.txt", bytes: 300)
        expected += try fixture.file("Projects/b/c/three.mov", bytes: 70_000)
        expected += try fixture.file("loose.pdf", bytes: 5_000)
        let tree = try await Self.walker(fixture).walk(fixture.url)

        #expect(tree.totalSize >= expected)
        // Folders on APFS take (almost) no blocks of their own.
        #expect(Double(tree.totalSize - expected) <= Double(expected) * 0.02)
        let du = try Self.duKilobytes(fixture.url)
        #expect(abs(Double(tree.totalSize) / 1024 - Double(du)) <= Double(du) * 0.02)
        #expect(tree.fileCount == 4)

        let projects = try #require(tree.index(ofPath: fixture.path("Projects").path))
        #expect(tree.kind(projects) == .directory)
        #expect(tree.name(projects) == "Projects")
        let mov = try #require(tree.index(ofPath: fixture.path("Projects/b/c/three.mov").path))
        #expect(tree.fileKind(mov) == .media)
        #expect(tree.path(mov) == fixture.path("Projects/b/c/three.mov").path)
        // The folder takes the kind of its biggest child.
        #expect(tree.fileKind(projects) == .media)
    }

    @Test("Hard links are counted once; symbolic links are never followed")
    func linksAndHardLinks() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        let size = try fixture.file("data/original.bin", bytes: 200_000)
        #expect(link(fixture.path("data/original.bin").path, fixture.path("data/hardlink.bin").path) == 0)
        try fixture.file("big.bin", bytes: 500_000, absolute: fixture.outside.appendingPathComponent("big.bin"))
        try fixture.symlink("data/outside-link", to: fixture.outside)

        let tree = try await Self.walker(fixture).walk(fixture.url)
        let data = try #require(tree.index(ofPath: fixture.path("data").path))
        #expect(tree.size(data) >= size)
        #expect(tree.size(data) < size + 100_000)
        let linkNode = try #require(tree.index(ofPath: fixture.path("data/outside-link").path))
        #expect(tree.kind(linkNode) == .link)
        #expect(tree.children(of: linkNode).isEmpty)
    }

    @Test("Protected places are measured as one node; guarded folders are skipped without access")
    func protectedAndGuarded() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        let mail = try fixture.file("Library/Mail/V10/box/1.emlx", bytes: 40_000)
        try fixture.file("Documents/report.pdf", bytes: 30_000)
        try fixture.file("Pictures/Holiday.photoslibrary/originals/a.heic", bytes: 20_000)

        let full = try await Self.walker(fixture, access: true).walk(fixture.url)
        let mailNode = try #require(full.index(ofPath: fixture.path("Library/Mail").path))
        #expect(full.kind(mailNode) == .protected)
        #expect(full.size(mailNode) >= mail)
        #expect(full.children(of: mailNode).isEmpty)
        let library = try #require(full.index(ofPath: fixture.path("Pictures/Holiday.photoslibrary").path))
        #expect(full.kind(library) == .protected)
        let documents = try #require(full.index(ofPath: fixture.path("Documents").path))
        #expect(full.kind(documents) == .directory)

        let limited = try await Self.walker(fixture, access: false).walk(fixture.url)
        for relative in ["Library/Mail", "Documents", "Pictures"] {
            let node = try #require(limited.index(ofPath: fixture.path(relative).path))
            #expect(limited.kind(node) == .needsAccess, "\(relative)")
            #expect(limited.size(node) == 0)
            #expect(limited.children(of: node).isEmpty)
        }
        #expect(limited.nodes(ofKind: .needsAccess).count == 3)
    }

    @Test("Without access, ~/Library is opened only for allow-listed folders and never com.apple.*")
    func libraryWithoutAccess() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 10_000)
        try fixture.file("Library/Caches/com.apple.Music/blob", bytes: 10_000)
        try fixture.file("Library/Developer/Xcode/DerivedData/a.o", bytes: 10_000)
        try fixture.file("Library/MediaThing/data", bytes: 10_000)
        let limited = try await Self.walker(fixture, access: false).walk(fixture.url)
        func kind(_ relative: String) -> SizeTree.Kind? {
            limited.index(ofPath: fixture.path(relative).path).map { limited.kind($0) }
        }
        #expect(kind("Library/Caches/com.vendor.app") == .directory)
        #expect(kind("Library/Caches/com.apple.Music") == .needsAccess)
        #expect(kind("Library/Developer") == .directory)
        #expect(kind("Library/MediaThing") == .needsAccess)
        #expect(kind("Library/MediaThing/data") == nil)
        let full = try await Self.walker(fixture, access: true).walk(fixture.url)
        #expect(full.index(ofPath: fixture.path("Library/MediaThing/data").path) != nil)
        #expect(
            full.index(ofPath: fixture.path("Library/Caches/com.apple.Music").path).map { full.kind($0) } == .directory)
        // A guarded folder picked as the root is not opened either.
        let rootTree = try await Self.walker(fixture, access: false).walk(fixture.path("Documents"))
        #expect(rootTree.kind(SizeTree.root) == .needsAccess)
        #expect(rootTree.count == 1)
    }

    @Test("Walking / skips the firmlinked Data volume and /Volumes")
    func rootSkips() {
        let context = WalkContext(
            rootPath: "/", home: "/Users/nobody", protectedList: ProtectedList(), hasFullDiskAccess: false)
        #expect(context.isSkipped("/System/Volumes/Data"))
        #expect(context.isSkipped("/Volumes"))
        #expect(context.watchParents.contains("/"))
        #expect(context.isGuarded("/Users/nobody/Desktop/x"))
        #expect(!context.isGuarded("/Users/nobody/Projects"))
        #expect(context.isProtected("/System/Library"))
    }

    @Test("A cancelled walk throws")
    func cancellation() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try Self.makeTree(at: fixture.path("many"), folders: 40, filesPerFolder: 200)
        let walker = Self.walker(fixture)
        let task = Task { try await walker.walk(fixture.url) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Re-walking one folder updates the tree and its ancestors")
    func graft() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try fixture.file("a/b/keep.bin", bytes: 50_000)
        let gone = try fixture.file("a/b/gone.bin", bytes: 400_000)
        let walker = Self.walker(fixture)
        var tree = try await walker.walk(fixture.url)
        let before = tree.totalSize
        let filesBefore = tree.fileCount
        try FileManager.default.removeItem(at: fixture.path("a/b/gone.bin"))
        let folder = try #require(tree.index(ofPath: fixture.path("a/b").path))
        let fresh = try await walker.walk(fixture.path("a/b"))
        tree.graft(fresh, at: folder)
        #expect(tree.totalSize == before - gone)
        #expect(tree.fileCount == filesBefore - 1)
        #expect(tree.index(ofPath: fixture.path("a/b/gone.bin").path) == nil)
        #expect(tree.index(ofPath: fixture.path("a/b/keep.bin").path) != nil)
        let a = try #require(tree.index(ofPath: fixture.path("a").path))
        #expect(tree.size(a) == tree.size(folder))
    }

    @Test("Top children come from a bounded heap, biggest first")
    func topChildren() {
        var tree = SizeTree(rootPath: "/x")
        for i in 0..<500 {
            tree.append(
                name: Array("f\(i)".utf8), parent: SizeTree.root, kind: .file, size: Int64(i * 10), fileKind: nil)
        }
        tree.finalize()
        let top = tree.topChildren(of: SizeTree.root, limit: 50)
        #expect(top.count == 50)
        #expect(top.map { tree.size($0) } == (450..<500).reversed().map { Int64($0 * 10) })
        #expect(tree.totalSize == Int64((0..<500).reduce(0, +) * 10))
    }

    @Test("A 1M-node SizeTree stays far under 400 MB")
    func memoryBudget() {
        let before = Self.physFootprint()
        var tree = SizeTree(rootPath: "/Users/someone", capacity: 1_000_000)
        var folder = SizeTree.root
        for i in 1..<1_000_000 {
            if i % 50 == 1 {
                folder = tree.append(
                    name: Array("folder-\(i)".utf8), parent: SizeTree.root, kind: .directory, size: 0, fileKind: nil)
            } else {
                tree.append(
                    name: Array("file-number-\(i).dat".utf8), parent: folder, kind: .file, size: 4096, fileKind: .other)
            }
        }
        tree.finalize()
        let after = Self.physFootprint()
        let estimate = tree.estimatedBytes
        print(
            "SizeTree 1M nodes: estimate \(estimate / 1_048_576) MB, phys_footprint +\((after - before) / 1_048_576) MB"
        )
        #expect(tree.count == 1_000_000)
        #expect(estimate < 400 * 1_048_576)
        #expect(estimate < 100 * 1_048_576)
        #expect(after - before < 400 * 1_048_576)
    }

    /// 200k files: DiskWalker must be at least 3× faster than a FileManager.enumerator walk over
    /// the same tree (both warm). Runs in `make test`; set TEST_RUNNER_DUSTPAN_SKIP_BENCHMARK=1 (xcodebuild passes it to the test host) to skip.
    @Test(
        "Benchmark: ≥ 3× faster than FileManager.enumerator on 200k files",
        .enabled(if: ProcessInfo.processInfo.environment["DUSTPAN_SKIP_BENCHMARK"] == nil))
    func benchmark() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        let root = fixture.path("bench")
        let created = Date()
        try Self.makeTree(at: root, folders: 400, filesPerFolder: 500)
        let createSeconds = Date().timeIntervalSince(created)
        let walker = Self.walker(fixture)
        _ = try await walker.walk(root)  // warm the metadata cache

        let baselineStart = Date()
        let baseline = Self.enumeratorTotal(root)
        let baselineSeconds = Date().timeIntervalSince(baselineStart)

        var best = Double.infinity
        var tree = SizeTree(rootPath: root.path)
        for _ in 0..<3 {
            let start = Date()
            tree = try await walker.walk(root)
            best = min(best, Date().timeIntervalSince(start))
        }
        let speedup = baselineSeconds / best
        print(
            String(
                format: "Benchmark 200k files: created in %.2f s; enumerator %.3f s; DiskWalker %.3f s; speedup %.1f×",
                createSeconds, baselineSeconds, best, speedup))
        #expect(tree.fileCount == 200_000)
        #expect(tree.totalSize == baseline)
        let du = try Self.duKilobytes(root)
        #expect(abs(Double(tree.totalSize) / 1024 - Double(du)) <= Double(du) * 0.02)
        #expect(speedup >= 3)
    }

    // MARK: - Helpers

    /// `folders` folders (in groups of 20) of `filesPerFolder` small files each, written in parallel.
    static func makeTree(at root: URL, folders: Int, filesPerFolder: Int) throws {
        let base = root.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = [UInt8](repeating: 0x5A, count: 6_000)
        let failures = OSAllocatedUnfairLockCounter()
        DispatchQueue.concurrentPerform(iterations: folders) { folder in
            let dir = "\(base)/group\(folder / 20)/folder\(folder)"
            if mkdir("\(base)/group\(folder / 20)", 0o755) != 0 && errno != EEXIST { failures.add() }
            if mkdir(dir, 0o755) != 0 && errno != EEXIST { failures.add() }
            for file in 0..<filesPerFolder {
                let fd = open("\(dir)/file\(file).dat", O_CREAT | O_WRONLY | O_TRUNC, 0o644)
                guard fd >= 0 else {
                    failures.add()
                    continue
                }
                let length = file % 7 == 0 ? 6_000 : 100
                _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, length) }
                close(fd)
            }
        }
        if failures.value > 0 { throw CocoaError(.fileWriteUnknown) }
    }

    /// The baseline: FileManager's enumerator, summing allocated sizes of regular files.
    static func enumeratorTotal(_ root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func duKilobytes(_ url: URL) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return Int64(text.split(separator: "\t").first.map(String.init) ?? "") ?? -1
    }

    /// This process's physical footprint (what Activity Monitor calls Memory).
    static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

/// A thread-safe counter for the fixture writer.
final class OSAllocatedUnfairLockCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
