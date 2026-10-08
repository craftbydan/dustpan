import Darwin
import Foundation
import os

/// Turns rules into explained, sized `ScanItem`s. Read-only: it never changes the disk.
///
/// How a scan works:
/// 0. **Access.** Without Full Disk Access, rules marked `needsFullDiskAccess` are not run at
///    all; they are listed in `skipped` so the UI can say which categories need access.
/// 1. **Match.** Each rule path (`~` → `home`, wildcards expanded) becomes a rule root, and
///    the root (no globs) or its matching children become candidates. Roots that resolve
///    through a symlink, or outside the home folder, are refused (safety rule 4); candidates
///    that are themselves symlinks are skipped, never followed.
/// 2. **Most specific rule wins.** When two rules find the same path, a `.never` rule wins;
///    otherwise the rule with the deeper root wins (`~/Library/Caches/Homebrew` beats
///    `~/Library/Caches/*`); then the more literal glob (`*.ShipIt` beats `*`); then `.review`
///    beats `.safe`; then catalogue order.
///    Anything inside a `.never` path is dropped. When one item lies inside another, the outer
///    item's size leaves the inner one out, so no byte is counted twice.
/// 3. **Protect.** Items in or containing a `ProtectedList` root are dropped. While measuring,
///    an item that holds a `.sqlite`/`.realm`/`.db` file (outside `Caches` and the Trash) is
///    dropped as an app database — full depth, as part of the same walk.
/// 4. **Measure.** Allocated size (`.totalFileAllocatedSizeKey`) of every regular file;
///    symlinks count 0 and are not followed. `modified` is the newest file inside.
/// 5. **Ignore.** Items the user ignored (by path or by rule) are left out of the results but
///    keep their claim, so an enclosing item still leaves them out (`excludedURLs`).
/// 6. **Filter and select.** Items younger than the rule's `minAgeDays` and empty items are
///    left out. `isSelected` only for `.safe` items untouched for 7 days (safety rule 3).
actor JunkScanner {
    /// Items modified more recently than this are never pre-selected.
    static let preselectMinimumAge: TimeInterval = 7 * 86_400

    private let rules: [Rule]
    private let home: String
    private let now: Date
    private let protectedList: ProtectedList
    /// Paths and rules the user chose to ignore. Their items are not reported, but they still
    /// claim their paths, so a broader rule never picks them up instead.
    private let ignore: IgnoreList
    private let logger = Logger(subsystem: "app.dustpan", category: "junk")

    private static let ignoredNames: Set<String> = [".ds_store", ".localized"]
    private static let resourceKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey,
        .isSymbolicLinkKey, .isRegularFileKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    /// Rules left out of this scan (e.g. they need Full Disk Access and the app doesn't have it).
    nonisolated let skipped: [SkippedRule]

    /// - Parameter hasFullDiskAccess: when false, rules with `needsFullDiskAccess` are not run
    ///   (so macOS never shows a prompt) and are listed in `skipped` instead.
    init(
        rules: [Rule], home: URL, now: Date = Date(), protectedList: ProtectedList? = nil,
        hasFullDiskAccess: Bool = true, ignore: IgnoreList = IgnoreList()
    ) {
        self.ignore = ignore
        let blocked = hasFullDiskAccess ? [] : rules.filter { $0.needsFullDiskAccess && $0.risk != .never }
        self.rules = hasFullDiskAccess ? rules : rules.compactMap(Self.withoutAccess)
        self.skipped = blocked.map {
            SkippedRule(ruleID: $0.id, title: $0.title, category: $0.category, reason: .needsFullDiskAccess)
        }
        self.home = PathTools.canonical(home.path) ?? home.standardizedFileURL.path
        self.now = now
        self.protectedList = protectedList ?? ProtectedList(home: home)
    }

    /// Runs the scan. Progress goes to `progress`, which is finished when the scan ends.
    func scan(progress: AsyncStream<ScanProgress>.Continuation? = nil) -> [ScanResult] {
        assertNotMainThread()
        defer { progress?.finish() }
        let started = Date()
        progress?.yield(ScanProgress(phase: .matching, completedItems: 0, totalItems: 0, bytesFound: 0))

        let plan = makePlan()
        var found: [JunkCategory: [ScanItem]] = [:]
        var durations: [JunkCategory: TimeInterval] = [:]
        var bytesFound: Int64 = 0
        var dropped = (protected: 0, young: 0, empty: 0, ignored: 0)

        for (index, candidate) in plan.items.enumerated() {
            if Task.isCancelled { break }
            let rule = rules[candidate.ruleIndex]
            if ignore.ignores(path: candidate.path, ruleID: rule.id) {
                dropped.ignored += 1
                progress?.yield(
                    ScanProgress(
                        phase: .measuring, completedItems: index + 1, totalItems: plan.items.count,
                        bytesFound: bytesFound))
                continue
            }
            let itemStart = Date()
            defer {
                durations[rule.category, default: 0] += Date().timeIntervalSince(itemStart)
                progress?.yield(
                    ScanProgress(
                        phase: .measuring, completedItems: index + 1, totalItems: plan.items.count,
                        bytesFound: bytesFound))
            }
            let checkDatabases = protectedList.databaseRuleApplies(to: candidate.path)
            let excluded = plan.exclusions(inside: candidate.path)
            guard
                let measured = measure(
                    candidate.path, excluding: Set(excluded.map { $0.lowercased() }), checkDatabases: checkDatabases)
            else {
                dropped.protected += 1
                continue
            }
            guard measured.bytes > 0 else {
                dropped.empty += 1
                continue
            }
            let minAge = TimeInterval(rule.minAgeDays) * 86_400
            if rule.minAgeDays > 0, measured.newest > now.addingTimeInterval(-minAge) {
                dropped.young += 1
                continue
            }
            let oldEnough = measured.newest <= now.addingTimeInterval(-Self.preselectMinimumAge)
            let item = ScanItem(
                id: UUID(), url: URL(fileURLWithPath: candidate.path), allocatedSize: measured.bytes,
                modified: measured.newest, category: rule.category, ruleID: rule.id, risk: rule.risk,
                isSelected: rule.risk == .safe && oldEnough && !rule.detectionOnly,
                detectionOnly: rule.detectionOnly,
                excludedURLs: excluded.sorted().map { URL(fileURLWithPath: $0) })
            found[rule.category, default: []].append(item)
            bytesFound += measured.bytes
        }

        let results = found.keys.sorted().map { category in
            let items = (found[category] ?? []).sorted {
                $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.url.path < $1.url.path
            }
            return ScanResult(
                category: category, items: items, totalBytes: items.reduce(0) { $0 + $1.allocatedSize },
                duration: durations[category] ?? 0)
        }
        progress?.yield(
            ScanProgress(
                phase: .finished, completedItems: plan.items.count, totalItems: plan.items.count,
                bytesFound: bytesFound))
        logger.info(
            """
            Junk scan: \(results.reduce(0) { $0 + $1.items.count }, privacy: .public) items, \
            \(bytesFound, privacy: .public) bytes in \(Date().timeIntervalSince(started), privacy: .public) s; \
            left out \(dropped.protected, privacy: .public) protected, \(dropped.young, privacy: .public) recent, \
            \(dropped.empty, privacy: .public) empty, \(dropped.ignored, privacy: .public) ignored
            """)
        return results
    }

    /// The rule as it runs without Full Disk Access: unchanged if it needs none, nil (skipped)
    /// if it does — except `.never` carve-outs, which keep their paths that need no access so
    /// they still protect what they cover (e.g. Spotify's offline music in `~/Library/Caches`).
    static func withoutAccess(_ rule: Rule) -> Rule? {
        guard rule.needsFullDiskAccess else { return rule }
        guard rule.risk == .never else { return nil }
        let paths = rule.paths.filter { !FullDiskAccessPaths.requiresAccess($0) }
        guard !paths.isEmpty else { return nil }
        return Rule(
            id: rule.id, title: rule.title, category: rule.category, paths: paths, globs: rule.globs,
            excludeGlobs: rule.excludeGlobs, minAgeDays: rule.minAgeDays, risk: rule.risk, why: rule.why,
            appBundleID: rule.appBundleID, requiresQuit: rule.requiresQuit, source: rule.source,
            detectionOnly: rule.detectionOnly, needsFullDiskAccess: false)
    }

    // MARK: - Matching

    struct Candidate: Sendable, Equatable {
        /// Index into this scanner's own (effective) rule list; only meaningful inside the scanner.
        let ruleIndex: Int
        /// The winning rule's ID. Anyone outside the scanner must use this, never `ruleIndex`:
        /// without Full Disk Access the scanner's rule list is shorter than the one it was given.
        let ruleID: String
        /// Canonical absolute path.
        let path: String
        /// Depth of the rule root that produced it; deeper roots are more specific.
        let specificity: Int
        /// Literal characters in the glob that matched (`*.ShipIt` beats `*`); `Int.max` when
        /// the root itself is the item.
        var globSpecificity: Int = .max
        let risk: Risk
    }

    struct Plan: Sendable {
        /// Items to measure, after precedence, `.never` and protection.
        let items: [Candidate]
        /// Every claimed path (items and `.never` paths) as (lowercased key, path), sorted by key.
        let claimed: [(key: String, path: String)]

        /// Claimed paths strictly inside `path`.
        func exclusions(inside path: String) -> [String] {
            let prefix = path.lowercased() + "/"
            var low = 0
            var high = claimed.count
            while low < high {
                let mid = (low + high) / 2
                if claimed[mid].key < prefix { low = mid + 1 } else { high = mid }
            }
            var result: [String] = []
            while low < claimed.count, claimed[low].key.hasPrefix(prefix) {
                result.append(claimed[low].path)
                low += 1
            }
            return result
        }
    }

    /// Matches every rule and resolves precedence. Exposed for tests.
    func makePlan() -> Plan {
        assertNotMainThread()
        var byPath: [String: Candidate] = [:]
        for (index, rule) in rules.enumerated() {
            for raw in rule.paths {
                for root in roots(for: PathTools.expandTilde(raw, home: home)) {
                    let depth = PathTools.components(root).count
                    if rule.globs.isEmpty {
                        guard PathTools.isStrictlyInside(root, root: home) else { continue }
                        offer(
                            Candidate(
                                ruleIndex: index, ruleID: rule.id, path: root, specificity: depth, risk: rule.risk),
                            to: &byPath)
                        continue
                    }
                    for name in children(of: root) {
                        guard let glob = Self.matchingGlob(name, rule: rule) else { continue }
                        let path = root + "/" + name
                        guard !isSymlink(path) else { continue }
                        offer(
                            Candidate(
                                ruleIndex: index, ruleID: rule.id, path: path, specificity: depth,
                                globSpecificity: glob.filter { !"*?[]".contains($0) }.count, risk: rule.risk),
                            to: &byPath)
                    }
                }
            }
        }

        let neverPaths = byPath.values.filter { $0.risk == .never }.map(\.path)
        let items = byPath.values
            .filter { candidate in
                candidate.risk != .never
                    && !neverPaths.contains { PathTools.isInside(candidate.path, root: $0) }
                    && !protectedList.isProtectedPath(candidate.path)
            }
            .sorted { $0.path < $1.path }
        let claimed = (items.map(\.path) + neverPaths).map { (key: $0.lowercased(), path: $0) }.sorted {
            $0.key < $1.key
        }
        return Plan(items: items, claimed: claimed)
    }

    private func offer(_ candidate: Candidate, to byPath: inout [String: Candidate]) {
        let key = candidate.path.lowercased()
        guard let existing = byPath[key] else {
            byPath[key] = candidate
            return
        }
        if Self.beats(candidate, existing) { byPath[key] = candidate }
    }

    /// Precedence between two rules that found the same path.
    static func beats(_ a: Candidate, _ b: Candidate) -> Bool {
        if (a.risk == .never) != (b.risk == .never) { return a.risk == .never }
        if a.specificity != b.specificity { return a.specificity > b.specificity }
        if a.globSpecificity != b.globSpecificity { return a.globSpecificity > b.globSpecificity }
        if a.risk != b.risk { return a.risk == .review }
        return a.ruleIndex < b.ruleIndex
    }

    /// The most specific of `rule.globs` matching `name`, unless an exclude glob matches.
    static func matchingGlob(_ name: String, rule: Rule) -> String? {
        guard !ignoredNames.contains(name.lowercased()),
            !rule.excludeGlobs.contains(where: { PathTools.fnmatch($0, name) })
        else { return nil }
        return rule.globs.filter { PathTools.fnmatch($0, name) }
            .max { $0.filter { !"*?[]".contains($0) }.count < $1.filter { !"*?[]".contains($0) }.count }
    }

    /// Expands wildcard components and returns canonical roots that exist, are the home folder
    /// or inside it, and are not reached through a symlink.
    private func roots(for expanded: String) -> [String] {
        var partials = [""]
        for component in PathTools.components(expanded) {
            if PathTools.hasWildcard(component) {
                partials = partials.flatMap { parent in
                    children(of: parent.isEmpty ? "/" : parent)
                        .filter { PathTools.fnmatch(component, $0) && !Self.ignoredNames.contains($0.lowercased()) }
                        .map { parent + "/" + $0 }
                }
            } else {
                partials = partials.map { $0 + "/" + component }
            }
            if partials.isEmpty { return [] }
        }
        return partials.compactMap { path in
            guard let canonical = PathTools.canonical(path),
                canonical.lowercased() == path.lowercased(),  // no symlink on the way
                PathTools.isInside(canonical, root: home)
            else { return nil }
            return canonical
        }
    }

    private func children(of path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    private func isSymlink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }  // vanished or unreadable: skip
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Measuring

    struct Measurement: Sendable, Equatable {
        let bytes: Int64
        let newest: Date
    }

    /// Allocated bytes and newest file date of `path`, leaving out `excluded` subtrees.
    /// With `checkDatabases`, returns nil (treat as protected) when the item holds an app
    /// database **or when any part of it can't be read** — an unreadable folder could hide one.
    func measure(_ path: String, excluding excluded: Set<String>, checkDatabases: Bool) -> Measurement? {
        assertNotMainThread()
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else {
            return Measurement(bytes: 0, newest: .distantPast)
        }
        if values.isSymbolicLink == true { return Measurement(bytes: 0, newest: .distantPast) }
        if values.isDirectory != true {
            if checkDatabases && ProtectedList.isDatabaseFile(url) { return nil }
            // A loose file beside an app database belongs to that app (safety rule 2).
            if checkDatabases && protectedList.isLooseFileBesideDatabase(path) { return nil }
            return Measurement(bytes: Self.allocated(values), newest: values.contentModificationDate ?? .distantPast)
        }

        var bytes: Int64 = 0
        var newestFile: Date?
        let errors = ErrorFlag()
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Self.resourceKeys, options: [],
                errorHandler: { _, _ in
                    errors.raise()
                    return true
                })
        else {
            if checkDatabases { return nil }
            return Measurement(bytes: 0, newest: values.contentModificationDate ?? .distantPast)
        }

        var visited = 0
        while let child = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 2_000 == 0, Task.isCancelled { break }
            let isExcluded = !excluded.isEmpty && excluded.contains(child.path.lowercased())
            guard let childValues = try? child.resourceValues(forKeys: Self.resourceKeySet) else {
                if isExcluded { continue }
                if checkDatabases { return nil }  // unreadable: can't rule out a database
                continue
            }
            if isExcluded {
                // Only a real folder has descendants to skip. Called on a file, `skipDescendants()`
                // carries over to the next folder the enumerator enters, whose files would then go
                // uncounted (and their dates unseen by the Cleaner's age check).
                if childValues.isDirectory == true, childValues.isSymbolicLink != true { enumerator.skipDescendants() }
                continue
            }
            guard childValues.isSymbolicLink != true, childValues.isDirectory != true else { continue }
            if checkDatabases && (ProtectedList.isDatabaseFile(child) || errors.raised) { return nil }
            bytes += Self.allocated(childValues)
            if let date = childValues.contentModificationDate, date > (newestFile ?? .distantPast) {
                newestFile = date
            }
        }
        if checkDatabases && errors.raised { return nil }
        return Measurement(bytes: bytes, newest: newestFile ?? values.contentModificationDate ?? .distantPast)
    }

    private static func allocated(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}

