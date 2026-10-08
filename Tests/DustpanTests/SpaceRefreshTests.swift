import Foundation
import Testing

@testable import Dustpan

/// Counts free-space reads and answers with a fixed figure (never the real disk).
final class FakeDiskReader: Sendable {
    private let reads = ReadCounter(0)
    let space = DiskSpace(availableBytes: 200_000_000_000, totalBytes: 500_000_000_000)

    var count: Int { reads.value }

    var reader: DiskSpaceModel.Reader {
        { [self] in
            reads.increment()
            return space
        }
    }
}

/// A tiny lock-protected counter.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int
    init(_ value: Int) { stored = value }
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

/// The disk bar and the Junk Trash tile follow every move to the Trash, put-back and Empty Trash
/// (bug fix 2026-10-07). Fixture home with its own `.Trash`; never the real home or Trash.
@Suite("Disk bar and Trash tile refresh")
@MainActor
struct SpaceRefreshTests {
    struct Harness {
        let fixture: FixtureHome
        let trash: URL
        let database: AppDatabase
        let disk = FakeDiskReader()

        init() throws {
            fixture = try FixtureHome()
            trash = fixture.path(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            database = try AppDatabase(
                directory: fixture.outside.deletingLastPathComponent().appendingPathComponent("db"))
        }

        @MainActor
        func appState(access: Bool = true) async -> AppState {
            let library = fixture.outside.deletingLastPathComponent().appendingPathComponent("Library")
            let state = AppState(
                database: database, permissions: FakePermissions(flag: AccessFlag(granted: access)),
                home: fixture.url, trashMover: TempTrashMover(trashDirectory: trash), runningApps: FakeRunningApps(),
                appRoots: [], systemLibrary: library, signing: FakeSigning(), lastUsed: FakeLastUsed(),
                diskReader: disk.reader)
            await state.onboarding.load(allowPresentation: false)
            return state
        }

        func remove() { fixture.remove() }
    }

    @Test("Clean grows the Trash tile by the moved bytes, Undo shrinks it, Empty Trash removes it")
    func junkCleanUndoEmpty() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 120_000)
        try h.fixture.file(".Trash/old-notes.zip", bytes: 5_000, ageDays: 3)
        let state = await h.appState()
        let junk = state.junk

        await junk.scan(hasFullDiskAccess: true)
        let before = try #require(junk.result(for: .trash)?.totalBytes)
        #expect(before > 0)
        #expect(state.spaceChanges == 0)
        let readsBefore = h.disk.count

        junk.requestClean()
        await junk.confirmClean()
        let report = try #require(junk.lastReport)
        #expect(report.freedBytes > 0)
        #expect(state.spaceChanges == 1)
        await state.spaceRefresh?.value
        #expect(junk.result(for: .trash)?.totalBytes == before + report.freedBytes)
        #expect(junk.showsTrashNote)
        #expect(junk.emptyTrashAction != nil)
        #expect(h.disk.count > readsBefore)
        #expect(state.disk.space == h.disk.space)

        await junk.undoLastClean()
        #expect(state.spaceChanges == 2)
        await state.spaceRefresh?.value
        #expect(junk.result(for: .trash)?.totalBytes == before)

        await junk.requestEmptyTrash()
        #expect(junk.trashToEmpty?.bytes == before)
        await junk.confirmEmptyTrash()
        #expect(state.spaceChanges == 3)
        await state.spaceRefresh?.value
        #expect(junk.result(for: .trash) == nil)
        #expect(!junk.showsTrashNote)
        // The cache that was put back is untouched by Empty Trash.
        #expect(FileManager.default.fileExists(atPath: h.fixture.path("Library/Caches/com.example.app/a.bin").path))
    }

    @Test("An empty Trash gets a tile once something is moved into it")
    func trashTileAppears() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 64_000)
        let state = await h.appState()
        await state.junk.scan(hasFullDiskAccess: true)
        #expect(state.junk.result(for: .trash) == nil)
        await state.junk.confirmClean()
        await state.spaceRefresh?.value
        let moved = try #require(state.junk.lastReport?.freedBytes)
        #expect(state.junk.result(for: .trash)?.totalBytes == moved)
    }

    @Test("Without Full Disk Access the Trash isn't measured: no made-up number")
    func noAccessNoTrashFigure() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 64_000)
        try h.fixture.file(".Trash/old.zip", bytes: 5_000)
        let state = await h.appState(access: false)
        await state.junk.scan(hasFullDiskAccess: false)
        #expect(state.junk.skippedCategories.contains(.trash))
        #expect(state.junk.result(for: .trash) == nil)
        await state.junk.confirmClean()
        #expect(state.spaceChanges == 1)
        await state.spaceRefresh?.value
        #expect(state.junk.result(for: .trash) == nil)
        #expect(state.junk.skippedCategories.contains(.trash))
        #expect(state.junk.emptyTrashAction == nil)
    }

    @Test("Every feature that moves or puts back files reaches the one signal")
    func everyFeatureWired() async throws {
        let h = try Harness()
        defer { h.remove() }
        let state = await h.appState()
        let hooks: [(SpaceChange) -> Void] = [
            state.junk.spaceChanged, state.sweep.spaceChanged, state.history.spaceChanged, state.apps.spaceChanged,
            state.spaceMap.spaceChanged, state.clutter.largeOld.spaceChanged, state.clutter.duplicates.spaceChanged,
        ]
        for (index, hook) in hooks.enumerated() {
            hook(.movedToTrash)
            #expect(state.spaceChanges == index + 1)
        }
        await state.spaceRefresh?.value
        #expect(state.disk.refreshCount >= 1)
    }

    @Test("The signal refreshes the shared disk model; Empty Trash reads again a moment later")
    func diskRefreshOnSignal() async throws {
        let h = try Harness()
        defer { h.remove() }
        let state = await h.appState()
        #expect(state.disk.space == nil)
        state.spaceChanged(.movedToTrash)
        await state.spaceRefresh?.value
        #expect(state.disk.space == h.disk.space)
        #expect(h.disk.count == 1)

        let model = DiskSpaceModel(read: h.disk.reader)
        model.refreshAgain(after: .milliseconds(10))
        model.refreshAgain(after: .milliseconds(10))  // a newer call replaces the pending one
        for _ in 0..<200 where model.refreshCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.refreshCount == 1)
    }

    @Test("The sidebar and the Sweep share AppState's one disk model (no second copy)")
    func oneDiskModel() throws {
        let made = CopyTests.sources().filter { file in
            guard file.lastPathComponent != "DiskSpaceModel.swift" else { return false }
            return (try? String(contentsOf: file, encoding: .utf8))?.contains("DiskSpaceModel(") == true
        }
        #expect(made.map(\.lastPathComponent) == ["AppState.swift"])
        let sweep = try String(
            contentsOf: CopyTests.repo.appendingPathComponent("Features/Sweep/SweepView.swift"), encoding: .utf8)
        #expect(sweep.contains("appState.disk"))
        let root = try String(contentsOf: CopyTests.repo.appendingPathComponent("App/RootView.swift"), encoding: .utf8)
        #expect(root.contains("disk: appState.disk"))
    }
}
