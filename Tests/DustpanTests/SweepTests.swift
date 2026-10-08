import Darwin
import Foundation
import Testing
import os

@testable import Dustpan

// MARK: - Mock scanners

/// Counts how many mock modules run at the same time.
final class Overlap: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
    func enter() {
        state.withLock {
            $0.now += 1; $0.peak = max($0.peak, $0.now)
        }
    }
    func leave() { state.withLock { $0.now -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
}

struct MockFailure: LocalizedError {
    var errorDescription: String? { "The mock module broke." }
}

/// A Sweep module that takes `duration`, reporting progress, then returns `finding` (or throws).
/// `busy` spins (like synchronous file walking) and checks `Task.isCancelled` every millisecond
/// instead of sleeping.
struct MockSweepScanner: SweepScanner {
    let module: SweepModule
    var duration: Duration = .milliseconds(300)
    var finding: SweepFinding = .needsAccess
    var fails = false
    var busy = false
    var overlap: Overlap?

    func run(hasFullDiskAccess: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> SweepFinding {
        overlap?.enter()
        defer { overlap?.leave() }
        let clock = ContinuousClock()
        let end = clock.now + duration
        var step = 0
        while clock.now < end {
            if busy {
                // Synchronous work, checking for cancellation as the real scanners do.
                let sliceEnd = clock.now + .milliseconds(1)
                while clock.now < sliceEnd {}
                if Task.isCancelled { throw CancellationError() }
            } else {
                try await Task.sleep(for: .milliseconds(20))
            }
            step += 1
            if step % 5 == 0 { progress(0.5) }
        }
        if fails { throw MockFailure() }
        return finding
    }
}

private func mocks(
    duration: Duration = .milliseconds(300), busy: Bool = false, failing: SweepModule? = nil, overlap: Overlap? = nil
) -> [any SweepScanner] {
    SweepModule.allCases.map { module in
        MockSweepScanner(
            module: module, duration: duration, finding: .orphans(LeftoverScan()), fails: module == failing,
            busy: busy, overlap: overlap)
    }
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@Suite("Scan coordinator (mock scanners)")
struct ScanCoordinatorTests {
    @Test("All five modules run at once")
    func concurrent() async {
        let overlap = Overlap()
        let coordinator = ScanCoordinator(scanners: mocks(duration: .milliseconds(400), overlap: overlap))
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await coordinator.sweep(hasFullDiskAccess: true)
        let elapsed = seconds(clock.now - start)
        #expect(overlap.peak == 5)
        // One after another would take 2 s.
        #expect(elapsed < 1.5)
        #expect(outcome.findings.count == 5)
        #expect(SweepModule.allCases.allSatisfy { outcome.states[$0] == .finished })
        #expect(!outcome.wasCancelled)
    }

    @Test("Each module's progress streams: waiting, running with a fraction, then finished")
    func progress() async {
        let coordinator = ScanCoordinator(scanners: mocks(duration: .milliseconds(300)))
        let (stream, continuation) = AsyncStream.makeStream(of: SweepEvent.self)
        async let outcome = coordinator.sweep(hasFullDiskAccess: true, events: continuation)
        var events: [SweepEvent] = []
        for await event in stream { events.append(event) }
        _ = await outcome
        for module in SweepModule.allCases {
            let states = events.filter { $0.module == module }.map(\.state)
            #expect(states.first == .waiting)
            #expect(states.contains(.running(nil)))
            #expect(states.contains(.running(0.5)))
            #expect(states.last == .finished)
        }
    }

    @Test("Cancel stops every module within 1 s", arguments: [false, true])
    func cancelMocks(busy: Bool) async {
        let coordinator = ScanCoordinator(scanners: mocks(duration: .seconds(20), busy: busy))
        let task = Task { await coordinator.sweep(hasFullDiskAccess: true) }
        try? await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        let outcome = await task.value
        let latency = seconds(clock.now - cancelled)
        #expect(latency < 1)
        #expect(outcome.wasCancelled)
        #expect(outcome.findings.isEmpty)
        #expect(SweepModule.allCases.allSatisfy { outcome.states[$0] == .cancelled })
    }

    @Test("A failing module doesn't stop the others")
    func failingModule() async {
        let coordinator = ScanCoordinator(scanners: mocks(failing: .unusedApps))
        let outcome = await coordinator.sweep(hasFullDiskAccess: true)
        #expect(outcome.states[.unusedApps] == .failed("The mock module broke."))
        #expect(outcome.findings[.unusedApps] == nil)
        #expect(outcome.findings.count == 4)
        #expect(!outcome.wasCancelled)
    }

    @Test("A module that needs Full Disk Access reports it, with no finding")
    func needsAccess() async {
        let coordinator = ScanCoordinator(scanners: [
            MockSweepScanner(module: .duplicates, duration: .milliseconds(10), finding: .needsAccess)
        ])
        let outcome = await coordinator.sweep(hasFullDiskAccess: false)
        #expect(outcome.states[.duplicates] == .needsAccess)
        #expect(outcome.findings.isEmpty)
    }

    @Test("The Downloads module never looks without Full Disk Access")
    func downloadsNeedsAccess() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        let same = Data(repeating: 7, count: 200_000)
        try same.write(to: fixture.path("Downloads/a.bin").creatingParent())
        try same.write(to: fixture.path("Downloads/b.bin"))
        let finder = DuplicateFinder(home: fixture.url, hasFullDiskAccess: { true })
        let scanner = DownloadsDuplicatesSweepScanner(finder: finder, home: fixture.url)
        let without = try await scanner.run(hasFullDiskAccess: false) { _ in }
        guard case .needsAccess = without else {
            Issue.record("Expected needsAccess without Full Disk Access")
            return
        }
        let with = try await scanner.run(hasFullDiskAccess: true) { _ in }
        #expect(with.bytes(now: Date()) > 0)
    }

    @Test("Sweep model: a failing module shows a quiet banner and the rest of the results")
    @MainActor
    func modelFailingModule() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        let model = h.model(scanners: mocks(duration: .milliseconds(50), failing: .largeOld))
        await model.sweep()
        #expect(model.phase == .results)
        #expect(model.issue == .sweepPartly(["Large & old files"]))
        #expect(model.state(.largeOld) == .failed("The mock module broke."))
        #expect(model.state(.junk) == .finished)
        #expect(model.lastSwept != nil)
    }

    @Test("Sweep model: Cancel goes back to the start within 1 s and keeps nothing")
    @MainActor
    func modelCancel() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        let model = h.model(scanners: mocks(duration: .seconds(20), busy: true))
        model.start()
        #expect(model.phase == .scanning)
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let cancelled = clock.now
        model.cancel()
        await model.waitForSweep()
        #expect(seconds(clock.now - cancelled) < 1)
        #expect(model.phase == .idle)
        #expect(model.wasCancelled)
        #expect(model.findings.isEmpty)
        #expect(model.lastSwept == nil)
    }

    @Test("Last swept is saved in the settings table")
    @MainActor
    func lastSweptSaved() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        let model = h.model(scanners: mocks(duration: .milliseconds(20)))
        await model.sweep()
        let saved = try #require(await h.settings.date(.lastSwept))
        #expect(abs(saved.timeIntervalSinceNow) < 60)
        let reopened = h.model(scanners: [])
        await reopened.load()
        #expect(reopened.lastSwept == saved)
        #expect(SweepDates.relative(saved) == "today")
    }

    @Test("Recommended = safe, pre-selected, not detection-only junk")
    func recommendedFilter() {
        func item(_ risk: Risk, selected: Bool, detection: Bool = false) -> ScanItem {
            ScanItem(
                id: UUID(), url: URL(fileURLWithPath: "/tmp/x"), allocatedSize: 10, modified: .distantPast,
                category: .userCache, ruleID: "r", risk: risk, isSelected: selected, detectionOnly: detection,
                excludedURLs: [])
        }
        let safe = item(.safe, selected: true)
        let items = [
            safe, item(.safe, selected: false), item(.review, selected: true), item(.review, selected: false),
            item(.safe, selected: true, detection: true),
        ]
        #expect(JunkScanOutput.recommended(items).map(\.id) == [safe.id])
    }
}