/// Everything one junk scan produced: what the Junk screen shows and what a Sweep's Junk tile adds up.
struct JunkScanOutput: Sendable {
    var results: [ScanResult] = []
    var rulesByID: [String: Rule] = [:]
    /// Rules not run (they need Full Disk Access).
    var skipped: [SkippedRule] = []
    var ignored: [IgnoreEntry] = []

    /// Allocated bytes of everything found. The Junk screen and the Sweep tile both use this.
    var totalBytes: Int64 { results.reduce(0) { $0 + $1.totalBytes } }

    /// What "Clean recommended" may move: `.safe`, pre-selected (old enough, safety rule 3), not
    /// detection-only. Never `.review` items, never anything that isn't junk.
    var recommendedItems: [ScanItem] { Self.recommended(results.flatMap(\.items)) }

    static func recommended(_ items: [ScanItem]) -> [ScanItem] {
        items.filter { $0.isSelected && $0.risk == .safe && !$0.detectionOnly }
    }
}

/// One junk scan with the catalogue's rules and the ignore list. Shared by the Junk screen and
/// the Sweep, so both find exactly the same things.
enum JunkScanRun {
    /// Runs off the main actor. `progress` is always finished when this returns or throws.
    @concurrent
    static func run(
        catalog: RuleCatalog, store: CleanupStore, home: URL, now: Date = Date(), hasFullDiskAccess: Bool,
        include: (@Sendable (Rule) -> Bool)? = nil, progress: AsyncStream<ScanProgress>.Continuation? = nil
    ) async throws -> JunkScanOutput {
        defer { progress?.finish() }
        var rules = try await catalog.rules()
        var output = JunkScanOutput()
        output.rulesByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let include { rules = rules.filter(include) }
        output.ignored = (try? await store.ignoreEntries()) ?? []
        let scanner = JunkScanner(
            rules: rules, home: home, now: now, hasFullDiskAccess: hasFullDiskAccess,
            ignore: IgnoreList(output.ignored))
        output.skipped = scanner.skipped
        output.results = await scanner.scan(progress: progress)
        return output
    }
}
