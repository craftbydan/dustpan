import AppKit
import Darwin
import Foundation

/// Why a file was matched to an app. Ordered from most to least certain.
enum LeftoverReason: String, Sendable, Codable, Hashable {
    /// The name is the app's bundle ID (`com.figma.Desktop`, `com.figma.Desktop.plist`).
    case bundleID
    /// The name starts with the app's bundle ID (`com.figma.Desktop.ShipIt`).
    case bundleIDPrefix
    /// A group container that starts with the app's team ID.
    case teamID
    /// The name contains the app's name as whole words.
    case nameToken
    /// From an installer receipt (`pkgutil`). Not used yet (v1).
    case receipt
}

enum MatchConfidence: Int, Sendable, Codable, Comparable, Hashable {
    case low = 0, medium, high
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether Dustpan can move a match.
enum LeftoverStatus: String, Sendable, Codable, Hashable {
    case removable
    /// In `/Library` or owned by another user: listed only ("needs helper — coming later").
    case needsHelper
    /// Holds an app database (or couldn't be fully read): protected, listed only.
    case holdsDatabase

    var explanation: String? {
        switch self {
        case .removable: nil
        case .needsHelper: "Owned by the system. Removing it needs a helper, coming in a later version."
        case .holdsDatabase: "Holds an app database, which Dustpan never removes. You can check it in Finder."
        }
    }
}

/// One Library folder that leftovers are looked for in.
struct LibraryFolder: Sendable, Hashable {
    let title: String
    let path: String
    /// `/Library/…`: listed only, never moved.
    let isSystem: Bool
    /// Guarded by Full Disk Access; skipped (never read) without it.
    let needsFullDiskAccess: Bool
}

/// A file or folder that belongs to an app (or, for orphans, to an app that's gone).
struct LeftoverMatch: Sendable, Identifiable, Hashable {
    /// The app's bundle ID; for orphans, the ID the name points to.
    let appBundleID: String
    let url: URL
    let reason: LeftoverReason
    let confidence: MatchConfidence
    /// Plain words: why Dustpan thinks this belongs to the app.
    let explanation: String
    /// The Library folder it was found in ("Caches", "Preferences", …).
    let folderTitle: String
    let size: Int64
    /// Newest change anywhere inside.
    let modified: Date
    let status: LeftoverStatus

    var id: String { url.path }
    var isRemovable: Bool { status == .removable }
    /// Ticked at first: only removable, medium- or high-confidence app leftovers. Low-confidence
    /// matches and orphans (guesses) start unticked.
    var isSelectedByDefault: Bool { isRemovable && confidence >= .medium }
}

/// What a leftover or orphan search found, and which folders it couldn't look in.
struct LeftoverScan: Sendable, Equatable {
    var matches: [LeftoverMatch] = []
    /// Titles of folders skipped because Full Disk Access is off.
    var skippedFolders: [String] = []

    /// Matches Dustpan can move (listing-only ones left out).
    var removable: [LeftoverMatch] { matches.filter(\.isRemovable) }
    /// Their total size. The Leftovers tab and the Sweep tile both use this.
    var removableBytes: Int64 { removable.reduce(0) { $0 + $1.size } }
}

/// Finds an app's leftovers in the Library folders, and leftovers of apps that are gone.
///
/// Matching, most certain first: exact bundle ID → bundle ID prefix → team ID (group containers
/// only) → the app's name as whole words (≥ 4 characters, generic words ignored). A name that
/// belongs to another installed app (its ID, or a longer ID prefix) is never this app's. Apple
/// names, protected places and links are never returned. Read-only.
struct LeftoverMatcher: Sendable {
    /// Canonical home folder.
    let home: String
    let systemLibrary: String
    let protectedList: ProtectedList
    let hasFullDiskAccess: Bool
    let now: Date
    /// Where macOS (LaunchServices) has an app with this bundle ID, outside the Trash; nil if
    /// none. Catches apps installed outside the app folders. Tests pass a fake.
    let knownAppPath: @Sendable (String) -> String?

    /// Orphans must be at least this old.
    static let orphanMinimumAge: TimeInterval = 30 * 86_400