// MARK: - Fixture home sweeps (real scanners)

/// A fake home, app folder, `/Library`, Trash and database in a temp folder.
struct SweepHarness {
    let fixture: FixtureHome
    let apps: URL
    let systemLibrary: URL
    let trash: URL
    let database: AppDatabase
    let settings: SettingsStore

    init() throws {
        fixture = try FixtureHome()
        let container = fixture.outside.deletingLastPathComponent()
        apps = container.appendingPathComponent("Applications", isDirectory: true)
        systemLibrary = container.appendingPathComponent("SystemLibrary", isDirectory: true)
        trash = container.appendingPathComponent("trash", isDirectory: true)
        for url in [apps, systemLibrary, trash] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        database = try AppDatabase(directory: container.appendingPathComponent("db"))
        settings = SettingsStore(database: database)
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: fixture.path(relative).path) }

    @MainActor
    func model(scanners: [any SweepScanner]) -> SweepModel {
        let cleaner = Cleaner(
            home: fixture.url, trashMover: TempTrashMover(trashDirectory: trash),
            store: CleanupStore(database: database),
            rules: { [] })
        return SweepModel(
            coordinator: ScanCoordinator(scanners: scanners), cleaner: cleaner, settings: settings,
            hasFullDiskAccess: { true })
    }

    /// The whole app wired as in `AppState`, on the fake home.
    @MainActor
    func appState(access: Bool = true) async -> AppState {
        let state = AppState(
            database: database, permissions: FakePermissions(flag: AccessFlag(granted: access)), home: fixture.url,
            trashMover: TempTrashMover(trashDirectory: trash), runningApps: FakeRunningApps(), appRoots: [apps],
            systemLibrary: systemLibrary, signing: FakeSigning(),
            lastUsed: FakeLastUsed(byName: [
                "Old.app": fixture.now.addingTimeInterval(-400 * 86_400),
                "New.app": fixture.now.addingTimeInterval(-10 * 86_400),
            ]))
        await state.onboarding.load(allowPresentation: false)
        return state
    }

    /// `<apps>/<name>.app` with an Info.plist and a payload.
    func app(_ name: String, id: String, payload: Int) throws {
        let contents = apps.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try fixture.file("", bytes: payload, absolute: contents.appendingPathComponent("MacOS/\(name)"))
    }

    /// A file with `bytes` allocated but not written (fast, even for gigabytes).
    func reserve(_ relative: String, bytes: Int64, ageDays: Double) throws {
        let url = fixture.path(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE, fst_offset: 0, fst_length: off_t(bytes),
            fst_bytesalloc: 0)
        _ = fcntl(fd, F_PREALLOCATE, &store)
        guard ftruncate(fd, off_t(bytes)) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let date = fixture.now.addingTimeInterval(-ageDays * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Something for every tile: safe old junk, young junk, `.review` junk, a leftover of a gone
    /// app, an unused and a used app, two copies in Downloads, a big old file and a mid-size one.
    func populate() throws {
        try fixture.file("Library/Caches/com.example.app/a.bin", bytes: 12_000)
        try fixture.file("Library/Caches/com.example.other/b.bin", bytes: 30_000, ageDays: 20)
        try fixture.file("Library/Caches/com.example.young/c.bin", bytes: 4_000, ageDays: 1)
        try fixture.file(".cache/zzreview/d.bin", bytes: 8_000, ageDays: 30)
        try fixture.file("Library/Preferences/com.gone.oldapp.plist", bytes: 3_000, ageDays: 90)
        try app("Old", id: "com.example.old", payload: 50_000)
        try app("New", id: "com.example.new", payload: 20_000)
        let same = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        try same.write(to: fixture.path("Downloads/report.pdf").creatingParent())
        try same.write(to: fixture.path("Downloads/report (1).pdf"))
        try reserve("Movies/big.mov", bytes: 1_200_000_000, ageDays: 400)
        try reserve("Movies/medium.mov", bytes: 150_000_000, ageDays: 400)
    }

    func remove() { fixture.remove() }
}

extension URL {
    /// Creates the parent folder, then returns self.
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

@Suite("Sweep on a fixture home", .serialized)
struct SweepFixtureTests {
    @Test("Every tile equals its feature screen's total, adopted and scanned on its own")
    @MainActor
    func tilesEqualFeatureTotals() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.populate()
        let state = await h.appState()
        let sweep = state.sweep
        await sweep.sweep()
        #expect(sweep.phase == .results)
        #expect(sweep.issue == nil)
        #expect(SweepModule.allCases.allSatisfy { sweep.state($0) == .finished })

        let junk = sweep.bytes(.junk)
        let orphans = sweep.bytes(.orphans)
        let unused = sweep.bytes(.unusedApps)
        let duplicates = sweep.bytes(.duplicates)
        let largeOld = sweep.bytes(.largeOld)
        #expect(junk > 0)
        #expect(orphans > 0)
        #expect(unused > 0)
        #expect(duplicates > 0)
        #expect(largeOld >= 1_200_000_000)
        #expect(largeOld < 1_350_000_000)  // the 150 MB file isn't counted by the tile

        // Carried over without looking again.
        #expect(state.junk.hasScanned && state.junk.totalBytes == junk)
        #expect(state.apps.orphans?.removableBytes == orphans)
        #expect(state.apps.unusedBytes == unused)
        #expect(state.clutter.duplicates.totalReclaimable == duplicates)
        state.review(.largeOld)
        #expect(state.section == .clutter && state.clutter.tab == .largeOld)
        #expect(state.clutter.largeOld.visibleBytes == largeOld)
        state.review(.orphans)
        #expect(state.section == .apps && state.apps.tab == .leftovers)

        // Each screen looking again on its own finds the same totals.
        await state.junk.scan(hasFullDiskAccess: true)
        #expect(state.junk.totalBytes == junk)
        await state.apps.load(hasFullDiskAccess: true)
        #expect(state.apps.unusedBytes == unused)
        await state.apps.loadOrphans(hasFullDiskAccess: true)
        #expect(state.apps.orphans?.removableBytes == orphans)
        await state.clutter.duplicates.scan()
        #expect(state.clutter.duplicates.totalReclaimable == duplicates)
        #expect(state.clutter.duplicates.sweptFolder == nil)
        await state.clutter.largeOld.scan()
        state.clutter.largeOld.filter = .sweep
        #expect(state.clutter.largeOld.visibleBytes == largeOld)
    }

    @Test("Clean recommended moves only safe, pre-selected junk; Undo puts it back")
    @MainActor
    func cleanRecommendedOnlySafeJunk() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.populate()
        let state = await h.appState()
        let sweep = state.sweep
        await sweep.sweep()

        let recommended = sweep.recommendedItems
        #expect(!recommended.isEmpty)
        #expect(recommended.allSatisfy { $0.risk == .safe && $0.isSelected && !$0.detectionOnly })
        let names = Set(recommended.map(\.url.lastPathComponent))
        #expect(names == ["com.example.app", "com.example.other"])
        // The `.review` item and the young one were found, but aren't recommended.
        let found = Set(sweep.junk?.results.flatMap(\.items).map(\.url.lastPathComponent) ?? [])
        #expect(found.isSuperset(of: ["zzreview", "com.example.young"]))

        sweep.requestClean()
        #expect(sweep.isConfirming)
        await sweep.confirmClean()
        let report = try #require(sweep.lastReport)
        #expect(Set(report.moved.map(\.itemID)) == Set(recommended.map(\.id)))
        #expect(report.skipped.isEmpty)
        #expect(sweep.undoDeadline != nil)

        // Only the two safe caches went to the (fake) Trash.
        #expect(!h.exists("Library/Caches/com.example.app"))
        #expect(!h.exists("Library/Caches/com.example.other"))
        for kept in [
            "Library/Caches/com.example.young/c.bin", ".cache/zzreview/d.bin",
            "Library/Preferences/com.gone.oldapp.plist",
            "Downloads/report.pdf", "Downloads/report (1).pdf", "Movies/big.mov", "Movies/medium.mov",
        ] {
            #expect(h.exists(kept), "\(kept) should stay")
        }
        #expect(FileManager.default.fileExists(atPath: h.apps.appendingPathComponent("Old.app").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: h.trash.path)
        #expect(Set(trashed) == ["com.example.app", "com.example.other"])

        // The Junk screen forgot them; the tile shrank; Last swept was saved.
        #expect(!state.junk.allItems.contains { names.contains($0.url.lastPathComponent) })
        #expect(sweep.recommendedItems.isEmpty)
        #expect(await h.settings.date(.lastSwept) != nil)

        await sweep.undoLastClean()
        #expect(h.exists("Library/Caches/com.example.app/a.bin"))
        #expect(h.exists("Library/Caches/com.example.other/b.bin"))
        #expect(Set(sweep.recommendedItems.map(\.url.lastPathComponent)) == names)
    }

    @Test("Cancel stops the real scanners within 1 s")
    @MainActor
    func cancelRealScanners() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.populate()
        // Enough files that the junk and large & old walks are still busy when Cancel comes.
        let bytes = Data(repeating: 1, count: 64)
        for folder in 0..<40 {
            let dir = h.fixture.path("Library/Caches/com.example.many\(folder)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<500 { try bytes.write(to: dir.appendingPathComponent("f\(file)")) }
        }
        let state = await h.appState()
        let sweep = state.sweep
        sweep.start()
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let cancelled = clock.now
        sweep.cancel()
        await sweep.waitForSweep()
        let latency = seconds(clock.now - cancelled)
        print("Sweep cancel latency on the fixture home: \(latency) s")
        #expect(latency < 1)
        #expect(sweep.phase == .idle)
        #expect(sweep.wasCancelled)
        #expect(sweep.findings.isEmpty)
        // Cancel came while real scanners were still busy, and they stopped.
        #expect(SweepModule.allCases.contains { sweep.state($0) == .cancelled })
        #expect(!state.junk.hasScanned)
    }

    @Test("Without Full Disk Access the Downloads tile is locked and Downloads is never read")
    @MainActor
    func withoutAccess() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.populate()
        let state = await h.appState(access: false)
        await state.sweep.sweep()
        #expect(state.sweep.state(.duplicates) == .needsAccess)
        #expect(state.sweep.bytes(.duplicates) == 0)
        #expect(!state.clutter.duplicates.hasScanned)
        #expect(state.sweep.state(.junk) == .finished)
    }
}

