import Darwin
import Foundation

/// Where apps may be uninstalled from and how the Cleaner re-checks them. Injected so tests use
/// temp folders and fake signatures.
struct AppCleaningContext: Sendable {
    /// Folders apps may be removed from (`/Applications`, `~/Applications`).
    var appRoots: [URL]
    /// `/Library`: anything in it is listed only (needs the helper, later).
    var systemLibrary: URL
    var signing: any CodeSigningReading
    /// Installed apps right now (for "does another app own this?").
    var installedApps: @Sendable () async -> [AppIdentity]
    /// Whether macOS knows an app with this bundle ID (orphans must not be).
    var isKnownApp: @Sendable (String) -> Bool
    /// Where macOS has an app with this ID (outside the Trash), for leftover re-matching.
    var knownAppPath: @Sendable (String) -> String? = { _ in nil }

    static func standard(home: URL) -> AppCleaningContext {
        let roots = AppScanner.defaultRoots(home: home)
        let scanner = AppScanner(roots: roots, useSpotlight: true)
        return AppCleaningContext(
            appRoots: roots, systemLibrary: URL(fileURLWithPath: "/Library", isDirectory: true),
            signing: SecCodeSigningReader(), installedApps: { await scanner.identities() },
            isKnownApp: { LaunchServicesApps.isKnown($0) }, knownAppPath: { LaunchServicesApps.path(for: $0) })
    }
}

/// What an uninstall (or an orphan clean-up) did.
struct UninstallReport: Sendable, Equatable {
    struct Moved: Sendable, Equatable {
        let original: URL
        let trashed: URL
        let bytes: Int64
        /// The app bundle itself (not a leftover).
        let isApp: Bool
        var logID: Int64?
    }

    struct Skipped: Sendable, Equatable {
        let url: URL
        let reason: SkipReason
    }

    var moved: [Moved] = []
    var skipped: [Skipped] = []
    var logFailed = false

    var appRemoved: Bool { moved.contains(where: \.isApp) }
    var freedBytes: Int64 { moved.reduce(0) { $0 + $1.bytes } }
    var logIDs: [Int64] { moved.compactMap(\.logID) }
}

/// A bundle that passed every check, with facts read from disk (not from the caller).
struct VerifiedApp: Sendable {
    let path: String
    let identity: AppIdentity
}

extension Cleaner {
    // MARK: - Uninstall

    /// Moves `app`'s bundle and the given leftovers to the Trash, re-checking everything itself:
    /// - the bundle must be a real `.app` folder (no link anywhere on its path) directly in an app
    ///   folder or one level down, not inside another bundle or `/System`; its `Info.plist` ID
    ///   must equal `app.bundleID`; it must not be Apple's (ID or signature);
    /// - if the app is open, nothing is moved (the UI asks the user to quit it first);
    /// - each leftover must sit directly in one of the searched `~/Library` folders, be re-matched
    ///   by `LeftoverMatcher` against the bundle's own ID / team ID / name (another installed app's
    ///   folders never match), not be a link, not be protected (fails closed), be owned by the user
    ///   (root-owned and `/Library` items are listed only) and, without Full Disk Access, not be in
    ///   a guarded folder;
    /// - the bundle moves first; if it can't, its leftovers stay too.
    /// Every move is logged (`ruleID` `app:<bundleID>`) and can be put back.
    func uninstall(app: AppRecord, leftovers: [LeftoverMatch]) async -> UninstallReport {
        assertNotMainThread()
        var report = UninstallReport()
        let unique = Self.unique(leftovers)
        func skipAll(_ appReason: SkipReason, _ leftoverReason: SkipReason) {
            report.skipped.append(.init(url: app.url, reason: appReason))
            for leftover in unique { report.skipped.append(.init(url: leftover.url, reason: leftoverReason)) }
        }

        let verified: VerifiedApp
        switch verifyApp(app) {
        case .failure(let reason):
            skipAll(reason, .appNotRemoved)
            return report
        case .success(let app): verified = app
        }
        if let name = runningApps.runningAppName(bundleID: verified.identity.bundleID) {
            skipAll(.appRunning(name), .appRunning(name))
            return report
        }

        let installed = await appContext.installedApps()
        let others = installed.filter {
            (PathTools.canonical($0.url.path) ?? $0.url.path).lowercased() != verified.path.lowercased()
        }
        let access = hasFullDiskAccess()
        var approved: [(path: String, bytes: Int64)] = []
        for leftover in unique {
            switch checkLeftover(leftover, app: verified, others: others, access: access) {
            case .failure(let reason): report.skipped.append(.init(url: leftover.url, reason: reason))
            case .success(let path): approved.append((path, LeftoverMatcher.measure(leftover.url).bytes))
            }
        }

        // The bundle first, re-checked right before the move.
        let appURL = URL(fileURLWithPath: verified.path, isDirectory: true)
        guard Self.isUnchanged(verified.path), AppBundleInfo.read(appURL)?.bundleID == verified.identity.bundleID
        else {
            report.skipped.append(.init(url: appURL, reason: .changedDuringClean))
            for item in approved {
                report.skipped.append(.init(url: URL(fileURLWithPath: item.path), reason: .appNotRemoved))
            }
            return report
        }
        let appBytes = Self.allocatedSize(of: appURL)
        do {
            let trashed = try trashMover.trash(appURL)
            report.moved.append(.init(original: appURL, trashed: trashed, bytes: appBytes, isApp: true))
        } catch {
            report.skipped.append(.init(url: appURL, reason: .appMoveFailed))
            for item in approved {
                report.skipped.append(.init(url: URL(fileURLWithPath: item.path), reason: .appNotRemoved))
            }
            return report
        }

        for item in approved {
            moveChecked(item.path, bytes: item.bytes, into: &report)
        }
        await log(&report, ruleID: "app:\(verified.identity.bundleID)")
        logger.info(
            """
            Uninstall: moved \(report.moved.count, privacy: .public) (\(report.freedBytes, privacy: .public) bytes), \
            skipped \(report.skipped.count, privacy: .public)
            """)
        return report
    }

