import Darwin
import Foundation

extension Cleaner {
    /// Folders directly in home that macOS and apps expect (lowercased). Never moved whole.
    static let standardHomeFolders: Set<String> = [
        "library", "documents", "desktop", "downloads", "movies", "music", "pictures", "public", "applications",
        "sites", ".trash", ".ssh", ".gnupg", ".config", ".local",
    ]

    /// The `ruleID` written for Space map moves.
    static let userChosenRuleID = "user:spacemap"

    /// Dustpan's app bundle and its database folder.
    static func defaultOwnPaths() -> [URL] {
        var paths = [Bundle.main.bundleURL]
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(support.appendingPathComponent("Dustpan", isDirectory: true))
        }
        return paths
    }

    // MARK: - Space map

    /// Moves one file or folder the user picked on the Space map to the Trash, after checking it
    /// from scratch (fails closed). Refused:
    /// - the home folder, its standard folders (`~/Library`, `~/Documents`, …, `~/.ssh`) and the
    ///   folders directly in `~/Library`;
    /// - anything outside the home folder (root-owned or system places are never moved) or not
    ///   owned by the user;
    /// - without Full Disk Access, anything in a guarded folder (checked before any `lstat`);
    /// - links, or a path with a link anywhere on it (re-checked right before the move);
    /// - ProtectedList places, including folders holding an app database (`isProtected`), and
    ///   anything inside a folder that directly holds one (`appDatabaseFolder`);
    /// - places a `.never` rule covers, or folders holding one (`neverTouched`);
    /// - anything inside an app bundle, and Apple app bundles;
    /// - Dustpan itself and its history database; the Trash and anything in it.
    /// Logged as `user:spacemap`, so History can put it back. `knownBytes` (the Space map's own
    /// measurement) is only used for the log and the result line.
    func trashUserChosen(_ url: URL, knownBytes: Int64? = nil) async -> UninstallReport {
        assertNotMainThread()
        var report = UninstallReport()
        switch checkUserChosen(url, neverPaths: await neverRulePaths()) {
        case .failure(let reason):
            report.skipped.append(.init(url: url, reason: reason))
        case .success(let path):
            let bytes = knownBytes ?? Self.allocatedSize(of: URL(fileURLWithPath: path))
            moveChecked(path, bytes: bytes, into: &report)
            await log(&report, ruleID: Self.userChosenRuleID)
        }
        logger.info(
            "Space map: moved \(report.moved.count, privacy: .public), skipped \(report.skipped.count, privacy: .public)"
        )
        return report
    }

    /// Runs every `trashUserChosen` check on `url` without moving anything. Nil = it may go.
    /// The Space map asks this before showing its confirmation; `trashUserChosen` checks again.
    func canTrashUserChosen(_ url: URL) async -> SkipReason? {
        await precheckUserChosen([url]).first?.reason
    }

    /// `canTrashUserChosen` for several items, plus the open app for a running `.app` bundle.
    func precheckUserChosen(_ urls: [URL]) async -> [UserChosenVerdict] {
        assertNotMainThread()
        let neverPaths = await neverRulePaths()
        return urls.map { url in
            switch checkUserChosen(url, neverPaths: neverPaths) {
            case .success: return UserChosenVerdict(url: url, reason: nil, blockingApp: nil)
            case .failure(let reason):
                var app: BlockingApp?
                if case .appRunning(let name) = reason, let id = AppBundleInfo.read(url)?.bundleID {
                    app = BlockingApp(bundleID: id, name: name)
                }
                return UserChosenVerdict(url: url, reason: reason, blockingApp: app)
            }
        }
    }

    /// Every check for `trashUserChosen`. Returns the path to move.
    /// `neverPaths`: from `neverRulePaths()`; nil (the catalogue didn't load) refuses everything.
    func checkUserChosen(_ url: URL, neverPaths: [String]?) -> Result<String, SkipReason> {
        let path = url.path
        let components = PathTools.components(path)
        guard path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else {
            return .failure(.outsideHome)
        }
        let normalized = "/" + components.joined(separator: "/")
        if normalized.caseInsensitiveCompare(home) == .orderedSame { return .failure(.homeFolder) }
        guard PathTools.isStrictlyInside(normalized, root: home) else { return .failure(.outsideHome) }
        // `.never` places first (text only), so they get their own reason even where another
        // refusal would also apply (e.g. `~/Library/Autosave Information`).
        guard let neverPaths else { return .failure(.unknownRule) }
        if Self.touchesNeverPath(normalized, neverPaths) { return .failure(.neverTouched) }
        // Without access, never touch a guarded folder (the same folders the Space map doesn't
        // open), not even with lstat.
        guard
            hasFullDiskAccess()
                || (!needsAccess(normalized) && !FullDiskAccessPaths.isGuardedWithoutAccess(normalized, home: home))
        else { return .failure(.needsFullDiskAccess) }

        switch Self.linkState(normalized) {
        case .missing: return .failure(.notFound)
        case .link: return .failure(.isSymlink)
        case .present: break
        }
        // A link anywhere on the way is refused as a link; a path that only differs from the one
        // on disk (e.g. in capitals) gets its own reason.
        var prefix = ""
        for component in PathTools.components(normalized) {
            prefix += "/" + component
            if Self.linkState(prefix) == .link { return .failure(.isSymlink) }
        }
        guard let resolved = PathTools.canonical(normalized) else { return .failure(.notFound) }
        guard resolved == normalized, Self.isUnchanged(normalized) else { return .failure(.pathMismatch) }
        guard PathTools.isStrictlyInside(resolved, root: home) else { return .failure(.outsideHome) }

        let relative = PathTools.components(String(resolved.dropFirst(home.count)))
        if relative.count == 1, Self.standardHomeFolders.contains(relative[0].lowercased()) {
            return .failure(.homeFolder)
        }
        if relative.count == 2, relative[0].lowercased() == "library" { return .failure(.homeFolder) }

        let trash = trashMover.trashDirectory.path
        let trashPath = PathTools.canonical(trash) ?? trash
        if PathTools.isInside(resolved, root: trashPath) || PathTools.isInside(trashPath, root: resolved)
            || PathTools.isInside(resolved, root: home + "/.Trash")
        {
            return .failure(.alreadyInTrash)
        }
        if ownPaths.contains(where: { PathTools.isInside(resolved, root: $0) || PathTools.isInside($0, root: resolved) }
        ) {
            return .failure(.dustpanItself)
        }

        if let appIndex = relative.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
            guard appIndex == relative.count - 1 else { return .failure(.insideApp) }
            let appURL = URL(fileURLWithPath: resolved, isDirectory: true)
            if let info = AppBundleInfo.read(appURL), AppScanner.isAppleBundleID(info.bundleID) {
                return .failure(.appleApp)
            }
            if appContext.signing.signing(of: appURL).isApple { return .failure(.appleApp) }
            // An open app is never moved; the Space map offers to quit it first.
            if let id = AppBundleInfo.read(appURL)?.bundleID, let name = runningApps.runningAppName(bundleID: id) {
                return .failure(.appRunning(name))
            }
        }

        if let reason = containedAppRefusal(resolved) { return .failure(reason) }

        if Self.touchesNeverPath(resolved, neverPaths) { return .failure(.neverTouched) }
        // Anything below a folder that holds an app database is that app's data (safety rule 2).
        // Checked before `isProtected` so the reason names it.
        if DatabaseFolderCheck(home: home, protectedList: protectedList).isInsideDatabaseFolder(resolved) {
            return .failure(.appDatabaseFolder)
        }
        if protectedList.isLooseFileBesideDatabase(resolved) { return .failure(.appDatabaseFolder) }
        guard !protectedList.isProtected(URL(fileURLWithPath: resolved)) else { return .failure(.protected) }
        guard LeftoverMatcher.isOwnedByCurrentUser(resolved) else { return .failure(.needsHelper) }
        return .success(resolved)
    }

    /// Every `.never` rule path (`~` expanded, wildcards kept), or nil when the catalogue
    /// didn't load. The junk scanner already leaves these out; the Space map and Clutter refuse
    /// them too, so unsaved documents or downloaded models can't be picked by hand.
    func neverRulePaths() async -> [String]? {
        guard let catalog = try? await rules() else { return nil }
        return catalog.filter { $0.risk == .never }.flatMap(\.paths).map { PathTools.expandTilde($0, home: home) }
    }

    /// `path` is at, inside, or above one of `neverPaths` (component-wise, case-insensitive).
    static func touchesNeverPath(_ path: String, _ neverPaths: [String]) -> Bool {
        let components = PathTools.components(path)
        return neverPaths.contains { never in
            let pattern = PathTools.components(never)
            let n = min(pattern.count, components.count)
            return PathTools.matches(pattern: Array(pattern.prefix(n)), path: Array(components.prefix(n)))
        }
    }

    /// A folder holding (up to two levels down) an Apple app or a copy of Dustpan is refused too.
    /// Links are not followed.
    func containedAppRefusal(_ folder: String) -> SkipReason? {
        var isDirectory: ObjCBool = false
        guard Self.linkState(folder) == .present,
            FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        var level = [folder]
        for _ in 0..<2 {
            var next: [String] = []
            for directory in level {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                for name in names {
                    let path = directory + "/" + name
                    guard Self.linkState(path) == .present else { continue }
                    var childIsDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &childIsDirectory),
                        childIsDirectory.boolValue
                    else { continue }
                    if name.lowercased().hasSuffix(".app") {
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        let bundleID = AppBundleInfo.read(url)?.bundleID ?? ""
                        if bundleID.lowercased().hasPrefix("app.dustpan.") { return .dustpanItself }
                        if AppScanner.isAppleBundleID(bundleID) || appContext.signing.signing(of: url).isApple {
                            return .appleApp
                        }
                    } else {
                        next.append(path)
                    }
                }
            }
            level = next
        }
        return nil
    }
}

/// What `precheckUserChosen` found for one item: nil `reason` = it may go to the Trash.
struct UserChosenVerdict: Sendable, Equatable {
    let url: URL
    let reason: SkipReason?
    /// For an open app bundle: the app, so the UI can offer to quit it.
    let blockingApp: BlockingApp?
}