@Suite("Cleaner without Full Disk Access (bundled catalogue)")
struct CleanerNoAccessTests {
    /// Regression: the scanner drops rules that need Full Disk Access, so the Cleaner's rule
    /// matcher must resolve winners by rule ID, not by index into its own longer list.
    @Test("Scan → clean with access off moves caches, Chrome, logs and npm items")
    func cleanWithoutAccess() async throws {
        let h = try CleanerTests.Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 12_000)
        try h.fixture.file("Library/Caches/com.google.Chrome/Default/Cache/data_0", bytes: 20_000)
        try h.fixture.file("Library/Logs/com.example.sync/sync.log", bytes: 9_000, ageDays: 20)
        try h.fixture.file("Library/Logs/DiagnosticReports/Finder-2026-09-01.ips", bytes: 5_000, ageDays: 20)
        try h.fixture.file(".npm/_cacache/content-v2/sha512/ab/cd", bytes: 15_000)
        let rules = try await RuleCatalog().rules()
        #expect(rules.contains { $0.needsFullDiskAccess })  // the case that shifted indices
        let items = await JunkScanner(rules: rules, home: h.fixture.url, now: h.fixture.now, hasFullDiskAccess: false)
            .scan().flatMap(\.items)
        let names = [
            "com.example.app", "com.google.Chrome", "com.example.sync", "Finder-2026-09-01.ips", "_cacache",
        ]
        let chosen = names.compactMap { name in items.first { $0.url.lastPathComponent == name } }
        #expect(chosen.count == names.count)
        let cleaner = h.cleaner(rules, access: false)
        let report = await cleaner.clean(chosen)
        #expect(report.skipped.isEmpty, "\(report.skipped.map { "\($0.url.lastPathComponent): \($0.reason)" })")
        #expect(report.moved.count == names.count)
    }

    @Test("Something ignored after the scan is never moved")
    func ignoredAfterScan() async throws {
        let h = try CleanerTests.Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 12_000)
        try h.fixture.file("Library/Caches/com.example.other/b.bin", bytes: 12_000)
        try h.fixture.file("Library/Logs/com.example.sync/sync.log", bytes: 9_000, ageDays: 20)
        let rules = try await RuleCatalog().rules()
        let items = await JunkScanner(rules: rules, home: h.fixture.url, now: h.fixture.now).scan().flatMap(\.items)
        let app = try #require(items.first { $0.url.lastPathComponent == "com.example.app" })
        let other = try #require(items.first { $0.url.lastPathComponent == "com.example.other" })
        let log = try #require(items.first { $0.url.lastPathComponent == "com.example.sync" })
        try await h.store.ignore(path: app.url.path)
        try await h.store.ignore(ruleID: log.ruleID)
        let report = await h.cleaner(rules).clean([app, other, log])
        #expect(report.moved.map(\.itemID) == [other.id])
        #expect(Set(report.skipped.map(\.itemID)) == [app.id, log.id])
        #expect(report.skipped.allSatisfy { $0.reason == .ignored })
        #expect(h.exists("Library/Caches/com.example.app/a.bin"))
        #expect(h.exists("Library/Logs/com.example.sync/sync.log"))
    }
}

@Suite("Sweep and the ignore list", .serialized)
struct SweepIgnoreTests {
    @Test("Clean recommended skips an item ignored on the Junk screen after the Sweep")
    @MainActor
    func ignoredOnJunkScreen() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.populate()
        let state = await h.appState()
        await state.sweep.sweep()
        let item = try #require(state.junk.allItems.first { $0.url.lastPathComponent == "com.example.app" })
        await state.junk.ignore(item)
        #expect(state.sweep.recommendedItems.contains { $0.id == item.id })  // the Sweep's snapshot
        await state.sweep.confirmClean()
        let report = try #require(state.sweep.lastReport)
        #expect(report.skipped.contains { $0.itemID == item.id && $0.reason == .ignored })
        #expect(h.exists("Library/Caches/com.example.app/a.bin"))
        #expect(!h.exists("Library/Caches/com.example.other"))
    }
}
