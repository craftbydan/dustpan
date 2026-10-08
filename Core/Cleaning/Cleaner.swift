import AppKit
import Darwin
import Foundation
import os

/// Moves files to the Trash and back. The app uses `FileManagerTrashMover`; tests move into a
/// temp folder instead.
protocol TrashMover: Sendable {
    /// The folder trashed items land in. Undo only moves things out of here, and Empty Trash
    /// only deletes what is inside it.
    var trashDirectory: URL { get }
    /// Moves `url` to the Trash and returns where it ended up.
    func trash(_ url: URL) throws -> URL
    /// Moves `trashed` back to `original`, creating missing parent folders.
    func restore(_ trashed: URL, to original: URL) throws
}

extension TrashMover {
    func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trashed, to: original)
    }
}

/// The real Trash: `FileManager.trashItem(at:resultingItemURL:)`, so Finder shows the item
/// under its own name and can put it back too.
struct FileManagerTrashMover: TrashMover {
    let trashDirectory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let canonicalHome = PathTools.canonical(home.path) ?? home.path
        trashDirectory = URL(fileURLWithPath: canonicalHome, isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
    }

    func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else { throw CocoaError(.fileWriteUnknown) }
        return resulting as URL
    }
}

/// Tells the Cleaner whether an app is open. Injected so tests can pretend.
protocol RunningAppsChecking: Sendable {
    /// The app's name when at least one copy of it is running, else nil.
    func runningAppName(bundleID: String) -> String?
}

struct WorkspaceRunningApps: RunningAppsChecking {
    func runningAppName(bundleID: String) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        return app.localizedName ?? bundleID
    }
}

/// Why the Cleaner left something where it was. Every reason has plain words for the UI.
enum SkipReason: Error, Sendable, Equatable {
    /// Shown for information only (Docker data, the Trash itself).
    case detectionOnly
    /// In or containing a protected place, or holding an app database.
    case protected
    /// The item, after following links, is not where its rule looks.
    case leavesRuleRoot
    /// The item is a link to somewhere else.
    case isSymlink
    /// The app that owns it is open (`requiresQuit`).
    case appRunning(String)
    /// The item's rule isn't in the catalogue (or the catalogue didn't load).
    case unknownRule
    /// It is no longer there.
    case notFound
    /// macOS refused the move.
    case moveFailed
    /// The item isn't what its rule finds (wrong name, excluded name, or another rule's place).
    case ruleMismatch
    /// Changed more recently than its rule allows.
    case tooRecent
    /// On the ignore list (the item, a folder above it, or its rule).
    case ignored
    /// In a folder macOS guards with Full Disk Access, which Dustpan doesn't have.
    case needsFullDiskAccess
    /// Something on its path changed between checking and moving (e.g. became a link).
    case changedDuringClean
    /// Uninstall: not an app bundle Dustpan may remove (wrong place, link, or a different ID).
    case notAnApp
    /// Uninstall: part of macOS or signed by Apple.
    case appleApp
    /// Uninstall: couldn't be re-matched to the app (or, for orphans, an app may still use it).
    case notALeftover
    /// Owned by the system or another user; needs the privileged helper (later version).
    case needsHelper
    /// Uninstall: the app bundle itself didn't move, so its files were kept with it.
    case appNotRemoved
    /// Uninstall: macOS wouldn't move the app (e.g. it's owned by another user).
    case appMoveFailed
    /// Leftovers of a removed app: the app is still there (or macOS still finds it), so its files stay.
    case appStillInstalled
    /// Space map: the home folder itself, or a folder macOS and apps expect (~/Library, ~/Documents, …).
    case homeFolder
    /// Space map: outside the home folder.
    case outsideHome
    /// Space map: Dustpan itself or its history file.
    case dustpanItself
    /// Space map: inside an app bundle.
    case insideApp
    /// Space map: already in the Trash.
    case alreadyInTrash
    /// Space map: the path doesn't match the one on disk exactly (e.g. different capitals).
    case pathMismatch
    /// Clutter: not a single regular file.
    case notAFile
    /// Clutter: inside a package (an app, a library, a bundle) or a folder a tool manages.
    case insidePackage
    /// Clutter: only a placeholder for a file stored in the cloud.
    case cloudOnly
    /// Duplicates: it's the copy being kept, or the same file as it, so it stays.
    case lastCopy
    /// Duplicates: the copy being kept is gone, moved or changed.
    case keeperMissing
    /// Duplicates: its content no longer matches the copy being kept.
    case contentChanged
    /// Space map / Clutter: inside a folder an app keeps its database in (safety rule 2).
    case appDatabaseFolder
    /// Space map / Clutter: a place a `.never` rule covers (unsaved documents, offline music,
    /// downloaded models, sign-in tokens), or a folder holding one.
    case neverTouched

