import Foundation
import Testing

@testable import Dustpan

/// Space map model on a fixture home: walk, drill, breadcrumb, Move to Trash with refresh, undo.
@MainActor
@Suite("Space map model")
struct SpaceMapModelTests {
    @Test("Drill, go back, move to Trash (re-walking only that folder) and undo")
    func flow() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        let container = fixture.outside.deletingLastPathComponent()
        let trash = container.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let store = CleanupStore(database: try AppDatabase(directory: container.appendingPathComponent("db")))
        let cleaner = Cleaner(
            home: fixture.url, trashMover: TempTrashMover(trashDirectory: trash), store: store,
            protectedList: ProtectedList(home: fixture.url), rules: { [] }, now: { fixture.now },
            hasFullDiskAccess: { true }, ownPaths: [])
        let walker = DiskWalker(home: fixture.url, hasFullDiskAccess: { true })
        let model = SpaceMapModel(walker: walker, cleaner: cleaner, store: store, home: fixture.url)

        try fixture.file("Projects/site/node_modules/react/index.js", bytes: 120_000)
        let build = try fixture.file("Projects/site/build/out.zip", bytes: 300_000)
        try fixture.file("Projects/film/cut.mov", bytes: 500_000)
        for i in 0..<300 { try fixture.file("Many/f\(i).txt", bytes: 100) }

        model.start(.home)
        await model.waitForWalk()
        #expect(model.hasMap)
        #expect(!model.isWalking)
        let total = model.currentSize
        #expect(model.entries.contains { $0.name == "Projects" })

        model.debugDrill(["Many"])
        #expect(model.entries.count == SpaceMapModel.maxBlocks + 1)
        #expect(model.entries.last?.node == nil)
        #expect(model.topItems.count == SpaceMapModel.topCount)
        model.go(to: SizeTree.root)

        model.debugDrill(["Projects", "site"])
        #expect(model.breadcrumb.count == 3)
        let target = try #require(model.topItems.first { model.name($0) == "build" })
        await model.requestTrash(target)
        #expect(model.pendingTrash?.allowed == [target])
        await model.confirmTrash()
        #expect(model.issue == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("Projects/site/build").path))
        #expect(model.lastMove?.name == "build")
        #expect(model.breadcrumb.count == 3)
        #expect(!model.topItems.contains { model.name($0) == "build" })
        let root = SizeTree.root
        #expect(model.size(root) <= total - build)