    /// `~/Library/<name>` folders searched, in display order.
    static let userFolderNames = [
        "Application Support", "Caches", "Preferences", "Containers", "Group Containers",
        "Saved Application State", "HTTPStorages", "WebKit", "Logs", "LaunchAgents", "Cookies",
    ]
    /// `/Library/<name>` folders listed (never moved).
    static let systemFolderNames = ["LaunchAgents", "LaunchDaemons", "Application Support", "Preferences"]

    /// Words too common to tie a folder to an app.
    static let genericWords: Set<String> = [
        "app", "apps", "application", "applications", "helper", "helpers", "mac", "macos", "osx", "update",
        "updater", "updates", "apple", "agent", "service", "services", "support", "data", "cache", "caches",
        "files", "file", "settings", "preferences", "prefs", "desktop", "client", "launcher", "installer",
        "install", "uninstaller", "tool", "tools", "manager", "editor", "player", "viewer", "browser", "studio",
        "free", "lite", "plus", "online", "cloud", "sync", "shared", "group", "default", "user", "users",
        "library", "logs", "home", "pro", "beta", "edition", "community", "google", "microsoft", "adobe",
        "with", "from", "your", "this", "that", "web", "plugin", "plugins", "extension", "extensions",
    ]

    init(
        home: URL, systemLibrary: URL = URL(fileURLWithPath: "/Library", isDirectory: true),
        protectedList: ProtectedList? = nil, hasFullDiskAccess: Bool, now: Date = Date(),
        knownAppPath: @escaping @Sendable (String) -> String? = { LaunchServicesApps.path(for: $0) }
    ) {
        self.knownAppPath = knownAppPath
        self.home = PathTools.canonical(home.path) ?? home.standardizedFileURL.path
        self.systemLibrary = PathTools.canonical(systemLibrary.path) ?? systemLibrary.path
        self.protectedList = protectedList ?? ProtectedList(home: home)
        self.hasFullDiskAccess = hasFullDiskAccess
        self.now = now
    }

    var userFolders: [LibraryFolder] {
        Self.userFolderNames.map { name in
            LibraryFolder(
                title: name, path: "\(home)/Library/\(name)", isSystem: false,
                needsFullDiskAccess: FullDiskAccessPaths.requiresAccess("~/Library/\(name)"))
        }
    }

    var systemFolders: [LibraryFolder] {
        Self.systemFolderNames.map {
            LibraryFolder(title: $0, path: "\(systemLibrary)/\($0)", isSystem: true, needsFullDiskAccess: false)
        }
    }

    // MARK: - Leftovers of an installed app

    func leftovers(for app: AppIdentity, installed: [AppIdentity]) -> LeftoverScan {
        assertNotMainThread()
        var scan = LeftoverScan()
        let others = installed.filter { $0.url.standardizedFileURL != app.url.standardizedFileURL }
        let appPath = PathTools.canonical(app.url.path) ?? app.url.path
        for folder in userFolders + systemFolders {
            if folder.needsFullDiskAccess && !hasFullDiskAccess {
                scan.skippedFolders.append(folder.title)
                continue
            }
            for name in Self.children(folder.path) {
                guard
                    let match = Self.match(
                        name: name, inGroupContainers: folder.title == "Group Containers", app: app, others: others,
                        knownAppPath: knownAppPath)
                else { continue }
                let path = folder.path + "/" + name
                guard !PathTools.isInside(path, root: appPath),
                    let found = describe(
                        path: path, folder: folder, bundleID: app.bundleID, reason: match.reason,
                        confidence: match.confidence, explanation: match.explanation)
                else { continue }
                scan.matches.append(found)
            }
        }
        scan.matches.sort { ($0.confidence, $0.size) > ($1.confidence, $1.size) }
        return scan
    }

    // MARK: - Orphans