    var explanation: String {
        switch self {
        case .detectionOnly: "Shown for information only. Dustpan doesn't move this."
        case .protected: "Inside a place Dustpan never touches, or holds an app's database."
        case .leavesRuleRoot: "Leads somewhere outside the folder its rule looks in."
        case .isSymlink: "It's a link to somewhere else, so it was left alone."
        case .appRunning(let name): "\(name) is open. Quit it and clean again."
        case .unknownRule: "Dustpan couldn't match this to one of its rules."
        case .notFound: "It's already gone."
        case .moveFailed: "macOS wouldn't move it to the Trash."
        case .ruleMismatch: "It isn't something its rule looks for, so it was left alone."
        case .tooRecent: "It changed recently, so it was left alone for now."
        case .ignored: "You asked Dustpan to ignore it, so it was left alone."
        case .needsFullDiskAccess: "It's in a folder Dustpan can't open without Full Disk Access."
        case .changedDuringClean: "It changed while Dustpan was cleaning, so it was left alone."
        case .notAnApp: "Dustpan couldn't confirm this is the app you chose, so it was left alone."
        case .appleApp: "It's part of macOS or made by Apple, so Dustpan doesn't remove it."
        case .notALeftover: "Dustpan couldn't confirm it belongs to this app, so it was left alone."
        case .needsHelper: "Owned by the system. Removing it needs a helper, coming in a later version."
        case .appNotRemoved: "Kept, because the app itself couldn't be moved."
        case .appMoveFailed:
            "macOS wouldn't move the app. If it was installed for all users, drag it to the Trash in Finder."
        case .appStillInstalled: "The app is still on this Mac, so its files stay with it."
        case .homeFolder: "macOS and your apps expect this folder to be there, so Dustpan leaves it alone."
        case .outsideHome: "It's outside your home folder. Dustpan only moves your own files."
        case .dustpanItself: "That's Dustpan itself or its history, so it stays."
        case .insideApp: "It's part of an app. To remove the app, use Apps."
        case .alreadyInTrash: "It's already in the Trash."
        case .pathMismatch:
            "Its name on disk doesn't match the one Dustpan saw, so it was left alone. Look again first."
        case .notAFile: "Only single files are moved from here."
        case .insidePackage: "It's part of a bundle or a folder a tool manages, so it was left alone."
        case .cloudOnly: "It's stored in the cloud, not on this Mac, so moving it wouldn't free space here."
        case .lastCopy: "Dustpan always keeps one copy, so this one stays."
        case .keeperMissing: "The copy you're keeping has moved or changed, so this one stays. Look again first."
        case .contentChanged: "It no longer matches the copy you're keeping, so it was left alone."
        case .appDatabaseFolder: "It's in a folder an app keeps its database in, so it was left alone."
        case .neverTouched:
            "Dustpan never moves this: it can hold unsaved documents, sign-ins, offline downloads or models that are slow to get back."
        }
    }
}

/// What one `clean` did.
struct CleanReport: Sendable, Equatable {
    struct Moved: Sendable, Equatable {
        let itemID: UUID
        let category: JunkCategory
        let ruleID: String
        let original: URL
        let trashed: URL
        let bytes: Int64
        /// The `cleanupLog` row, nil only when logging failed.
        var logID: Int64?
    }

    struct Skipped: Sendable, Equatable {
        let itemID: UUID
        let url: URL
        let reason: SkipReason
    }

    var moved: [Moved] = []
    var skipped: [Skipped] = []
    /// Things were moved but the log write failed, so History can't put them back
    /// (they are still in Finder's Trash).
    var logFailed = false

    var freedBytes: Int64 { moved.reduce(0) { $0 + $1.bytes } }
    var logIDs: [Int64] { moved.compactMap(\.logID) }
    /// Items moved entirely: at least one part moved and nothing skipped.
    var cleanedItemIDs: Set<UUID> {
        Set(moved.map(\.itemID)).subtracting(skipped.map(\.itemID))
    }
}

