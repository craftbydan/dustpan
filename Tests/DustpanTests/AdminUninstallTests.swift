import Foundation
import Testing

@testable import Dustpan

/// Apps installed for all users (bundle not writable by the user): no Uninstall, "Show in
/// Finder", a "gone — remove leftovers?" prompt once the bundle disappears, and the grouped
/// result. Fixture app folder in a temp directory; permissions restored before cleanup.
@Suite("Apps installed for all users")
@MainActor
struct AdminUninstallTests {
    /// `Applications/Shared/Huddle.app`, made read-only (555) together with its parent, plus
    /// leftovers in the fake home.
    static func makeHuddle(_ h: AppsTests.Harness) throws -> (bundle: URL, parent: URL) {
        let parent = h.apps.appendingPathComponent("Shared", isDirectory: true)
        let bundle = try h.app("Huddle", id: "com.huddle.Huddle", in: parent)
        try h.fixture.file("Library/Caches/com.huddle.Huddle/c.bin", bytes: 30_000)
        try h.fixture.file("Library/Preferences/com.huddle.Huddle.plist", bytes: 300)
        try h.fixture.file("Library/Logs/Huddle Sync/sync.log", bytes: 500)
        for url in [bundle, parent] { try lock(url) }
        return (bundle, parent)
    }