    /// Library entries named like a bundle ID (`com.x.y`) that no installed app owns, no app known
    /// to macOS has, older than 30 days and not protected. Only the user's Library is searched.
    func orphans(installed: [AppIdentity], isKnownApp: (String) -> Bool) -> LeftoverScan {
        assertNotMainThread()
        var scan = LeftoverScan()
        for folder in userFolders {
            if Task.isCancelled { break }
            if folder.needsFullDiskAccess && !hasFullDiskAccess {
                scan.skippedFolders.append(folder.title)
                continue
            }
            for name in Self.children(folder.path) {
                if Task.isCancelled { break }
                guard
                    let id = Self.orphanID(
                        name: name, inGroupContainers: folder.title == "Group Containers", installed: installed),
                    !Self.idChain(id).contains(where: isKnownApp)
                else { continue }
                let path = folder.path + "/" + name
                guard
                    let found = describe(
                        path: path, folder: folder, bundleID: id, reason: .bundleID, confidence: .low,
                        explanation: "")
                else { continue }
                guard found.modified <= now.addingTimeInterval(-Self.orphanMinimumAge) else { continue }
                let months = max(1, Int(now.timeIntervalSince(found.modified) / (30 * 86_400)))
                let age = months == 1 ? "a month" : "\(months) months"
                scan.matches.append(
                    LeftoverMatch(
                        appBundleID: id, url: found.url, reason: .bundleID, confidence: .low,
                        explanation: "No app on this Mac has the ID \(id). Unchanged for \(age).",
                        folderTitle: folder.title, size: found.size, modified: found.modified, status: found.status))
            }
        }
        // Removable first (listing-only ones are for information), then largest.
        scan.matches.sort { ($0.isRemovable ? 1 : 0, $0.size) > ($1.isRemovable ? 1 : 0, $1.size) }
        return scan
    }

    /// Who is installed, then the orphan search, off the main actor. Shared by the Leftovers tab
    /// and the Sweep, so both find the same things.
    @concurrent
    static func findOrphans(
        scanner: AppScanner, matcher: LeftoverMatcher, isKnownApp: @escaping @Sendable (String) -> Bool
    ) async -> LeftoverScan {
        let identities = await scanner.identities()
        return matcher.orphans(installed: identities, isKnownApp: isKnownApp)
    }

    /// The bundle ID an orphan candidate is named after, or nil when it isn't one, is Apple's, or
    /// belongs to (or shares a vendor with) an installed app.
    static func orphanID(name: String, inGroupContainers: Bool, installed: [AppIdentity]) -> String? {
        let id = idPart(of: strippedName(name), inGroupContainers: inGroupContainers).id
        guard looksLikeBundleID(id), !isAppleName(id), !isAppleName(name), !isToolingName(id) else { return nil }
        let lower = id.lowercased()
        let vendor = vendorPrefix(lower)
        let entryTokens = Set(tokens(id))
        for app in installed {
            let bid = app.bundleID.lowercased()
            if lower == bid || lower.hasPrefix(bid + ".") || bid.hasPrefix(lower + ".") { return nil }
            if vendorPrefix(bid) == vendor { return nil }
            // Named after an installed app (`LINE.VideoPreviewService.0` while LINE is installed):
            // likely one of its extensions or helpers.
            let appTokens = significantTokens(app.name)
            if !appTokens.isEmpty, appTokens.isSubset(of: entryTokens) { return nil }
        }
        return id
    }

