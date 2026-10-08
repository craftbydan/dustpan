import Foundation

/// The Cleaner's independent answer to "is this path really what its rule finds?", worked out
/// from the catalogue with the junk scanner's own matcher (`JunkScanner.makePlan`), never from
/// what a `ScanItem` claims.
///
/// Only rules whose paths can overlap the paths being cleaned are matched (a rule root above,
/// at or inside one of them), so the Cleaner never lists folders it has no business reading
/// (and never touches places guarded by Full Disk Access for unrelated rules).
struct RuleMatcher: Sendable {
    private let scanner: JunkScanner
    private let protectedList: ProtectedList
    private let plan: JunkScanner.Plan
    /// Lowercased path → ID of the rule that wins that path. By ID, not index: the scanner drops
    /// rules that need Full Disk Access when it's off, so its indices don't match this list.
    private let winners: [String: String]

    /// - Parameter hasFullDiskAccess: the real access state; without it, rules that need access
    ///   are not matched at all (so their folders are never read), as in the scanner.
    init(
        catalog: [Rule], paths: [String], home: String, protectedList: ProtectedList, now: Date,
        hasFullDiskAccess: Bool
    ) async {
        self.protectedList = protectedList
        let targets = paths.map(PathTools.components)
        let rules = catalog.filter { rule in
            rule.paths.contains { raw in
                let pattern = PathTools.components(PathTools.expandTilde(raw, home: home))
                return targets.contains { Self.overlaps(pattern, $0) }
            }
        }
        scanner = JunkScanner(
            rules: rules, home: URL(fileURLWithPath: home, isDirectory: true), now: now, protectedList: protectedList,
            hasFullDiskAccess: hasFullDiskAccess)
        plan = await scanner.makePlan()
        winners = Dictionary(
            plan.items.map { ($0.path.lowercased(), $0.ruleID) }, uniquingKeysWith: { first, _ in first })
    }

    /// The ID of the rule that finds exactly `path` (symlink-free), or nil when no rule does:
    /// wrong root, no matching glob, an exclude glob, inside a `.never` place or a protected root.
    func winningRuleID(for path: String) -> String? {
        winners[path.lowercased()]
    }

    /// Paths strictly inside `path` that another rule or a `.never` rule owns.
    func exclusions(inside path: String) -> [String] {
        plan.exclusions(inside: path)
    }

    /// Newest change inside `path` leaving out `excluded`; nil when it holds an app database
    /// or can't be fully read (treat as protected).
    func newestChange(_ path: String, excluding excluded: Set<String>) async -> Date? {
        let checkDatabases = protectedList.databaseRuleApplies(to: path)
        let measured = await scanner.measure(path, excluding: excluded, checkDatabases: checkDatabases)
        // The measuring walk stops early in a cancelled task; a partial walk can't vouch for the age.
        if Task.isCancelled { return nil }
        return measured?.newest
    }

    /// One path pattern lies above, at or below the other (wildcards allowed in `pattern`).
    static func overlaps(_ pattern: [String], _ path: [String]) -> Bool {
        let n = min(pattern.count, path.count)
        return PathTools.matches(pattern: Array(pattern.prefix(n)), path: Array(path.prefix(n)))
    }
}