/// Why an item could not be put back.
enum UndoFailure: Sendable, Equatable {
    case alreadyRestored
    case notInTrash
    case originalTaken
    case unsafePath
    case moveFailed
    case notLogged

    var explanation: String {
        switch self {
        case .alreadyRestored: "It's already back."
        case .notInTrash: "It's no longer in the Trash."
        case .originalTaken: "Something else is in its old place now."
        case .unsafePath: "The log entry points somewhere Dustpan won't move things."
        case .moveFailed: "macOS wouldn't move it back."
        case .notLogged: "Dustpan has no record of it."
        }
    }
}

struct UndoReport: Sendable, Equatable {
    var restored: [Int64] = []
    var failed: [Int64: UndoFailure] = [:]
}

/// One row of History: a log entry and where the item is now.
struct HistoryEntry: Sendable, Equatable, Identifiable {
    enum Status: Sendable, Equatable {
        case inTrash
        case restored(Date)
        /// Out of the Trash and something is at its old path again: put back with Finder's
        /// Put Back (or by hand), not through Dustpan.
        case backInPlace
        /// The Trash was emptied (or the item was moved somewhere else by hand).
        case gone
    }

    let log: CleanupLog
    let status: Status
    var id: Int64 { log.id ?? -1 }
}

/// What is in the Trash right now, shown in the Empty Trash confirmation. `emptyTrash` deletes
/// only the entries listed in `names` (the ones this user can delete whole), so nothing added
/// after the user confirmed, and nothing only Finder can delete, is touched.
struct TrashSummary: Sendable, Equatable {
    /// Entries Dustpan can delete, and their size.
    let names: [String]
    let bytes: Int64
    /// Entries that stay (put there with the user's password, or locked).
    var kept: [TrashLeftEntry] = []

    var keptBytes: Int64 { kept.reduce(0) { $0 + $1.bytes } }
    var hasDeletable: Bool { !names.isEmpty }
}

/// What one Empty Trash did.
struct EmptyTrashReport: Sendable, Equatable {
    var freedBytes: Int64 = 0
    var deleted: [String] = []
    /// Entries still in the Trash afterwards, with why.
    var left: [TrashLeftEntry] = []

    var leftBytes: Int64 { left.reduce(0) { $0 + $1.bytes } }
}

