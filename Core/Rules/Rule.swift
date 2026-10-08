import Foundation

/// What a junk item is. Raw values match `Tone` cases so views can colour by category.
enum JunkCategory: String, Codable, CaseIterable, Sendable, Comparable {
    case userCache, logs, savedState, dev, ai, installers, trash, xcode

    /// Plain display name.
    var title: String {
        switch self {
        case .userCache: "App caches"
        case .logs: "Logs"
        case .savedState: "Saved window state"
        case .dev: "Developer caches"
        case .ai: "AI & editor caches"
        case .installers: "Installers"
        case .trash: "Trash"
        case .xcode: "Xcode"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs) ?? 0 < allCases.firstIndex(of: rhs) ?? 0
    }
}

/// How safe something is to remove.
enum Risk: String, Codable, CaseIterable, Sendable {
    /// Rebuilt by its app; pre-selected when older than 7 days.
    case safe
    /// Shown, never pre-selected; the user decides.
    case review
    /// Never shown. Exists only to carve places out of broader rules (e.g. offline music).
    case never
}

/// One entry in `rules.json`.
///
/// Matching:
/// - Each string in `paths` is an absolute path starting with `~` (the user's home). Path
///   components may contain wildcards (`*`, `?`, `[...]`, matched case-insensitively), e.g.
///   `~/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches`. Each expanded path is
///   a **rule root**.
/// - `globs` empty: the root itself is one item.
/// - `globs` non-empty: every direct child of the root whose name matches one of `globs`
///   and none of `excludeGlobs` is an item.
/// - Items modified (newest file inside) within `minAgeDays` are left out.
///
/// Fields beyond CLAUDE.md's `Rule`: `title` (short display name) and `excludeGlobs`
/// (optional, default empty).
struct Rule: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let category: JunkCategory
    let paths: [String]
    let globs: [String]
    let excludeGlobs: [String]
    let minAgeDays: Int
    let risk: Risk
    /// Plain words, ≤ 140 characters, shown next to every item this rule finds.
    let why: String
    let appBundleID: String?
    let requiresQuit: Bool
    /// Where the path came from: "mac-cleanup-py", "PureMac" or "dustpan".
    let source: String
    /// Shown for information only, never pre-selected. **The Cleaner (Prompt 5) must refuse to
    /// move these items.** Used for Docker (prune inside Docker) and the Trash (emptied only via
    /// Empty Trash with confirmation). Must be `.review`. Extra to CLAUDE.md; default false.
    let detectionOnly: Bool
    /// The rule looks inside a folder macOS guards with Full Disk Access (the Trash, Downloads,
    /// Desktop, other apps' containers). Without access the scanner skips it and reports it as
    /// skipped. Validation requires it for every such path. Extra to CLAUDE.md; default false.
    let needsFullDiskAccess: Bool

    init(
        id: String, title: String, category: JunkCategory, paths: [String], globs: [String] = [],
        excludeGlobs: [String] = [], minAgeDays: Int = 0, risk: Risk, why: String,
        appBundleID: String? = nil, requiresQuit: Bool = false, source: String = "dustpan",
        detectionOnly: Bool = false, needsFullDiskAccess: Bool = false
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.paths = paths
        self.globs = globs
        self.excludeGlobs = excludeGlobs
        self.minAgeDays = minAgeDays
        self.risk = risk
        self.why = why
        self.appBundleID = appBundleID
        self.requiresQuit = requiresQuit
        self.source = source
        self.detectionOnly = detectionOnly
        self.needsFullDiskAccess = needsFullDiskAccess
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, category, paths, globs, excludeGlobs, minAgeDays, risk, why, appBundleID, requiresQuit
        case source, detectionOnly, needsFullDiskAccess
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        category = try c.decode(JunkCategory.self, forKey: .category)
        paths = try c.decode([String].self, forKey: .paths)
        globs = try c.decodeIfPresent([String].self, forKey: .globs) ?? []
        excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? []
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0
        risk = try c.decode(Risk.self, forKey: .risk)
        why = try c.decode(String.self, forKey: .why)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        requiresQuit = try c.decodeIfPresent(Bool.self, forKey: .requiresQuit) ?? false
        source = try c.decode(String.self, forKey: .source)
        detectionOnly = try c.decodeIfPresent(Bool.self, forKey: .detectionOnly) ?? false
        needsFullDiskAccess = try c.decodeIfPresent(Bool.self, forKey: .needsFullDiskAccess) ?? false
    }
}

/// One thing the scanner found.
struct ScanItem: Sendable, Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// Allocated bytes on disk (`.totalFileAllocatedSizeKey`), excluding anything a more
    /// specific rule claimed.
    let allocatedSize: Int64
    /// Newest modification date of the item or anything inside it.
    let modified: Date
    let category: JunkCategory
    let ruleID: String
    let risk: Risk
    var isSelected: Bool
    /// From a `detectionOnly` rule: never selected, and the Cleaner must refuse it.
    var detectionOnly: Bool = false
    /// Paths inside this item that belong to another rule (or must never be touched) and are
    /// not counted in `allocatedSize`. The Cleaner must leave them in place. Extra to CLAUDE.md.
    var excludedURLs: [URL] = []
}

/// Everything found in one category, biggest first.
struct ScanResult: Sendable, Equatable {
    let category: JunkCategory
    let items: [ScanItem]
    let totalBytes: Int64
    /// Time spent measuring this category's items.
    let duration: TimeInterval
}

/// A rule the scanner did not run, and why. Lets the UI say "3 categories need access".
struct SkippedRule: Sendable, Equatable {
    enum Reason: String, Sendable, Equatable {
        /// The rule needs Full Disk Access and the app doesn't have it.
        case needsFullDiskAccess
    }

    let ruleID: String
    let title: String
    let category: JunkCategory
    let reason: Reason
}

/// Progress of a running junk scan.
struct ScanProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case matching
        case measuring
        case finished
    }

    let phase: Phase
    let completedItems: Int
    let totalItems: Int
    let bytesFound: Int64

    var fraction: Double {
        guard totalItems > 0 else { return phase == .finished ? 1 : 0 }
        return Double(completedItems) / Double(totalItems)
    }
}
