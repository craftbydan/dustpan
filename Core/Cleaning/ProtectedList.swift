import Darwin
import Foundation

/// Places Dustpan never scans into or acts on (CLAUDE.md safety rule 2). Checked by the
/// scanners and, from Prompt 5, by the Cleaner.
///
/// A path is protected when, after resolving symlinks, it
/// 1. is inside one of the protected roots below, or
/// 2. *contains* one of them (moving `~/Library` would move `~/Library/Mail`), or
/// 3. is an app database: a `.sqlite`, `.realm` or `.db` file, or a folder holding one,
///    unless it sits inside a `Caches` directory (any path component named `Caches`,
///    case-insensitive) or inside `~/.Trash`.
///
/// Rule 3 is checked on the item itself and everything inside it, not on its ancestors — except
/// that a single *file* whose own folder holds a database is protected too
/// (`isLooseFileBesideDatabase`). Picking things by hand (Space map, Clutter) also refuses
/// anything below a database folder (`DatabaseFolderCheck`).
/// `isProtected(_:)` walks the item at full depth but stops after `databaseSearchLimit` entries;
/// it **fails closed**: hitting the limit, or any folder it can't read, counts as protected.
/// Items inside `Caches` or the Trash skip the walk entirely. The junk scanner does the same
/// check for free during the size walk it already does (see `JunkScanner`).
struct ProtectedList: Sendable {
    /// Canonical (symlink-free) home folder.
    let home: String
    /// Every root, as absolute patterns (`*` allowed inside a component).
    let roots: [String]

    static let databaseExtensions: Set<String> = ["sqlite", "realm", "db"]
    /// Entries `isProtected` will look at before giving up and calling the item protected.
    let databaseSearchLimit: Int