/// The only part of Dustpan that moves or deletes anything (CLAUDE.md).
///
/// `clean` re-checks every item before acting, whatever the scanner said:
/// - `detectionOnly` items (Docker data, the Trash) are refused;
/// - the item must still exist, must not be a link, and its symlink-free path must lie inside
///   the home folder (safety rule 4);
/// - the item must be exactly what its rule finds, re-derived from the catalogue with the
///   scanner's own matcher (`JunkScanner.makePlan`): right root, a matching glob and no exclude
///   glob, the winning rule for that path, and not in a `.never` place; its `minAgeDays` must
///   still hold;
/// - `ProtectedList.isProtected` (fails closed) must say no (safety rule 2);
/// - if the rule has `requiresQuit` and its app is running, the item is skipped (rule 5);
/// - an item holding paths that other rules (or `.never` rules) own is never moved whole: its
///   other children are moved one by one. Those paths are recomputed from the catalogue, not
///   taken from the item;
/// - right before each move the path is checked again (no link anywhere on it, same resolved
///   path, not protected).
/// Everything goes through `TrashMover` and every move gets a `cleanupLog` row, all written in
/// one transaction. The only permanent delete is `emptyTrash(_:)`, which the UI calls after
/// the user confirms the size.
actor Cleaner {
    // Internal (not private) so `Cleaner+Apps.swift` can use them.
    let home: String
    let trashMover: any TrashMover
    let runningApps: any RunningAppsChecking
    let store: CleanupStore
    let protectedList: ProtectedList
    /// Internal so the Space map and Clutter checks can read the `.never` paths.
    let rules: @Sendable () async throws -> [Rule]
    let now: @Sendable () -> Date
    let hasFullDiskAccess: @Sendable () -> Bool
    /// Where apps may be uninstalled from, and how to re-check them (Prompt 6).
    let appContext: AppCleaningContext
    /// Dustpan's own app bundle and database folder, never moved (Space map).
    let ownPaths: [String]
    /// Cloud placeholder check for clutter files (Prompt 8).
    let cloudStatus: any CloudStatusChecking
    let logger = Logger(subsystem: "app.dustpan", category: "cleaner")

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashMover: (any TrashMover)? = nil,
        runningApps: any RunningAppsChecking = WorkspaceRunningApps(),
        store: CleanupStore,
        protectedList: ProtectedList? = nil,
        rules: @escaping @Sendable () async throws -> [Rule],
        now: @escaping @Sendable () -> Date = { Date() },
        hasFullDiskAccess: @escaping @Sendable () -> Bool = { true },
        appContext: AppCleaningContext? = nil,
        ownPaths: [URL]? = nil,
        cloudStatus: any CloudStatusChecking = SystemCloudStatus()
    ) {
        self.cloudStatus = cloudStatus
        self.ownPaths = (ownPaths ?? Self.defaultOwnPaths()).map { PathTools.canonical($0.path) ?? $0.path }
        self.hasFullDiskAccess = hasFullDiskAccess
        self.appContext = appContext ?? .standard(home: home)
        self.home = PathTools.canonical(home.path) ?? home.standardizedFileURL.path
        self.trashMover = trashMover ?? FileManagerTrashMover(home: home)
        self.runningApps = runningApps
        self.store = store
        self.protectedList = protectedList ?? ProtectedList(home: home)
        self.rules = rules
        self.now = now
    }

    // MARK: - Clean

    /// Moves `items` to the Trash after re-checking each one, and logs every move.
    func clean(_ items: [ScanItem]) async -> CleanReport {
        assertNotMainThread()
        var report = CleanReport()
        let catalog = (try? await rules()) ?? []
        let rulesByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var runningByBundle: [String: String?] = [:]
        let trashPath = try? validatedTrashPath()
        let access = hasFullDiskAccess()
        // The ignore list as it is now: something ignored after the scan (e.g. on the Junk screen
        // while a Sweep's results wait) is never moved.
        let ignore = IgnoreList((try? await store.ignoreEntries()) ?? [])
        // Without Full Disk Access, never touch (not even `lstat`) a path inside a guarded folder.
        let reachable = items.filter { access || !needsAccess($0.url.path) }
        let matcher = await RuleMatcher(
            catalog: catalog, paths: reachable.compactMap { PathTools.canonical($0.url.path) }, home: home,
            protectedList: protectedList, now: now(), hasFullDiskAccess: access)

        for item in items {
            let skip = { (reason: SkipReason) in
                report.skipped.append(.init(itemID: item.id, url: item.url, reason: reason))
            }
            guard !item.detectionOnly else { skip(.detectionOnly); continue }
            guard let rule = rulesByID[item.ruleID] else { skip(.unknownRule); continue }
            guard !rule.detectionOnly else { skip(.detectionOnly); continue }
            guard rule.risk != .never else { skip(.protected); continue }
            guard !ignore.ignores(path: item.url.path.lowercased(), ruleID: rule.id) else {
                skip(.ignored)
                continue
            }
            guard access || !needsAccess(item.url.path) else { skip(.needsFullDiskAccess); continue }

            switch Self.linkState(item.url.path) {
            case .missing: skip(.notFound); continue
            case .link: skip(.isSymlink); continue
            case .present: break
            }
            guard let resolved = PathTools.canonical(item.url.path) else { skip(.notFound); continue }
            guard PathTools.isStrictlyInside(resolved, root: home),
                trashPath.map({ !PathTools.isInside(resolved, root: $0) && !PathTools.isInside($0, root: resolved) })
                    ?? true
            else { skip(.leavesRuleRoot); continue }
            guard !ignore.ignores(path: resolved.lowercased(), ruleID: rule.id) else { skip(.ignored); continue }
            guard !protectedList.isProtected(URL(fileURLWithPath: resolved)) else { skip(.protected); continue }
            guard matcher.winningRuleID(for: resolved) == rule.id else { skip(.ruleMismatch); continue }

            // Paths inside this item that other rules or `.never` rules own: from the catalogue,
            // plus anything the scanner reported.
            var excluded = Set(matcher.exclusions(inside: resolved).map { $0.lowercased() })
            excluded.formUnion(item.excludedURLs.map { (PathTools.canonical($0.path) ?? $0.path).lowercased() })

            if rule.minAgeDays > 0 {
                guard let newest = await matcher.newestChange(resolved, excluding: excluded) else {
                    skip(.protected)
                    continue
                }
                guard newest <= now().addingTimeInterval(-TimeInterval(rule.minAgeDays) * 86_400) else {
                    skip(.tooRecent)
                    continue
                }
            }

            if rule.requiresQuit {
                guard let bundleID = rule.appBundleID else { skip(.appRunning(rule.title)); continue }
                if runningByBundle[bundleID] == nil {
                    runningByBundle[bundleID] = .some(runningApps.runningAppName(bundleID: bundleID))
                }
                if let name = runningByBundle[bundleID] ?? nil { skip(.appRunning(name)); continue }
            }

            let parts: [(path: String, bytes: Int64?)]
            if excluded.isEmpty {
                parts = [(resolved, item.allocatedSize)]
            } else {
                parts = Self.movableParts(of: resolved, excluding: Array(excluded)).map { ($0, nil) }
            }

            for part in parts {
                let url = URL(fileURLWithPath: part.path)
                // Re-check right before moving: nothing on the path became a link, it still
                // resolves to itself inside the item, and it isn't protected.
                guard PathTools.isInside(part.path, root: resolved), Self.isUnchanged(part.path),
                    !protectedList.isProtectedPath(part.path)
                else {
                    report.skipped.append(.init(itemID: item.id, url: url, reason: .changedDuringClean))
                    continue
                }
                let bytes = part.bytes ?? Self.allocatedSize(of: url)
                do {
                    let trashed = try trashMover.trash(url)
                    report.moved.append(
                        .init(
                            itemID: item.id, category: item.category, ruleID: rule.id, original: url,
                            trashed: trashed, bytes: bytes))
                } catch {
                    report.skipped.append(.init(itemID: item.id, url: url, reason: .moveFailed))
                }
            }
        }

        let date = now()
        let rows = report.moved.map {
            CleanupLog(
                id: nil, date: date, originalPath: $0.original.path, trashPath: $0.trashed.path, bytes: $0.bytes,
                ruleID: $0.ruleID, restoredAt: nil)
        }
        do {
            let inserted = try await store.insert(rows)
            for index in report.moved.indices { report.moved[index].logID = inserted[index].id }
        } catch {
            report.logFailed = !rows.isEmpty
            logger.error("Cleanup log write failed: \(error.localizedDescription, privacy: .private)")
        }
        logger.info(
            """
            Clean: moved \(report.moved.count, privacy: .public) (\(report.freedBytes, privacy: .public) bytes), \
            skipped \(report.skipped.count, privacy: .public)
            """)
        return report
    }

    /// Whether `path` (read as text only) lies in a folder guarded by Full Disk Access. Paths
    /// outside the home folder count as guarded here; they are refused later anyway.
    func needsAccess(_ path: String) -> Bool {
        let components = PathTools.components(path)
        guard !components.contains(".."), !components.contains(".") else { return true }
        let normalized = "/" + components.joined(separator: "/")
        guard PathTools.isStrictlyInside(normalized, root: home) else { return true }
        return FullDiskAccessPaths.requiresAccess("~" + normalized.dropFirst(home.count))
    }

    /// True when `path` still resolves to exactly itself and no component is a symbolic link.
    static func isUnchanged(_ path: String) -> Bool {
        guard let canonical = PathTools.canonical(path), canonical == path else { return false }
        var prefix = ""
        for component in PathTools.components(path) {
            prefix += "/" + component
            if linkState(prefix) != .present { return false }
        }
        return true
    }

    /// The pieces of `root` that can go when `excluded` paths inside it must stay: every child
    /// that is neither excluded nor holding an excluded path, descending into the ones that do.
    /// Links are left alone.
    static func movableParts(of root: String, excluding excluded: [String]) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var parts: [String] = []
        for name in names.sorted() {
            let path = root + "/" + name
            let key = path.lowercased()
            if excluded.contains(key) { continue }
            if excluded.contains(where: { PathTools.isStrictlyInside($0, root: key) }) {
                parts += movableParts(of: path, excluding: excluded)
            } else if linkState(path) == .present {
                parts.append(path)
            }
        }
        return parts
    }

    // MARK: - Undo

    /// Moves logged items back from the Trash, if they are still there and their old place is
    /// free. Marks the rows restored in one transaction.
    func undo(_ logIDs: [Int64]) async -> UndoReport {
        assertNotMainThread()
        var report = UndoReport()
        let rows: [CleanupLog]
        do {
            rows = try await store.logs(ids: logIDs)
        } catch {
            for id in logIDs { report.failed[id] = .notLogged }
            return report
        }
        let trashPath = try? validatedTrashPath()
        let found = Set(rows.compactMap(\.id))
        for id in logIDs where !found.contains(id) { report.failed[id] = .notLogged }

        for row in rows {
            guard let id = row.id else { continue }
            guard row.restoredAt == nil else { report.failed[id] = .alreadyRestored; continue }
            let trashed = URL(fileURLWithPath: row.trashPath)
            let original = URL(fileURLWithPath: row.originalPath)
            let trashedParent = PathTools.canonical(trashed.deletingLastPathComponent().path) ?? ""
            guard let trashPath, PathTools.isInside(trashedParent, root: trashPath),
                // Plain path (not `standardizedFileURL`, which drops a leading /private when the
                // file exists); `..` components are refused outright.
                !PathTools.components(row.originalPath).contains(".."),
                !PathTools.components(row.trashPath).contains(".."),
                let allowedRoots = restoreRoots(for: row),
                !protectedList.isProtectedPath(row.originalPath),
                // The deepest folder that exists on the way back must be a real (link-free)
                // folder inside home (or, for an uninstalled app, its app folder), so the move
                // can't be redirected through a link.
                let ancestor = Self.deepestExistingAncestor(of: row.originalPath),
                Self.isUnchanged(ancestor), allowedRoots.contains(where: { PathTools.isInside(ancestor, root: $0) }),
                // Inside-only: the home folder or ~/Library *contain* protected places, which is
                // fine for a parent we only put one item back into.
                !protectedList.isInsideProtectedRoot(ancestor)
            else { report.failed[id] = .unsafePath; continue }
            guard Self.linkState(trashed.path) != .missing else { report.failed[id] = .notInTrash; continue }
            guard Self.linkState(original.path) == .missing else { report.failed[id] = .originalTaken; continue }
            do {
                try trashMover.restore(trashed, to: original)
                report.restored.append(id)
            } catch {
                report.failed[id] = .moveFailed
            }
        }
        do {
            try await store.markRestored(report.restored, at: now())
        } catch {
            logger.error("Could not mark restored rows: \(error.localizedDescription, privacy: .private)")
        }
        logger.info(
            "Undo: restored \(report.restored.count, privacy: .public), failed \(report.failed.count, privacy: .public)"
        )
        return report
    }

    // MARK: - History

    /// Every log row, newest first, with where the item is now.
    func history() async throws -> [HistoryEntry] {
        assertNotMainThread()
        return try await store.logs().map { log in
            if let restored = log.restoredAt { return HistoryEntry(log: log, status: .restored(restored)) }
            if Self.linkState(log.trashPath) != .missing { return HistoryEntry(log: log, status: .inTrash) }
            let back = Self.linkState(log.originalPath) != .missing
            return HistoryEntry(log: log, status: back ? .backInPlace : .gone)
        }
    }

    // MARK: - Empty Trash

    /// The Trash folder (nonisolated: it never changes).
    nonisolated var trashDirectory: URL { trashMover.trashDirectory }

    /// What's in the Trash now, for the confirmation: each top-level entry is sorted into
    /// deletable or kept (`TrashAccess`). Needs Full Disk Access for the real Trash.
    func trashSummary() throws -> TrashSummary {
        assertNotMainThread()
        let directory = URL(fileURLWithPath: try validatedTrashPath(), isDirectory: true)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw DustpanError.trashUnreadable
        }
        var deletable: [String] = []
        var bytes: Int64 = 0
        var kept: [TrashLeftEntry] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            let size = Self.allocatedSize(of: url)
            if let reason = TrashAccess.blocker(of: url.path, inTrash: directory.path) {
                kept.append(TrashLeftEntry(name: name, bytes: size, reason: reason))
            } else {
                deletable.append(name)
                bytes += size
            }
        }
        return TrashSummary(names: deletable, bytes: bytes, kept: kept)
    }

    /// Bytes in the Trash that only Finder can delete (for the Trash tile's note).
    func trashKeptBytes() throws -> Int64 {
        assertNotMainThread()
        let directory = URL(fileURLWithPath: try validatedTrashPath(), isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(Int64(0)) { total, name in
            let url = directory.appendingPathComponent(name)
            guard TrashAccess.blocker(of: url.path, inTrash: directory.path) != nil else { return total }
            return total + Self.allocatedSize(of: url)
        }
    }

    /// **Permanently deletes** the deletable entries listed in `confirmed` from the Trash folder.
    /// Call it only after the user confirmed the size in the Empty Trash dialog. Each entry is
    /// checked again right before removal; one that can no longer be deleted whole is left
    /// untouched (never half-deleted) and reported, as are the entries the summary kept.
    @discardableResult
    func emptyTrash(_ confirmed: TrashSummary) throws -> EmptyTrashReport {
        assertNotMainThread()
        let directory = URL(fileURLWithPath: try validatedTrashPath(), isDirectory: true)
        var report = EmptyTrashReport()
        for name in confirmed.names {
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { continue }
            let url = directory.appendingPathComponent(name)
            // A link inside the Trash is removed itself; its target is never followed.
            guard Self.linkState(url.path) != .missing else { continue }
            let bytes = Self.allocatedSize(of: url)
            if let reason = TrashAccess.blocker(of: url.path, inTrash: directory.path) {
                report.left.append(TrashLeftEntry(name: name, bytes: bytes, reason: reason))
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                report.freedBytes += bytes
                report.deleted.append(name)
            } catch {
                let remaining = Self.linkState(url.path) == .missing ? 0 : Self.allocatedSize(of: url)
                report.freedBytes += bytes - remaining
                report.left.append(TrashLeftEntry(name: name, bytes: remaining, reason: .failed))
            }
        }
        for entry in confirmed.kept where Self.linkState(directory.appendingPathComponent(entry.name).path) != .missing
        {
            report.left.append(entry)
        }
        logger.info(
            """
            Empty Trash: freed \(report.freedBytes, privacy: .public) bytes, \
            \(report.left.count, privacy: .public) entries left
            """)
        return report
    }

    /// The trash folder's path, after making sure it is a real folder (not a link, no link on
    /// the way), isn't the home folder or above it, holds nothing protected, and — for the real
    /// Trash — is exactly `<home>/.Trash`.
    private func validatedTrashPath() throws -> String {
        let path = trashMover.trashDirectory.path
        guard Self.linkState(path) == .present, Self.isUnchanged(path),
            PathTools.components(path).count >= 2,
            !PathTools.isInside(home, root: path),
            !protectedList.isProtectedPath(path)
        else { throw DustpanError.trashUnreadable }
        if trashMover is FileManagerTrashMover, path.lowercased() != (home + "/.Trash").lowercased() {
            throw DustpanError.trashUnreadable
        }
        return path
    }

    /// The nearest existing path at or above `path` (by `lstat`), or nil.
    static func deepestExistingAncestor(of path: String) -> String? {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while current != "/" && !current.isEmpty {
            if linkState(current) != .missing { return current }
            current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
        return nil
    }

    // MARK: - File helpers

    enum LinkState: Sendable, Equatable { case missing, link, present }

    /// `lstat`: does the path exist, and is it itself a symbolic link?
    static func linkState(_ path: String) -> LinkState {
        assertNotMainThread()
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        return (info.st_mode & S_IFMT) == S_IFLNK ? .link : .present
    }

    /// Allocated bytes of a file or folder; links count 0 and are not followed.
    /// With `stopIfCancelled`, a walk in a cancelled task stops early (the partial total is then
    /// meaningless; scanners drop it). The Cleaner itself never stops early.
    static func allocatedSize(of url: URL, stopIfCancelled: Bool = false) -> Int64 {
        assertNotMainThread()
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        func size(_ v: URLResourceValues) -> Int64 { Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        guard values.isDirectory == true else { return size(values) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var visited = 0
        while let child = enumerator?.nextObject() as? URL {
            visited += 1
            if stopIfCancelled, visited % 1_000 == 0, Task.isCancelled { break }
            guard let v = try? child.resourceValues(forKeys: keys), v.isSymbolicLink != true, v.isDirectory != true
            else { continue }
            total += size(v)
        }
        return total
    }
}