    /// The ID and its parents down to three parts (`a.b.c.Helper.x` → `…Helper.x`, `…Helper`,
    /// `a.b.c`), so an extension's parent app counts as known.
    static func idChain(_ id: String) -> [String] {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count > 3 else { return [id] }
        return (3...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }

    /// Prefixes of macOS's own data (Apple, Shortcuts, CUPS printing, system groups). Never
    /// leftovers, never orphans.
    static let systemPrefixes = [
        "com.apple.", "group.com.apple.", "systemgroup.com.apple.", "is.workflow.", "group.is.workflow.",
        "org.cups.", "apple.", "group.apple.",
    ]

    /// Developer tools and libraries that keep Library files but aren't apps (removing them can
    /// break `brew services`, Swift builds, crash reporting …). Never orphans.
    static let toolingPrefixes = [
        "homebrew.", "org.swift.", "com.breakpad.", "org.sparkle-project.", "io.sentry.", "com.crashlytics.",
        "org.python.", "org.nodejs.", "org.macports.", "org.llvm.", "org.rust-lang.", "com.github.homebrew.",
        "org.gnupg.", "org.openjdk.", "net.java.", "com.oracle.java.", "org.mozilla.crashreporter",
        "com.google.keystone", "com.microsoft.autoupdate", "org.videolan.vlc.crash",
    ]

    static func isToolingName(_ id: String) -> Bool {
        let lower = id.lowercased()
        return toolingPrefixes.contains { lower.hasPrefix($0) }
    }

    // MARK: - Describing one entry

    /// Measures a matched entry and works out whether it can be moved. Links and protected
    /// places give nil (never listed).
    private func describe(
        path: String, folder: LibraryFolder, bundleID: String, reason: LeftoverReason, confidence: MatchConfidence,
        explanation: String
    ) -> LeftoverMatch? {
        guard Cleaner.linkState(path) == .present, Cleaner.isUnchanged(path),
            !protectedList.isProtectedPath(path)
        else { return nil }
        let url = URL(fileURLWithPath: path)
        let (bytes, newest) = Self.measure(url, stopIfCancelled: true)
        let status: LeftoverStatus
        if folder.isSystem || !Self.isOwnedByCurrentUser(path) {
            status = .needsHelper
        } else if protectedList.isProtected(url) {
            status = .holdsDatabase
        } else {
            status = .removable
        }
        return LeftoverMatch(
            appBundleID: bundleID, url: url, reason: reason, confidence: confidence, explanation: explanation,
            folderTitle: folder.title, size: bytes, modified: newest, status: status)
    }

    // MARK: - Name matching (also used by the Cleaner to re-check)

    struct NameMatch: Sendable, Equatable {
        let reason: LeftoverReason
        let confidence: MatchConfidence
        let explanation: String
    }

    /// Whether the Library entry `name` belongs to `app`, given the other installed apps.
    static func match(
        name: String, inGroupContainers: Bool, app: AppIdentity, others: [AppIdentity],
        knownAppPath: (String) -> String? = { _ in nil }
    ) -> NameMatch? {
        guard !name.hasPrefix("."), !isAppleName(name) else { return nil }
        let stripped = strippedName(name)
        let (teamPrefix, id) = idPart(of: stripped, inGroupContainers: inGroupContainers)
        guard !isAppleName(id) else { return nil }
        let kind =
            inGroupContainers ? "Shared folder name" : (stripped.count != name.count ? "File name" : "Folder name")
        let appPath = (PathTools.canonical(app.url.path) ?? app.url.path).lowercased()
        /// macOS knows an app with this ID somewhere other than this bundle.
        func elsewhere(_ bundleID: String) -> Bool {
            guard let path = knownAppPath(bundleID) else { return false }
            // A helper registered inside this app's own bundle is this app.
            return !PathTools.isInside((PathTools.canonical(path) ?? path).lowercased(), root: appPath)
        }
        let sameIDElsewhere =
            others.contains { $0.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame }
            || elsewhere(app.bundleID)

        // 1–2. Bundle ID, exact or as a prefix; the most specific installed owner wins.
        let lower = id.lowercased()
        let owners = ([app] + others).filter {
            let bid = $0.bundleID.lowercased()
            return lower == bid || lower.hasPrefix(bid + ".")
        }
        if let owner = owners.max(by: { $0.bundleID.count < $1.bundleID.count }) {
            guard owner.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame else { return nil }
            let exact = lower == app.bundleID.lowercased()
            // `com.foo.Bar.Pro…` while macOS knows an app `com.foo.Bar.Pro` elsewhere: that app's.
            if !exact {
                let appParts = app.bundleID.split(separator: ".").count
                let parts = id.split(separator: ".").map(String.init)
                if parts.count > appParts,
                    (appParts + 1...parts.count).contains(where: { elsewhere(parts.prefix($0).joined(separator: ".")) })
                {
                    return nil
                }
            }
            var explanation =
                exact
                ? "\(kind) matches the app's ID \(app.bundleID)."
                : "\(kind) starts with the app's ID \(app.bundleID)."
            var confidence: MatchConfidence = exact ? .high : .medium
            if sameIDElsewhere {
                confidence = .low
                explanation += " Another copy of this app is installed, so it isn't selected."
            }
            return NameMatch(
                reason: exact ? .bundleID : .bundleIDPrefix, confidence: confidence, explanation: explanation)
        }
        // 3. Team ID group containers.
        if inGroupContainers, let team = app.teamID, !team.isEmpty, let teamPrefix,
            teamPrefix.caseInsensitiveCompare(team) == .orderedSame
        {
            let shared = others.contains { $0.teamID?.caseInsensitiveCompare(team) == .orderedSame }
            return NameMatch(
                reason: .teamID, confidence: shared ? .low : .medium,
                explanation: shared
                    ? "Shared folder for apps from the same developer (team \(team)). Another of their apps is installed, so it isn't selected."
                    : "Shared folder for apps from the same developer (team \(team)).")
        }

        // 4. The app's name as whole words.
        let appTokens = significantTokens(app.name)
        guard !appTokens.isEmpty else { return nil }
        let entryTokens = Set(tokens(stripped))
        guard appTokens.isSubset(of: entryTokens) else { return nil }
        if others.contains(where: {
            let theirs = significantTokens($0.name)
            return !theirs.isEmpty && theirs.isSubset(of: entryTokens) && theirs.count >= appTokens.count
        }) {
            return nil
        }
        let sameName = !looksLikeBundleID(stripped) && tokens(stripped) == tokens(app.name)
        let confidence: MatchConfidence = sameName && !sameIDElsewhere ? .medium : .low
        return NameMatch(
            reason: .nameToken, confidence: confidence,
            explanation: confidence == .medium
                ? "Named after the app, “\(app.name)”."
                : "Its name contains “\(app.name)”. A guess, so it isn't selected.")
    }

    /// The name without a known file suffix (`.plist`, `.savedState`, `.binarycookies`).
    static func strippedName(_ name: String) -> String {
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.lowercased().hasSuffix(suffix.lowercased())
        {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// For group containers, splits `TEAMID.com.x.y` / `group.com.x.y` into its prefix and ID.
    static func idPart(of name: String, inGroupContainers: Bool) -> (teamPrefix: String?, id: String) {
        guard inGroupContainers else { return (nil, name) }
        if name.lowercased().hasPrefix("group.") { return (nil, String(name.dropFirst("group.".count))) }
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }),
            parts[0].allSatisfy(\.isASCII)
        {
            // `TEAMID.group.com.x.y` is a group for `com.x.y` too.
            let rest = parts[1].lowercased().hasPrefix("group.") ? String(parts[1].dropFirst("group.".count)) : parts[1]
            return (parts[0], rest)
        }
        return (nil, name)
    }

    /// `com.x.y`: three or more dot-separated parts, starting with letters.
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first, first.first?.isLetter == true else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Apple's or macOS's own (see `systemPrefixes`), also after a team-ID prefix.
    static func isAppleName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return systemPrefixes.contains { lower.hasPrefix($0) } || lower.contains(".com.apple.")
            || lower.contains(".is.workflow.")
    }