    /// - Parameters:
    ///   - home: the user's home folder; tests pass a temp directory.
    ///   - allowMobileSync: true only when the iOS-backup rule is explicitly selected.
    ///   - databaseSearchLimit: entry budget for the app-database walk (tests lower it).
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, allowMobileSync: Bool = false,
        databaseSearchLimit: Int = 200_000
    ) {
        self.databaseSearchLimit = databaseSearchLimit
        let home = PathTools.canonical(home.path) ?? home.standardizedFileURL.path
        self.home = home
        var roots = [
            "/System", "/Library/Apple", "/usr", "/bin", "/sbin",
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/Mail",
            "\(home)/Pictures/*.photoslibrary",
            "\(home)/Library/Containers/com.apple.*",
            "\(home)/Library/Group Containers/*.com.apple.*",
            // Stricter than CLAUDE.md: real Apple group containers also use no prefix
            // (e.g. com.apple.Home.group). See PROGRESS.md → Deviations.
            "\(home)/Library/Group Containers/com.apple.*",
            "\(home)/Library/Keychains",
            // Stricter than CLAUDE.md: cloud-synced folders (iCloud Drive's File Provider
            // locations, Dropbox, Google Drive, OneDrive) hold placeholders and user files.
            "\(home)/Library/CloudStorage",
        ]
        if !allowMobileSync {
            roots.append("\(home)/Library/Application Support/MobileSync")
        }
        self.roots = roots
    }

    // MARK: - Full check (touches the disk)

    /// True when `url` must never be cleaned. Resolves symlinks first.
    func isProtected(_ url: URL) -> Bool {
        assertNotMainThread()
        let path = PathTools.canonical(url.path) ?? url.standardizedFileURL.path
        if isProtectedPath(path) { return true }
        guard databaseRuleApplies(to: path) else { return false }
        if isLooseFileBesideDatabase(path) { return true }
        return containsDatabase(at: URL(fileURLWithPath: path))
    }

    /// Rule 3 for single files (Prompt 11): a file (not a folder) whose own folder directly holds
    /// an app database is part of that app's data, e.g. `obsidian/old.log` next to
    /// `obsidian/store.sqlite`. Folders beside a database (an app's `Cache` folder) are judged on
    /// their own contents.
    func isLooseFileBesideDatabase(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { return false }
        let folder = (path as NSString).deletingLastPathComponent
        guard databaseRuleApplies(to: folder) else { return false }
        return Self.directlyHoldsDatabase(folder)
    }

    /// Whether `folder` itself (not its sub-folders) holds a `.sqlite`/`.realm`/`.db` file.
    /// Fails closed: a folder that can't be listed counts as holding one.
    static func directlyHoldsDatabase(_ folder: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return true }
        return names.contains { isDatabaseFile(URL(fileURLWithPath: $0)) }
    }

    // MARK: - Path-only checks (no disk access)

    /// Rule 1 only: `path` is a protected root or inside one.
    func isInsideProtectedRoot(_ path: String) -> Bool {
        let components = PathTools.components(path)
        return roots.contains { root in
            let rootComponents = PathTools.components(root)
            return components.count >= rootComponents.count
                && PathTools.matches(pattern: rootComponents, path: Array(components.prefix(rootComponents.count)))
        }
    }

    /// Rules 1 and 2 for an absolute, already-resolved path.
    func isProtectedPath(_ path: String) -> Bool {
        let components = PathTools.components(path)
        for root in roots {
            let rootComponents = PathTools.components(root)
            if components.count >= rootComponents.count {
                // Inside (or equal to) the root.
                if PathTools.matches(pattern: rootComponents, path: Array(components.prefix(rootComponents.count))) {
                    return true
                }
            } else if PathTools.matches(
                pattern: Array(rootComponents.prefix(components.count)), path: components)
            {
                // An ancestor of the root: acting on it would include the root.
                return true
            }
        }
        return false
    }

    /// Whether rule 3 (app databases) applies at this path.
    func databaseRuleApplies(to path: String) -> Bool {
        if PathTools.isInside(path, root: "\(home)/.Trash") { return false }
        return !PathTools.components(path).contains { $0.caseInsensitiveCompare("Caches") == .orderedSame }
    }

    static func isDatabaseFile(_ url: URL) -> Bool {
        databaseExtensions.contains(url.pathExtension.lowercased())
    }

    /// Database file at or under `url`? Fails closed: an unreadable entry, or more than
    /// `databaseSearchLimit` entries, answers true.
    private func containsDatabase(at url: URL) -> Bool {
        if Self.isDatabaseFile(url) { return true }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            // Vanished items are harmless; anything else we can't read is treated as protected.
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let errors = ErrorFlag()
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [], options: [],
                errorHandler: { _, _ in
                    errors.raise()
                    return true
                })
        else { return true }
        var seen = 0
        while let child = enumerator.nextObject() as? URL {
            seen += 1
            if seen > databaseSearchLimit || errors.raised { return true }
            if Self.isDatabaseFile(child) { return true }
        }
        return errors.raised
    }
}

/// Records that a `FileManager` enumerator hit an error. The error handler runs synchronously
/// on the enumerating thread, inside `nextObject()`.
final class ErrorFlag: @unchecked Sendable {
    private(set) var raised = false
    func raise() { raised = true }
}

/// Small path helpers shared by `ProtectedList`, `RuleCatalog` and `JunkScanner`.
enum PathTools {
    /// Symlink-free, case-correct absolute path (`realpath`), or nil when it doesn't exist.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func hasWildcard(_ component: String) -> Bool {
        component.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    /// Shell-style match of one name, case-insensitive (APFS default).
    static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        Darwin.fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }

    /// Component-wise match of equal-length arrays.
    static func matches(pattern: [String], path: [String]) -> Bool {
        guard pattern.count == path.count else { return false }
        return zip(pattern, path).allSatisfy { p, c in
            hasWildcard(p) ? fnmatch(p, c) : p.caseInsensitiveCompare(c) == .orderedSame
        }
    }

    /// `path` equals `root` or lies below it (case-insensitive).
    static func isInside(_ path: String, root: String) -> Bool {
        let p = path.lowercased()
        let r = root.lowercased()
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// Strictly below `root`.
    static func isStrictlyInside(_ path: String, root: String) -> Bool {
        isInside(path, root: root) && path.count != root.count
    }

    /// Replaces a leading `~` with `home`.
    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }
}