    // MARK: - Leftovers of an app removed outside Dustpan

    /// Moves leftovers of an app the user removed themselves (e.g. dragged to the Trash in Finder
    /// because it was installed for all users). The bundle can't be re-read, so instead:
    /// - nothing is at the app's old path any more (not even a link), the path was an app in an
    ///   allowed app folder, the ID isn't Apple's;
    /// - no installed app has that bundle ID, and LaunchServices doesn't find it at an existing
    ///   path outside the Trash;
    /// - each leftover passes the same checks as an uninstall's (direct child of a searched
    ///   `~/Library` folder, re-matched by `LeftoverMatcher` against the app's ID/team/name,
    ///   no link, not protected, user-owned, Full Disk Access respected).
    /// Logged as `app:<bundleID>`, undoable.
    func removeLeftovers(ofRemovedApp app: AppIdentity, leftovers: [LeftoverMatch]) async -> UninstallReport {
        assertNotMainThread()
        var report = UninstallReport()
        let unique = Self.unique(leftovers)
        func skipAll(_ reason: SkipReason) {
            for leftover in unique { report.skipped.append(.init(url: leftover.url, reason: reason)) }
        }
        let path = app.url.path
        let roots = appContext.appRoots.compactMap { PathTools.canonical($0.path) }
        guard !PathTools.components(path).contains(".."), AppScanner.isAcceptable(path, roots: roots),
            !AppScanner.isAppleBundleID(app.bundleID)
        else {
            skipAll(.notALeftover)
            return report
        }
        let installed = await appContext.installedApps()
        let stillKnown = appContext.knownAppPath(app.bundleID).map { Self.linkState($0) != .missing } ?? false
        guard Self.linkState(path) == .missing, !stillKnown,
            !installed.contains(where: { $0.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame })
        else {
            skipAll(.appStillInstalled)
            return report
        }
        let verified = VerifiedApp(path: path, identity: app)
        let access = hasFullDiskAccess()
        for leftover in unique {
            switch checkLeftover(leftover, app: verified, others: installed, access: access) {
            case .failure(let reason): report.skipped.append(.init(url: leftover.url, reason: reason))
            case .success(let found):
                moveChecked(found, bytes: LeftoverMatcher.measure(leftover.url).bytes, into: &report)
            }
        }
        await log(&report, ruleID: "app:\(app.bundleID)")
        logger.info(
            "Removed app's leftovers: moved \(report.moved.count, privacy: .public), skipped \(report.skipped.count, privacy: .public)"
        )
        return report
    }