    /// First two parts of a bundle ID (`com.figma`).
    static func vendorPrefix(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Lower-cased alphanumeric words.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Words of an app name that can identify it: ≥ 4 characters, not generic.
    static func significantTokens(_ name: String) -> Set<String> {
        Set(tokens(name).filter { $0.count >= 4 && !genericWords.contains($0) })
    }

    // MARK: - File helpers

    static func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    static func isOwnedByCurrentUser(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_uid == getuid()
    }

    /// Allocated bytes and the newest file modification date inside (like the junk scanner; a
    /// folder with no files uses its own date). Links inside are not followed.
    /// With `stopIfCancelled` (listing only, never the Cleaner's re-checks), a cancelled task stops
    /// early; the caller throws such results away.
    static func measure(_ url: URL, stopIfCancelled: Bool = false) -> (bytes: Int64, newest: Date) {
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        let keySet = Set(keys)
        guard let values = try? url.resourceValues(forKeys: keySet) else { return (0, .distantPast) }
        let ownDate = values.contentModificationDate ?? .distantPast
        func size(_ v: URLResourceValues) -> Int64 { Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        guard values.isDirectory == true else { return (size(values), ownDate) }
        var total: Int64 = 0
        var newest: Date?
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        var visited = 0
        while let child = enumerator?.nextObject() as? URL {
            visited += 1
            // A cancelled task (a stopped Sweep) stops early; its results are thrown away.
            if stopIfCancelled, visited % 1_000 == 0, Task.isCancelled { break }
            guard let v = try? child.resourceValues(forKeys: keySet), v.isSymbolicLink != true, v.isDirectory != true
            else { continue }
            if let date = v.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
            total += size(v)
        }
        return (total, newest ?? ownDate)
    }
}

/// Whether macOS knows any app (outside the Trash) with a bundle ID. Orphans must not be.
enum LaunchServicesApps {
    static func isKnown(_ bundleID: String) -> Bool { path(for: bundleID) != nil }

    /// The app's path as LaunchServices knows it, unless it's in the Trash.
    static func path(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            !url.path.contains("/.Trash/")
        else { return nil }
        return url.path
    }
}
