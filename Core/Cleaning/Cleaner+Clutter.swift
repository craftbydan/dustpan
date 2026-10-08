import Darwin
import Foundation

/// One duplicate the user chose to move, and the copy that stays.
struct DuplicateRemoval: Sendable, Equatable {
    /// The copy to move to the Trash.
    let url: URL
    /// The copy that stays (it must still exist, unchanged, and must not be moved itself).
    let keeper: URL
    /// The group's content hash (XXH3-64) and length, from the scan.
    let hash: UInt64
    let size: Int64
}

extension Cleaner {
    /// `ruleID`s written for clutter moves.
    static let largeOldRuleID = "user:largeold"
    static let duplicateRuleID = "user:duplicate"

    // MARK: - Large & old

    /// Moves big files the user ticked in Large & old to the Trash. Each one is checked from
    /// scratch (`checkClutterFile`): everything `trashUserChosen` checks, plus: a regular file
    /// (not a folder or link), not in `~/Library`, not inside a package or tool folder, not a
    /// cloud placeholder. Logged as `user:largeold`.
    func trashLargeFiles(_ urls: [URL]) async -> UninstallReport {
        assertNotMainThread()
        var report = UninstallReport()
        let never = await neverRulePaths()
        for url in Self.unique(urls) {
            switch checkClutterFile(url, neverPaths: never) {
            case .failure(let reason):
                report.skipped.append(.init(url: url, reason: reason))
            case .success(let checked):
                moveUnchanged(checked, into: &report)
            }
        }
        await log(&report, ruleID: Self.largeOldRuleID)
        logger.info(
            "Large & old: moved \(report.moved.count, privacy: .public), skipped \(report.skipped.count, privacy: .public)"
        )
        return report
    }

    // MARK: - Duplicates

    /// Moves duplicates to the Trash, never the last copy. For every removal, right before
    /// moving:
    /// - the file passes `checkClutterFile`;
    /// - its keeper is a different file, is not itself in this request (so a whole group can
    ///   never go, even if the caller asks), and passes the same checks;
    /// - the file and the keeper are read side by side and are byte-for-byte identical with the
    ///   group's hash and length from the scan; anything else is `contentChanged`.
    /// Logged as `user:duplicate`.
    func trashDuplicates(_ removals: [DuplicateRemoval]) async -> UninstallReport {
        assertNotMainThread()
        var report = UninstallReport()
        let targets = Set(removals.map { Self.key($0.url) })
        var done = Set<String>()
        let never = await neverRulePaths()
        for removal in removals {
            guard done.insert(Self.key(removal.url)).inserted else { continue }
            let skip = { (reason: SkipReason) in report.skipped.append(.init(url: removal.url, reason: reason)) }
            guard Self.key(removal.keeper) != Self.key(removal.url), !targets.contains(Self.key(removal.keeper)) else {
                skip(.lastCopy)
                continue
            }
            let file: CheckedFile
            switch checkClutterFile(removal.url, neverPaths: never) {
            case .failure(let reason): skip(reason); continue
            case .success(let checked): file = checked
            }
            guard case .success(let keeper) = checkClutterFile(removal.keeper, neverPaths: never),
                keeper.path != file.path
            else {
                skip(.keeperMissing)
                continue
            }
            guard !keeper.facts.isSameFile(as: file.facts) else { skip(.lastCopy); continue }
            guard file.facts.size == removal.size, keeper.facts.size == removal.size,
                FileContent.isIdentical(
                    file.path, file.facts, to: keeper.path, keeper.facts, expectedHash: removal.hash)
            else {
                skip(.contentChanged)
                continue
            }
            // The keeper must still be there, unchanged, when the copy goes.
            guard Self.isUnchanged(keeper.path),
                FileFacts.read(keeper.path).map({ $0.isSameFile(as: keeper.facts) })
                    == true
            else {
                skip(.keeperMissing)
                continue
            }
            moveUnchanged(file, into: &report)
        }
        await log(&report, ruleID: Self.duplicateRuleID)
        logger.info(
            "Duplicates: moved \(report.moved.count, privacy: .public), skipped \(report.skipped.count, privacy: .public)"
        )
        return report
    }

    // MARK: - Checks

    struct CheckedFile: Sendable {
        let path: String
        let facts: FileFacts
    }

    /// Every check for one clutter file. Returns its (resolved) path and `lstat` facts.
    func checkClutterFile(_ url: URL, neverPaths: [String]?) -> Result<CheckedFile, SkipReason> {
        // Text-only checks first: outside home, `~/Library`, guarded folders without access.
        let components = PathTools.components(url.path)
        guard url.path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else {
            return .failure(.outsideHome)
        }
        let normalized = "/" + components.joined(separator: "/")
        guard PathTools.isStrictlyInside(normalized, root: home) else { return .failure(.outsideHome) }
        if PathTools.isInside(normalized, root: home + "/Library") { return .failure(.homeFolder) }
        guard hasFullDiskAccess() || !FullDiskAccessPaths.isGuardedWithoutAccess(normalized, home: home) else {
            return .failure(.needsFullDiskAccess)
        }
        // Then everything the Space map's Move to Trash checks (links, protected places, apps,
        // Dustpan itself, the Trash, ownership).
        let path: String
        switch checkUserChosen(URL(fileURLWithPath: normalized), neverPaths: neverPaths) {
        case .failure(let reason): return .failure(reason)
        case .success(let resolved): path = resolved
        }
        guard let facts = FileFacts.read(path), facts.isRegularFile else { return .failure(.notAFile) }
        if ProtectedList.isDatabaseFile(URL(fileURLWithPath: path)) { return .failure(.protected) }
        // Safety rule 2: a file in a folder that holds an app database stays with it.
        if DatabaseFolderCheck(home: home, protectedList: protectedList).isInsideDatabaseFolder(path) {
            return .failure(.appDatabaseFolder)
        }
        if ClutterPaths.isInsidePackageOrToolFolder(path, root: home) { return .failure(.insidePackage) }
        if cloudStatus.isCloudOnly(URL(fileURLWithPath: path), facts: facts) { return .failure(.cloudOnly) }
        return .success(CheckedFile(path: path, facts: facts))
    }

    /// Re-reads the file with `lstat` right before the move: same inode, length and modification
    /// time as when it was checked (and compared), or it stays as `changedDuringClean`.
    private func moveUnchanged(_ file: CheckedFile, into report: inout UninstallReport) {
        guard let now = FileFacts.read(file.path), now.isUnchanged(since: file.facts) else {
            report.skipped.append(.init(url: URL(fileURLWithPath: file.path), reason: .changedDuringClean))
            return
        }
        moveChecked(file.path, bytes: file.facts.allocated, into: &report)
    }

    /// Text-only identity of a path (no disk access, so it's safe before the access guard).
    /// `checkClutterFile` refuses paths that differ from the one on disk, and the inode check
    /// catches a keeper reached through another name.
    private static func key(_ url: URL) -> String {
        ("/" + PathTools.components(url.path).joined(separator: "/")).lowercased()
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert(key($0)).inserted }
    }
}