        await model.undoLastMove()
        #expect(FileManager.default.fileExists(atPath: fixture.path("Projects/site/build/out.zip").path))
        #expect(model.topItems.contains { model.name($0) == "build" })
        #expect(model.size(root) == total)
    }

    @Test("The home folder's standard folders can't even be offered for the Trash")
    func refusalSurfaces() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try fixture.file("Documents/a.pdf", bytes: 1_000)
        let container = fixture.outside.deletingLastPathComponent()
        let store = CleanupStore(database: nil)
        let cleaner = Cleaner(
            home: fixture.url, trashMover: TempTrashMover(trashDirectory: container), store: store,
            protectedList: ProtectedList(home: fixture.url), rules: { [] }, hasFullDiskAccess: { true }, ownPaths: [])
        let model = SpaceMapModel(
            walker: DiskWalker(home: fixture.url, hasFullDiskAccess: { true }), cleaner: cleaner, store: store,
            home: fixture.url)
        model.start(.home)
        await model.waitForWalk()
        let documents = try #require(model.topItems.first { model.name($0) == "Documents" })
        #expect(model.canTrash(documents))  // offered; the Cleaner decides
        await model.requestTrash(documents)
        #expect(model.pendingTrash?.allowed.isEmpty == true)
        #expect(model.pendingTrash?.refused.map(\.reason) == [.homeFolder])
        await model.confirmTrash()
        #expect(model.lastMove == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.path("Documents/a.pdf").path))
    }

    // MARK: - Selection and delete (Space map delete)

    struct Harness {
        let fixture: FixtureHome
        let trash: URL
        let store: CleanupStore
        let model: SpaceMapModel

        @MainActor
        init(running: [String: String] = [:]) async throws {
            fixture = try FixtureHome()
            let container = fixture.outside.deletingLastPathComponent()
            trash = container.appendingPathComponent("trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            store = CleanupStore(database: try AppDatabase(directory: container.appendingPathComponent("db")))
            let never = Rule(
                id: "test.never", title: "Models", category: .ai, paths: ["~/Work/models"], risk: .never,
                why: "Downloaded models.")
            let fake = FakeRunningApps(running: running)
            let fixture = fixture
            let cleaner = Cleaner(
                home: fixture.url, trashMover: TempTrashMover(trashDirectory: trash), runningApps: fake, store: store,
                protectedList: ProtectedList(home: fixture.url), rules: { [never] }, now: { fixture.now },
                hasFullDiskAccess: { true }, ownPaths: [])
            model = SpaceMapModel(
                walker: DiskWalker(home: fixture.url, hasFullDiskAccess: { true }), cleaner: cleaner, store: store,
                home: fixture.url,
                runningApps: RunningApps(checker: fake, quitter: FakeQuitter(succeeds: true), observeWorkspace: false))
            try fixture.file("Work/old-render.mov", bytes: 400_000)
            try fixture.file("Work/build/out.zip", bytes: 200_000)
            try fixture.file("Work/notes.txt", bytes: 5_000)
            try fixture.file("Work/app-data/store.sqlite", bytes: 50_000)
            try fixture.file("Work/models/llm.bin", bytes: 100_000)
            try fixture.file("Documents/a.pdf", bytes: 30_000)
            model.start(.home)
            await model.waitForWalk()
        }

        @MainActor func child(_ name: String) throws -> UInt32 {
            try #require(
                model.tree.flatMap { tree in tree.children(of: model.current).first { tree.name($0) == name } })
        }

        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: fixture.path(relative).path) }
    }

    @Test("Click selects; ⌘-click toggles; double-click (drill) opens a folder and clears the selection; Esc clears")
    func selection() async throws {
        let h = try await Harness()
        defer { h.fixture.remove() }
        let model = h.model
        let work = try h.child("Work")
        let documents = try h.child("Documents")
        model.click(work)
        #expect(model.selection == [work])
        #expect(model.focused == work)
        model.click(documents)
        #expect(model.selection == [documents])
        model.click(work, toggle: true)
        #expect(model.selection == [documents, work])
        model.click(documents, toggle: true)
        #expect(model.selection == [work])
        #expect(model.selectedBytes == model.size(work))
        model.setSelected(documents, true)
        #expect(model.selection.count == 2)
        model.clearSelection()
        #expect(model.selection.isEmpty)

        model.click(documents)
        model.drill(into: work)
        #expect(model.title(of: model.current) == "Work")
        #expect(model.selection.isEmpty)
        // Items outside the current folder can't be selected.
        model.click(documents)
        #expect(model.selection.isEmpty)
        let render = try h.child("old-render.mov")
        model.drill(into: render)  // a file: double-click selects it
        #expect(model.selection == [render])
        #expect(model.goUp())
        #expect(model.current == SizeTree.root)
        #expect(model.selection.isEmpty)
        #expect(!model.goUp())
    }

    @Test("The first selection marks the hint as seen")
    func hint() async throws {
        let h = try await Harness()
        defer { h.fixture.remove() }
        #expect(!h.model.hintSeen)
        h.model.click(try h.child("Work"))
        #expect(h.model.hintSeen)
    }

    @Test("⌘⌫ / the bar pre-checks the selection: refused items get reasons and are left out; only allowed ones move")
    func precheckAndConfirm() async throws {
        let h = try await Harness()
        defer { h.fixture.remove() }
        let model = h.model
        model.drill(into: try h.child("Work"))
        let render = try h.child("old-render.mov")
        let build = try h.child("build")
        let appData = try h.child("app-data")
        let models = try h.child("models")
        for index in [render, build, appData, models] { model.setSelected(index, true) }
        await model.requestTrashSelection()
        let pending = try #require(model.pendingTrash)
        #expect(Set(pending.allowed) == [render, build])
        #expect(pending.allowedBytes == model.size(render) + model.size(build))
        let reasons = Dictionary(uniqueKeysWithValues: pending.refused.map { ($0.index, $0.reason) })
        #expect(reasons[appData] == .protected)  // a folder holding an app database
        #expect(reasons[models] == .neverTouched)
        // Nothing moved by the pre-check.
        #expect(h.exists("Work/build/out.zip"))

        await model.confirmTrash()
        #expect(model.pendingTrash == nil)
        #expect(!h.exists("Work/old-render.mov"))
        #expect(!h.exists("Work/build"))
        #expect(h.exists("Work/app-data/store.sqlite"))
        #expect(h.exists("Work/models/llm.bin"))
        #expect(model.selection.isEmpty)
        #expect(model.lastMove?.name == "2 items")
        #expect(model.issue == nil)
        #expect(!model.topItems.contains { model.name($0) == "build" })
        let logs = try await h.store.logs()
        #expect(logs.count == 2)
        #expect(logs.allSatisfy { $0.ruleID == Cleaner.userChosenRuleID })

        await model.undoLastMove()
        #expect(h.exists("Work/old-render.mov"))
        #expect(h.exists("Work/build/out.zip"))
        #expect(model.topItems.contains { model.name($0) == "build" })
    }

    @Test("Home's standard folders and a selection with nothing allowed get no destructive step")
    func allRefused() async throws {
        let h = try await Harness()
        defer { h.fixture.remove() }
        let model = h.model
        let documents = try h.child("Documents")
        model.click(documents)
        await model.requestTrashSelection()
        let pending = try #require(model.pendingTrash)
        #expect(pending.allowed.isEmpty)
        #expect(pending.refused.map(\.reason) == [.homeFolder])
        await model.confirmTrash()
        #expect(model.lastMove == nil)
        #expect(h.exists("Documents/a.pdf"))
    }

    @Test("Context-menu Move to Trash on a selected block acts on the whole selection; on another block, on it alone")
    func contextActsOnSelection() async throws {
        let h = try await Harness()
        defer { h.fixture.remove() }
        let model = h.model
        model.drill(into: try h.child("Work"))
        let render = try h.child("old-render.mov")
        let build = try h.child("build")
        let notes = try h.child("notes.txt")
        model.setSelected(render, true)
        model.setSelected(build, true)
        await model.requestTrash(render)
        #expect(Set(model.pendingTrash?.allowed ?? []) == [render, build])
        model.cancelTrash()
        await model.requestTrash(notes)
        #expect(model.pendingTrash?.allowed == [notes])
        model.cancelTrash()
        #expect(model.selection == [render, build])
    }

    @Test("An open app bundle is refused with “quit first” and can be quit from the confirmation")
    func runningApp() async throws {
        let h = try await Harness(running: ["com.example.editor": "Editor"])
        defer { h.fixture.remove() }
        let contents = h.fixture.path("Apps/Editor.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.editor", "CFBundleName": "Editor"], format: .xml,
            options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        try h.fixture.file("Apps/Editor.app/Contents/MacOS/Editor", bytes: 20_000)
        h.model.start(.home)
        await h.model.waitForWalk()
        h.model.drill(into: try h.child("Apps"))
        let editor = try h.child("Editor.app")
        await h.model.requestTrash([editor])
        let pending = try #require(h.model.pendingTrash)
        #expect(pending.allowed.isEmpty)
        #expect(pending.refused.first?.reason == .appRunning("Editor"))
        #expect(pending.blockingApps.map(\.bundleID) == ["com.example.editor"])
        #expect(h.exists("Apps/Editor.app/Contents/Info.plist"))
    }
}
