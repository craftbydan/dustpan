import Foundation

@testable import Dustpan

/// A fake home folder built in a temp directory at test time. Tests never touch the real home.
struct FixtureHome {
    /// Canonical path of the fake home (symlinks such as /var → /private/var resolved).
    let url: URL
    let now: Date
    private let container: URL

    init(now: Date = Date()) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DustpanFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        container = URL(fileURLWithPath: PathTools.canonical(base.path) ?? base.path, isDirectory: true)
        url = container.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.now = now
    }

    /// A folder outside the fake home (for symlink tests).
    var outside: URL { container.appendingPathComponent("outside", isDirectory: true) }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    /// Writes `bytes` bytes at `relative` (inside home, or absolute with `absolute`), dated
    /// `ageDays` before `now`, and returns its allocated size as the file system reports it.
    @discardableResult
    func file(_ relative: String, bytes: Int, ageDays: Double = 30, absolute: URL? = nil) throws -> Int64 {
        let target = absolute ?? path(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: target.path)
        let values = try target.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? 0)
    }

    func symlink(_ relative: String, to destination: URL) throws {
        let link = path(relative)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