    /// Re-checks an app bundle from scratch. Nothing from `app` is trusted except its path and ID.
    func verifyApp(_ app: AppRecord) -> Result<VerifiedApp, SkipReason> {
        let path = app.url.path
        let components = PathTools.components(path)
        guard !components.contains(".."), !components.contains("."), path.lowercased().hasSuffix(".app") else {
            return .failure(.notAnApp)
        }
        switch Self.linkState(path) {
        case .missing: return .failure(.notFound)
        case .link: return .failure(.isSymlink)
        case .present: break
        }
        var isDirectory: ObjCBool = false
        guard Self.isUnchanged(path), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return .failure(.notAnApp) }
        let roots = appContext.appRoots.compactMap { PathTools.canonical($0.path) }
        guard AppScanner.isAcceptable(path, roots: roots),
            let root = roots.first(where: { PathTools.isStrictlyInside(path, root: $0) }),
            PathTools.components(String(path.dropFirst(root.count))).count <= 2
        else { return .failure(.notAnApp) }
        guard !protectedList.isProtectedPath(path) else { return .failure(.protected) }
        guard let info = AppBundleInfo.read(app.url), info.bundleID == app.bundleID else {
            return .failure(.notAnApp)
        }
        // Dustpan can't remove the copy that's running (it would only quit itself).
        if Self.isDustpan(path: path, bundleID: info.bundleID, ownPaths: ownPaths) { return .failure(.dustpanItself) }
        guard !AppScanner.isAppleBundleID(info.bundleID) else { return .failure(.appleApp) }
        let signature = appContext.signing.signing(of: app.url)
        guard !signature.isApple else { return .failure(.appleApp) }
        return .success(
            VerifiedApp(
                path: path,
                identity: AppIdentity(bundleID: info.bundleID, teamID: signature.teamID, name: info.name, url: app.url))
        )
    }

    /// The running Dustpan: its own bundle (or one of `ownPaths`), or any copy with its bundle ID.
    static func isDustpan(
        path: String, bundleID: String, ownPaths: [String], runningBundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        if let runningBundleID, bundleID.caseInsensitiveCompare(runningBundleID) == .orderedSame { return true }
        let resolved = PathTools.canonical(path) ?? path
        return ownPaths.contains { PathTools.isInside(resolved, root: $0) || PathTools.isInside($0, root: resolved) }
    }

    /// Re-checks one leftover against the verified app. Returns its path when it may move.
    func checkLeftover(
        _ leftover: LeftoverMatch, app: VerifiedApp, others: [AppIdentity], access: Bool
    ) -> Result<String, SkipReason> {
        guard leftover.appBundleID.caseInsensitiveCompare(app.identity.bundleID) == .orderedSame else {
            return .failure(.notALeftover)
        }
        switch libraryEntry(leftover.url, access: access) {
        case .failure(let reason): return .failure(reason)
        case .success(let entry):
            guard !PathTools.isInside(entry.path, root: app.path) else { return .failure(.notALeftover) }
            guard
                LeftoverMatcher.match(
                    name: entry.name, inGroupContainers: entry.folder == "Group Containers", app: app.identity,
                    others: others, knownAppPath: appContext.knownAppPath) != nil
            else { return .failure(.notALeftover) }
            return .success(entry.path)
        }
    }

    // MARK: - Orphans

    /// Moves leftovers of deleted apps to the Trash after re-checking each: directly in a searched
    /// `~/Library` folder, named like a bundle ID that no installed app (or app known to macOS)
    /// has or shares a vendor with, not Apple's, unchanged for 30 days, not a link, not
    /// protected, owned by the user. Logged as `orphan:<id>`.
    func removeOrphans(_ orphans: [LeftoverMatch]) async -> UninstallReport {
        assertNotMainThread()
        var report = UninstallReport()
        let installed = await appContext.installedApps()
        let access = hasFullDiskAccess()
        let cutoff = now().addingTimeInterval(-LeftoverMatcher.orphanMinimumAge)
        for orphan in Self.unique(orphans) {
            let entry: LibraryEntry
            switch libraryEntry(orphan.url, access: access) {
            case .failure(let reason):
                report.skipped.append(.init(url: orphan.url, reason: reason))
                continue
            case .success(let found): entry = found
            }
            guard
                let id = LeftoverMatcher.orphanID(
                    name: entry.name, inGroupContainers: entry.folder == "Group Containers", installed: installed),
                !LeftoverMatcher.idChain(id).contains(where: appContext.isKnownApp)
            else {
                report.skipped.append(.init(url: orphan.url, reason: .notALeftover))
                continue
            }
            let measured = LeftoverMatcher.measure(URL(fileURLWithPath: entry.path))
            guard measured.newest <= cutoff else {
                report.skipped.append(.init(url: orphan.url, reason: .tooRecent))
                continue
            }
            var single = UninstallReport()
            moveChecked(entry.path, bytes: measured.bytes, into: &single)
            await log(&single, ruleID: "orphan:\(id)")
            report.moved += single.moved
            report.skipped += single.skipped
            report.logFailed = report.logFailed || single.logFailed
        }
        logger.info(
            "Orphans: moved \(report.moved.count, privacy: .public), skipped \(report.skipped.count, privacy: .public)")
        return report
    }

    // MARK: - Shared checks

    struct LibraryEntry {
        let path: String
        let name: String
        /// The `~/Library` folder it sits in ("Caches", "Group Containers", …).
        let folder: String
    }

    /// `url` must be a real, user-owned, unprotected entry directly inside one of the searched
    /// `~/Library` folders. `/Library` entries are refused as `needsHelper`.
    func libraryEntry(_ url: URL, access: Bool) -> Result<LibraryEntry, SkipReason> {
        let path = url.path
        let components = PathTools.components(path)
        guard !components.contains(".."), !components.contains("."), components.count >= 2 else {
            return .failure(.notALeftover)
        }
        let systemLibrary = PathTools.canonical(appContext.systemLibrary.path) ?? appContext.systemLibrary.path
        if PathTools.isInside(path, root: systemLibrary) || PathTools.isInside(path, root: "/Library") {
            return .failure(.needsHelper)
        }
        guard access || !needsAccess(path) else { return .failure(.needsFullDiskAccess) }
        let parent = url.deletingLastPathComponent().path
        guard
            let folder = LeftoverMatcher.userFolderNames.first(where: {
                parent.caseInsensitiveCompare("\(home)/Library/\($0)") == .orderedSame
            })
        else { return .failure(.notALeftover) }
        switch Self.linkState(path) {
        case .missing: return .failure(.notFound)
        case .link: return .failure(.isSymlink)
        case .present: break
        }
        guard Self.isUnchanged(path) else { return .failure(.leavesRuleRoot) }
        guard !protectedList.isProtected(url) else { return .failure(.protected) }
        guard LeftoverMatcher.isOwnedByCurrentUser(path) else { return .failure(.needsHelper) }
        return .success(LibraryEntry(path: path, name: url.lastPathComponent, folder: folder))
    }

    /// Moves `path` after a last check (no link on it, not protected).
    func moveChecked(_ path: String, bytes: Int64, into report: inout UninstallReport) {
        let url = URL(fileURLWithPath: path)
        guard Self.isUnchanged(path), !protectedList.isProtectedPath(path) else {
            report.skipped.append(.init(url: url, reason: .changedDuringClean))
            return
        }
        do {
            let trashed = try trashMover.trash(url)
            report.moved.append(.init(original: url, trashed: trashed, bytes: bytes, isApp: false))
        } catch {
            report.skipped.append(.init(url: url, reason: .moveFailed))
        }
    }

    /// Writes one log row per move, in one transaction.
    func log(_ report: inout UninstallReport, ruleID: String) async {
        let date = now()
        let rows = report.moved.map {
            CleanupLog(
                id: nil, date: date, originalPath: $0.original.path, trashPath: $0.trashed.path, bytes: $0.bytes,
                ruleID: ruleID, restoredAt: nil)
        }
        do {
            let inserted = try await store.insert(rows)
            for index in report.moved.indices { report.moved[index].logID = inserted[index].id }
        } catch {
            report.logFailed = !rows.isEmpty
            logger.error("Uninstall log write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func unique(_ leftovers: [LeftoverMatch]) -> [LeftoverMatch] {
        var seen = Set<String>()
        return leftovers.filter { seen.insert($0.url.path.lowercased()).inserted }
    }

    // MARK: - Undo support

    /// Folders a logged item may be put back into: the home folder, and — for an uninstalled app
    /// bundle (`app:` rows, a `.app` directly in an app folder) — that app folder. Nil = refuse.
    func restoreRoots(for row: CleanupLog) -> [String]? {
        if PathTools.isStrictlyInside(row.originalPath, root: home) { return [home] }
        guard row.ruleID?.hasPrefix("app:") == true, row.originalPath.lowercased().hasSuffix(".app") else {
            return nil
        }
        let roots = appContext.appRoots.compactMap { PathTools.canonical($0.path) }
        guard AppScanner.isAcceptable(row.originalPath, roots: roots),
            let root = roots.first(where: { PathTools.isStrictlyInside(row.originalPath, root: $0) })
        else { return nil }
        return [root]
    }
}
