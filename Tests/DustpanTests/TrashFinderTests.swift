import Foundation
import Testing

@testable import Dustpan

/// Empty Trash with entries only Finder can delete (bug fix 2026-10-07): apps installed for all
/// users that Finder trashed with the user's password are root-owned. Simulated in a temp Trash
/// with `chmod 555` (folder) and the `uchg` flag (file); both are undone before cleanup.
/// Never the real Trash.
@Suite("Empty Trash: entries only Finder can delete")
@MainActor
struct TrashFinderTests {
    /// A temp Trash with: a deletable file, a read-only app folder (needs Finder), a locked file,
    /// and a folder of the user's own holding a read-only folder deeper down.
    final class Fixture {
        let h: CleanerTests.Harness
        private var readOnly: [URL] = []
        private var locked: [URL] = []

        init() throws { h = try CleanerTests.Harness() }

        var trash: URL { h.trash }
        func url(_ name: String) -> URL { trash.appendingPathComponent(name) }

        @discardableResult
        func file(_ name: String, bytes: Int) throws -> URL {
            let url = url(name)
            try h.fixture.file("x", bytes: bytes, absolute: url)
            return url
        }

        func makeReadOnly(_ name: String) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url(name).path)
            readOnly.append(url(name))
        }

        func lock(_ name: String) throws {
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url(name).path)
            locked.append(url(name))
        }

        func populate() throws {
            try file("old.zip", bytes: 40_000)
            try file("Teams.app/Contents/MacOS/Teams", bytes: 300_000)
            try makeReadOnly("Teams.app/Contents/MacOS")
            try makeReadOnly("Teams.app/Contents")
            try makeReadOnly("Teams.app")
            try file("locked.pdf", bytes: 20_000)
            try lock("locked.pdf")
            try file("project/deep/ro/data.bin", bytes: 10_000)
            try makeReadOnly("project/deep/ro")
            try FileManager.default.createDirectory(at: url("empty-ro"), withIntermediateDirectories: true)
            try makeReadOnly("empty-ro")
        }

        /// Every file's path and bytes under `name` (to prove nothing changed).
        func snapshot(_ name: String) -> [String: Data] {
            let root = url(name)
            var result: [String: Data] = [:]
            if let data = FileManager.default.contents(atPath: root.path) { result[""] = data }
            let names = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
            for relative in names {
                let path = root.appendingPathComponent(relative).path
                result[relative] = FileManager.default.contents(atPath: path) ?? Data()
            }
            return result
        }

        func remove() {
            for url in locked { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
            for url in readOnly.reversed() {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            h.remove()
        }
    }

    @Test("Each top-level entry is classified: deletable, needs Finder, or locked")
    func classification() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.populate()
        let summary = try await f.h.cleaner([]).trashSummary()
        #expect(summary.names == ["empty-ro", "old.zip"])
        let reasons = Dictionary(uniqueKeysWithValues: summary.kept.map { ($0.name, $0.reason) })
        #expect(reasons == ["Teams.app": .needsFinder, "locked.pdf": .locked, "project": .needsFinder])
        #expect(summary.keptBytes >= 330_000)
        #expect(summary.bytes >= 40_000 && summary.bytes < summary.keptBytes)
        #expect(summary.hasDeletable)
    }

    @Test("Empty Trash deletes only deletable entries; the rest is untouched and reported")
    func onlyDeletableGo() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.populate()
        let teams = f.snapshot("Teams.app")
        let project = f.snapshot("project")
        let locked = f.snapshot("locked.pdf")
        let cleaner = f.h.cleaner([])
        let summary = try await cleaner.trashSummary()

        let report = try await cleaner.emptyTrash(summary)
        #expect(report.freedBytes == summary.bytes)
        #expect(Set(report.deleted) == ["old.zip", "empty-ro"])
        #expect(Set(report.left.map(\.name)) == ["Teams.app", "locked.pdf", "project"])
        #expect(report.leftBytes == summary.keptBytes)
        #expect(f.snapshot("Teams.app") == teams)
        #expect(f.snapshot("project") == project)  // not half-deleted
        #expect(f.snapshot("locked.pdf") == locked)
        #expect(!FileManager.default.fileExists(atPath: f.url("old.zip").path))
    }

    @Test("An entry that became undeletable after the confirmation opened is left whole")
    func recheckBeforeRemoval() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.file("bundle/a.bin", bytes: 5_000)
        try f.file("bundle/sub/b.bin", bytes: 5_000)
        try f.file("plain.bin", bytes: 5_000)
        let cleaner = f.h.cleaner([])
        let summary = try await cleaner.trashSummary()
        #expect(summary.names == ["bundle", "plain.bin"])
        try f.makeReadOnly("bundle/sub")
        let before = f.snapshot("bundle")

        let report = try await cleaner.emptyTrash(summary)
        #expect(report.deleted == ["plain.bin"])
        #expect(report.left.map(\.reason) == [.needsFinder])
        #expect(f.snapshot("bundle") == before)
    }

    @Test("Mixed Trash through the Junk model: calm note, Finder link, and the space signal")
    func modelMixed() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.populate()
        let model = JunkModel(catalog: RuleCatalog(), cleaner: f.h.cleaner([]), store: f.h.store, home: f.h.fixture.url)
        var changes: [SpaceChange] = []
        model.spaceChanged = { changes.append($0) }
        var opened = 0
        model.openTrashInFinder = { opened += 1 }

        await model.requestEmptyTrash()
        let shown = try #require(model.trashToEmpty)
        #expect(shown.hasDeletable && !shown.kept.isEmpty)
        #expect(TrashCopy.keptLine(shown.kept, more: true).contains("only Finder can delete that"))
        await model.confirmEmptyTrash()
        #expect(changes == [.emptiedTrash])
        let left = try #require(model.trashLeft)
        #expect(left.leftBytes == shown.keptBytes)
        #expect(model.issue == nil)  // not an error any more
        #expect(TrashCopy.leftLine(left).hasPrefix("Deleted "))
        #expect(TrashCopy.leftLine(left).contains("is still in the Trash — macOS only lets Finder delete it."))
        model.showTrashInFinder()
        #expect(opened == 1)
        model.dismissEmptiedNote()
        #expect(model.trashLeft == nil)
    }

    @Test("Nothing deletable: no delete is offered or possible, only Finder")
    func nothingDeletable() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.file("Teams.app/Contents/x", bytes: 50_000)
        try f.makeReadOnly("Teams.app")
        try f.file("locked.pdf", bytes: 5_000)
        try f.lock("locked.pdf")
        let before = (f.snapshot("Teams.app"), f.snapshot("locked.pdf"))
        let model = JunkModel(catalog: RuleCatalog(), cleaner: f.h.cleaner([]), store: f.h.store, home: f.h.fixture.url)
        var changes: [SpaceChange] = []
        model.spaceChanged = { changes.append($0) }
        var opened = 0
        model.openTrashInFinder = { opened += 1 }

        await model.requestEmptyTrash()
        let shown = try #require(model.trashToEmpty)
        #expect(!shown.hasDeletable)
        #expect(shown.names.isEmpty && shown.bytes == 0)
        #expect(TrashCopy.keptLine(shown.kept, more: false).hasPrefix("Everything in it"))
        await model.confirmEmptyTrash()  // even a forged confirm deletes nothing
        #expect(changes.isEmpty)
        #expect(f.snapshot("Teams.app") == before.0)
        #expect(f.snapshot("locked.pdf") == before.1)

        await model.requestEmptyTrash()
        model.showTrashInFinder()
        #expect(opened == 1)
        #expect(model.trashToEmpty == nil)
    }

    @Test("The Junk Trash tile knows how much only Finder can delete")
    func tileKeptBytes() async throws {
        let h = try SpaceRefreshTests.Harness()
        let teams = h.trash.appendingPathComponent("Teams.app")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: teams.path)
            h.remove()
        }
        try h.fixture.file(".Trash/old.zip", bytes: 10_000)
        try h.fixture.file(".Trash/Teams.app/Contents/x", bytes: 200_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: teams.path)
        let state = await h.appState()
        await state.junk.scan(hasFullDiskAccess: true)
        #expect(state.junk.result(for: .trash) != nil)
        #expect(state.junk.trashKeptBytes >= 200_000)
    }
}