    static func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }

    static func unlock(_ urls: [URL]) {
        for url in urls { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func model(_ h: AppsTests.Harness, revealed: RevealLog) -> AppsModel {
        AppsModel(
            scanner: h.scanner, cleaner: h.cleaner(), home: h.fixture.url, systemLibrary: h.systemLibrary,
            runningApps: FakeRunningApps(), quitter: FakeQuitter(succeeds: true), isKnownApp: { _ in false },
            now: { h.fixture.now }, reveal: { revealed.urls.append($0) })
    }

    @Test("A bundle the user can't write is flagged, and Uninstall isn't offered")
    func flaggedAndNoUninstall() async throws {
        let h = try AppsTests.Harness()
        let (bundle, parent) = try Self.makeHuddle(h)
        defer {
            Self.unlock([bundle, parent])
            h.remove()
        }
        try h.app("Notes", id: "com.example.Notes")
        #expect(AppRemoval.needsAdmin(bundle.path))
        #expect(!AppRemoval.needsAdmin(h.apps.appendingPathComponent("Notes.app").path))

        let revealed = RevealLog()
        let model = model(h, revealed: revealed)
        await model.load(hasFullDiskAccess: true)
        let huddle = try #require(model.apps.first { $0.bundleID == "com.huddle.Huddle" })
        #expect(huddle.needsAdminToRemove)
        #expect(model.apps.first { $0.bundleID == "com.example.Notes" }?.needsAdminToRemove == false)
        await model.select(huddle)
        model.requestUninstall()
        #expect(!model.isConfirmingUninstall && model.quitPromptName == nil)
        model.showInFinder(huddle)
        #expect(revealed.urls == [huddle.url])
        #expect(model.finderRemovalApp == huddle)
    }

    @Test("A forced uninstall of such an app moves nothing and keeps its leftovers")
    func forcedUninstallKeepsLeftovers() async throws {
        let h = try AppsTests.Harness()
        let (bundle, parent) = try Self.makeHuddle(h)
        defer {
            Self.unlock([bundle, parent])
            h.remove()
        }
        let record = try await h.record("com.huddle.Huddle")
        let installed = await h.scanner.identities()
        let matcher = h.matcher()
        let leftovers = await Task.detached { matcher.leftovers(for: record.identity, installed: installed) }.value
            .matches.filter(\.isSelectedByDefault)
        #expect(leftovers.count == 2)
        let report = await h.cleaner().uninstall(app: record, leftovers: leftovers)
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.appMoveFailed, .appNotRemoved, .appNotRemoved])
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(FileManager.default.fileExists(atPath: h.lib("Caches/com.huddle.Huddle").path))
        #expect(try await h.store.logs().isEmpty)
    }

    @Test("Once the bundle is gone, the prompt offers its leftovers; the Cleaner moves them; undo restores")
    func goneFlow() async throws {
        let h = try AppsTests.Harness()
        let (bundle, parent) = try Self.makeHuddle(h)
        defer {
            Self.unlock([bundle, parent])
            h.remove()
        }
        let revealed = RevealLog()
        let model = model(h, revealed: revealed)
        await model.load(hasFullDiskAccess: true)
        let huddle = try #require(model.apps.first { $0.bundleID == "com.huddle.Huddle" })
        await model.select(huddle)
        model.showInFinder(huddle)

        // Still there: nothing happens.
        await model.checkForRemovedApps()
        #expect(model.gone == nil)

        // The user drags it to the Trash in Finder (simulated: unlock and delete the fixture).
        Self.unlock([bundle, parent])
        try FileManager.default.removeItem(at: bundle)
        let cachesDigest = try CleanerTests.digest(h.lib("Caches/com.huddle.Huddle"))
        await model.checkForRemovedApps()
        let prompt = try #require(model.gone)
        #expect(prompt.app.bundleID == "com.huddle.Huddle")
        #expect(!model.apps.contains { $0.bundleID == "com.huddle.Huddle" })
        #expect(model.finderRemovalApp == nil)
        let names = Set(model.selectedGoneLeftovers.map(\.url.lastPathComponent))
        #expect(names == ["com.huddle.Huddle", "com.huddle.Huddle.plist"])
        // The low-confidence name match is listed but not ticked.
        #expect(prompt.scan.matches.contains { $0.url.lastPathComponent == "Huddle Sync" && !model.isGoneSelected($0) })

        await model.confirmGoneLeftovers()
        let report = try #require(model.lastReport)
        #expect(report.moved.count == 2 && report.skipped.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.lib("Caches/com.huddle.Huddle").path))
        #expect(FileManager.default.fileExists(atPath: h.lib("Logs/Huddle Sync").path))
        #expect(try await h.store.logs().allSatisfy { $0.ruleID == "app:com.huddle.Huddle" })

        await model.undoLast()
        #expect(try CleanerTests.digest(h.lib("Caches/com.huddle.Huddle")) == cachesDigest)
        #expect(FileManager.default.fileExists(atPath: h.lib("Preferences/com.huddle.Huddle.plist").path))
    }

    @Test("Leftovers of a 'removed' app stay while the app still exists anywhere macOS knows")
    func removedAppStillThere() async throws {
        let h = try AppsTests.Harness()
        defer { h.remove() }
        let bundle = try h.app("Huddle", id: "com.huddle.Huddle")
        try h.fixture.file("Library/Caches/com.huddle.Huddle/c.bin", bytes: 100)
        let record = try await h.record("com.huddle.Huddle")
        let leftover = AppsTests.forged(h.lib("Caches/com.huddle.Huddle"), id: "com.huddle.Huddle")

        // Still installed at its path.
        var report = await h.cleaner().removeLeftovers(ofRemovedApp: record.identity, leftovers: [leftover])
        #expect(report.moved.isEmpty && report.skipped.first?.reason == .appStillInstalled)

        // Gone from the app folder, but LaunchServices finds a copy elsewhere that exists.
        let elsewhere = h.fixture.outside.appendingPathComponent("Huddle.app")
        try FileManager.default.createDirectory(at: h.fixture.outside, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bundle, to: elsewhere)
        report = await h.cleaner(elsewhere: ["com.huddle.Huddle": elsewhere.path])
            .removeLeftovers(ofRemovedApp: record.identity, leftovers: [leftover])
        #expect(report.moved.isEmpty && report.skipped.first?.reason == .appStillInstalled)

        // A stale LaunchServices entry pointing at nothing doesn't count; Apple IDs never qualify.
        try FileManager.default.removeItem(at: elsewhere)
        let apple = AppIdentity(
            bundleID: "com.apple.Notes", teamID: nil, name: "Notes", url: h.apps.appendingPathComponent("Notes.app"))
        report = await h.cleaner().removeLeftovers(ofRemovedApp: apple, leftovers: [leftover])
        #expect(report.moved.isEmpty && report.skipped.first?.reason == .notALeftover)
        report = await h.cleaner(elsewhere: ["com.huddle.Huddle": elsewhere.path])
            .removeLeftovers(ofRemovedApp: record.identity, leftovers: [leftover])
        #expect(report.moved.map(\.original.lastPathComponent) == ["com.huddle.Huddle"])
    }

    @Test("The result groups identical skip reasons into one line each")
    func groupingCollapses() {
        let base = URL(fileURLWithPath: "/tmp/x")
        var items: [(url: URL, reason: SkipReason)] = [(base.appendingPathComponent("Huddle.app"), .appMoveFailed)]
        for index in 0..<14 { items.append((base.appendingPathComponent("leftover\(index)"), .appNotRemoved)) }
        items.append((base.appendingPathComponent("a"), .appRunning("Chrome")))
        items.append((base.appendingPathComponent("b"), .appRunning("Zen")))
        items.append((base.appendingPathComponent("c"), .appRunning("Chrome")))
        let groups = SkippedGroupsView.groups(items)
        #expect(groups.map(\.reason) == [.appMoveFailed, .appNotRemoved, .appRunning("Chrome"), .appRunning("Zen")])
        #expect(groups.map(\.urls.count) == [1, 14, 2, 1])
    }
}

/// Records what "Show in Finder" would have revealed (tests never open Finder).
@MainActor
final class RevealLog {
    var urls: [URL] = []
}
