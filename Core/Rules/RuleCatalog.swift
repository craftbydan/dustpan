import Foundation
import os

/// Loads and validates the bundled `rules.json`.
///
/// Validation (any failure rejects the whole catalogue):
/// - IDs are unique and non-empty; every rule has at least one path.
/// - Every path is `~` or starts with `~/` (user-home paths only; root-owned places wait for
///   the helper).
/// - `why` is non-empty and at most 140 characters; `title` is non-empty.
/// - No path, with `~` expanded, is in a `ProtectedList` root. A path without globs (the path
///   itself is the item) must not contain one either; with globs, each child is checked by the
///   scanner.
/// - `minAgeDays` is not negative.
/// - `detectionOnly` rules are `.review` (so they can never be pre-selected).
/// - A path inside a `FullDiskAccessPaths` root sets `needsFullDiskAccess`; only `.never` rules
///   may mix such paths with others.
actor RuleCatalog {
    static let maxWhyLength = 140

    private let bundle: Bundle
    private let protectedList: ProtectedList
    private var cached: [Rule]?
    private let logger = Logger(subsystem: "app.dustpan", category: "rules")

    init(bundle: Bundle = .main, protectedList: ProtectedList = ProtectedList()) {
        self.bundle = bundle
        self.protectedList = protectedList
    }

    /// The validated rules, loaded once.
    func rules() throws -> [Rule] {
        if let cached { return cached }
        guard let url = bundle.url(forResource: "rules", withExtension: "json") else {
            logger.error("rules.json is missing from the bundle")
            throw DustpanError.rulesInvalid("rules.json is missing")
        }
        do {
            let rules = try Self.decode(try Data(contentsOf: url), protectedList: protectedList)
            logger.info("Loaded \(rules.count, privacy: .public) rules")
            cached = rules
            return rules
        } catch {
            if case .rulesInvalid(let detail) = error as? DustpanError {
                logger.error("rules.json rejected: \(detail, privacy: .public)")
            }
            throw error
        }
    }

    /// Decodes and validates a catalogue. Pure: reads no files besides `data`.
    static func decode(_ data: Data, protectedList: ProtectedList) throws -> [Rule] {
        let rules: [Rule]
        do {
            rules = try JSONDecoder().decode([Rule].self, from: data)
        } catch {
            throw DustpanError.rulesInvalid("rules.json is not valid: \(error)")
        }
        try validate(rules, protectedList: protectedList)
        return rules
    }

    static func validate(_ rules: [Rule], protectedList: ProtectedList) throws {
        var seen = Set<String>()
        for rule in rules {
            func fail(_ reason: String) -> DustpanError { .rulesInvalid("\(rule.id): \(reason)") }
            if rule.id.isEmpty { throw fail("empty id") }
            if !seen.insert(rule.id).inserted { throw fail("duplicate id") }
            if rule.title.isEmpty { throw fail("empty title") }
            if rule.why.isEmpty { throw fail("empty why") }
            if rule.why.count > maxWhyLength { throw fail("why is longer than \(maxWhyLength) characters") }
            if rule.minAgeDays < 0 { throw fail("negative minAgeDays") }
            if rule.paths.isEmpty { throw fail("no paths") }
            if rule.requiresQuit && rule.appBundleID == nil { throw fail("requiresQuit without appBundleID") }
            if rule.detectionOnly && rule.risk != .review { throw fail("detectionOnly rules must be review") }
            // Skipping a rule without access must not drop coverage of places that need none,
            // so only `.never` rules (which stay active on their other paths) may mix the two.
            let accessPaths = rule.paths.filter(FullDiskAccessPaths.requiresAccess)
            if rule.risk != .never && !accessPaths.isEmpty && accessPaths.count != rule.paths.count {
                throw fail("mixes Full Disk Access paths with other paths; split the rule")
            }
            for path in rule.paths {
                guard path == "~" || path.hasPrefix("~/") else { throw fail("path must start with ~/") }
                if FullDiskAccessPaths.requiresAccess(path) && !rule.needsFullDiskAccess {
                    throw fail("path needs Full Disk Access; set needsFullDiskAccess")
                }
                if path.contains("/../") || path.hasSuffix("/..") { throw fail("path must not use ..") }
                let expanded = PathTools.expandTilde(path, home: protectedList.home)
                // Junk and the Space map agree on what is off limits without access: a rule reading a
                // folder the map won't open (e.g. `com.apple.*` caches, `~/Library/iTunes`) must set the flag.
                if !rule.needsFullDiskAccess && rule.risk != .never {
                    let library = (protectedList.home + "/Library").lowercased()
                    let guardedGlob =
                        PathTools.isInside(expanded.lowercased(), root: library)
                        && rule.globs.contains {
                            FullDiskAccessPaths.isGuardedInLibrary(name: $0, parent: "", library: library)
                        }
                    if FullDiskAccessPaths.isGuardedWithoutAccess(expanded, home: protectedList.home) || guardedGlob {
                        throw fail("reads a folder Dustpan opens only with Full Disk Access; set needsFullDiskAccess")
                    }
                }
                let protected =
                    rule.globs.isEmpty
                    ? protectedList.isProtectedPath(expanded) : protectedList.isInsideProtectedRoot(expanded)
                if protected { throw fail("path is protected") }
            }
        }
    }
}
