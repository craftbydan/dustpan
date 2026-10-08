import CoreServices
import Darwin
import Foundation
import Security
import os

/// An installed app, as the Apps screen lists it.
struct AppRecord: Sendable, Identifiable, Hashable {
    let bundleID: String
    let teamID: String?
    let name: String
    let url: URL
    let version: String
    /// Allocated bytes of the whole bundle.
    let size: Int64
    /// Spotlight's `kMDItemLastUsedDate`; nil when macOS hasn't recorded one.
    let lastUsed: Date?
    /// The current user can't move the bundle to the Trash (installed for all users, e.g. a
    /// root-owned bundle): Finder asks for a password, Dustpan doesn't (no helper, no admin prompt).
    var needsAdminToRemove = false

    var id: String { url.path }

    var identity: AppIdentity { AppIdentity(bundleID: bundleID, teamID: teamID, name: name, url: url) }

    /// 180 days (about six months).
    static let unusedInterval: TimeInterval = 180 * 86_400

    /// Opened more than six months ago. An app with no recorded use doesn't count (unknown).
    func isUnused(now: Date = Date()) -> Bool {
        guard let lastUsed else { return false }
        return lastUsed < now.addingTimeInterval(-Self.unusedInterval)
    }

    /// Total size of the unused apps in `apps`. The Apps screen and the Sweep tile both use this.
    static func unusedBytes(_ apps: [AppRecord], now: Date) -> Int64 {
        apps.filter { $0.isUnused(now: now) }.reduce(0) { $0 + $1.size }
    }
}

/// Who an app is, without measuring it. Enough to match leftovers and to re-check an uninstall.
struct AppIdentity: Sendable, Hashable {
    let bundleID: String
    let teamID: String?
    let name: String
    let url: URL
}

/// The few `Info.plist` values Dustpan needs, read straight from `Contents/Info.plist` (no
/// `Bundle` cache, so a re-check sees what is on disk now).
struct AppBundleInfo: Sendable, Equatable {
    let bundleID: String
    let name: String
    let version: String

    static func read(_ appURL: URL) -> AppBundleInfo? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }
        let fileName = appURL.deletingPathExtension().lastPathComponent
        let name =
            [plist["CFBundleDisplayName"], plist["CFBundleName"]].compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? fileName
        let version =
            [plist["CFBundleShortVersionString"], plist["CFBundleVersion"]].compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? ""
        return AppBundleInfo(bundleID: bundleID, name: name, version: version)
    }
}

/// Code-signing facts about an app bundle.
struct SigningInfo: Sendable, Equatable {
    var teamID: String?
    /// Signed by Apple itself (`anchor apple`), or with Apple's own team ID.
    var isApple: Bool

    static let unsigned = SigningInfo(teamID: nil, isApple: false)
}

/// Reads a bundle's signature. Injected so tests can give fixture apps a team ID.
protocol CodeSigningReading: Sendable {
    func signing(of appURL: URL) -> SigningInfo
}

/// `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`. Validates only the
/// signature's own structure against `anchor apple` (no hashing of the whole bundle).
struct SecCodeSigningReader: CodeSigningReading {
    /// Apple's App Store team (Xcode, Pages, Keynote, …).
    static let appleTeamIDs: Set<String> = ["59GAB85EFG", "APPLECOMPUTER"]

    func signing(of appURL: URL) -> SigningInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code else {
            return .unsigned
        }
        var info: CFDictionary?
        var teamID: String?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let dictionary = info as? [String: Any]
        {
            teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        }
        var requirement: SecRequirement?
        var isApple = teamID.map(Self.appleTeamIDs.contains) ?? false
        if !isApple, SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
            let requirement
        {
            let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
            isApple = SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        }
        return SigningInfo(teamID: teamID, isApple: isApple)
    }
}

/// When an app was last opened, from Spotlight.
protocol LastUsedReading: Sendable {
    func lastUsed(_ appURL: URL) -> Date?
}

struct SpotlightLastUsed: LastUsedReading {
    func lastUsed(_ appURL: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, appURL as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Lists installed apps: a direct look at the app folders (and one level of sub-folders such as
/// `/Applications/Utilities`) plus a Spotlight query (`kMDItemContentType ==
/// 'com.apple.application-bundle'`) scoped to the same folders, which finds apps deeper down.
///
/// Left out: anything in `/System`, Apple's own apps (`com.apple.*` IDs or Apple-signed), links,
/// apps inside other apps, and bundles without a bundle ID. Never reads outside `roots`.
actor AppScanner {
    let roots: [URL]
    private let useSpotlight: Bool
    private let signing: any CodeSigningReading
    private let lastUsedReader: any LastUsedReading
    private let logger = Logger(subsystem: "app.dustpan", category: "apps")

    /// `/Applications` and `~/Applications`.
    static func defaultRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications")]
    }

    init(
        roots: [URL], useSpotlight: Bool = true, signing: any CodeSigningReading = SecCodeSigningReader(),
        lastUsed: any LastUsedReading = SpotlightLastUsed()
    ) {
        self.roots = roots
        self.useSpotlight = useSpotlight
        self.signing = signing
        self.lastUsedReader = lastUsed
    }

    /// Who is installed, without measuring sizes (fast). Used for leftover and orphan checks.
    func identities() -> [AppIdentity] {
        assertNotMainThread()
        return candidates().compactMap { Self.identity(of: $0, signing: signing) }
    }

    /// Every installed, non-Apple app with size, version, team ID and last use.
    func installedApps() async -> [AppRecord] {
        assertNotMainThread()
        let found = candidates()
        let signing = signing
        let lastUsedReader = lastUsedReader
        let records = await withTaskGroup(of: AppRecord?.self) { group in
            for url in found {
                group.addTask {
                    Task.isCancelled ? nil : Self.record(of: url, signing: signing, lastUsed: lastUsedReader)
                }
            }
            var records: [AppRecord] = []
            for await record in group { if let record { records.append(record) } }
            return records
        }
        // Cancelled (e.g. a Sweep was stopped): sizes may be partial, so report nothing.
        if Task.isCancelled { return [] }
        logger.info("Apps: \(records.count, privacy: .public) installed apps listed")
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Finding bundles

    /// Canonical paths of `.app` bundles under the roots, deduplicated.
    private func candidates() -> [URL] {
        let canonicalRoots = roots.compactMap { PathTools.canonical($0.path) }
        var seen = Set<String>()
        var result: [URL] = []
        func offer(_ path: String) {
            guard let canonical = PathTools.canonical(path), Self.isAcceptable(canonical, roots: canonicalRoots)
            else { return }
            if seen.insert(canonical.lowercased()).inserted {
                result.append(URL(fileURLWithPath: canonical, isDirectory: true))
            }
        }
        for root in canonicalRoots {
            for name in Self.children(root) {
                let path = root + "/" + name
                guard Cleaner.linkState(path) == .present else { continue }
                if name.lowercased().hasSuffix(".app") {
                    offer(path)
                } else if Self.isPlainFolder(path) {
                    for inner in Self.children(path) where inner.lowercased().hasSuffix(".app") {
                        let innerPath = path + "/" + inner
                        if Cleaner.linkState(innerPath) == .present { offer(innerPath) }
                    }
                }
            }
        }
        if useSpotlight {
            for path in Self.spotlightApps(in: canonicalRoots) where Cleaner.linkState(path) == .present {
                offer(path)
            }
        }
        return result
    }

    /// Inside a root, not in `/System`, not inside another bundle, and no link on the way.
    static func isAcceptable(_ canonical: String, roots: [String]) -> Bool {
        guard canonical.lowercased().hasSuffix(".app"),
            !PathTools.isInside(canonical, root: "/System"),
            let root = roots.first(where: { PathTools.isStrictlyInside(canonical, root: $0) })
        else { return false }
        let inner = PathTools.components(String(canonical.dropFirst(root.count)))
        // At most one plain sub-folder down (`/Applications/Utilities/X.app`), the same limit the
        // Cleaner applies; only the last component may be a bundle; hidden folders are skipped.
        return inner.count <= 2
            && !inner.dropLast().contains { $0.lowercased().hasSuffix(".app") || $0.hasPrefix(".") }
    }

    private static func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func isPlainFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            && !path.lowercased().hasSuffix(".app")
    }

    /// Spotlight's app bundles under `roots` (synchronous `MDQuery`, off the main actor).
    private static func spotlightApps(in roots: [String]) -> [String] {
        guard !roots.isEmpty,
            let query = MDQueryCreate(
                kCFAllocatorDefault, "kMDItemContentType == 'com.apple.application-bundle'" as CFString, nil, nil)
        else { return [] }
        MDQuerySetSearchScope(query, roots as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
        }
        return paths
    }

    // MARK: - Reading one bundle

    /// Identity of a bundle, or nil for Apple apps and bundles without an ID.
    static func identity(of url: URL, signing: any CodeSigningReading) -> AppIdentity? {
        guard let info = AppBundleInfo.read(url), !isAppleBundleID(info.bundleID) else { return nil }
        let signature = signing.signing(of: url)
        guard !signature.isApple else { return nil }
        return AppIdentity(bundleID: info.bundleID, teamID: signature.teamID, name: info.name, url: url)
    }

    private static func record(
        of url: URL, signing: any CodeSigningReading, lastUsed: any LastUsedReading
    ) -> AppRecord? {
        guard let identity = identity(of: url, signing: signing), let info = AppBundleInfo.read(url) else {
            return nil
        }
        return AppRecord(
            bundleID: identity.bundleID, teamID: identity.teamID, name: identity.name, url: url,
            version: info.version, size: Cleaner.allocatedSize(of: url, stopIfCancelled: true),
            lastUsed: lastUsed.lastUsed(url), needsAdminToRemove: AppRemoval.needsAdmin(url.path))
    }

    static func isAppleBundleID(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.apple.")
    }
}

/// Whether the current user may move an app bundle to the Trash without a password.
enum AppRemoval {
    /// True unless both the bundle folder and its parent are writable by this user (moving a
    /// folder to another parent rewrites its own `..` entry, so the folder itself must be writable
    /// too), and — when the parent has the sticky bit — the user owns the bundle. `access(2)`
    /// answers for the real user, ACLs included. Unreadable paths count as needing a password.
    static func needsAdmin(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        var bundleInfo = stat()
        var parentInfo = stat()
        guard lstat(path, &bundleInfo) == 0, lstat(parent, &parentInfo) == 0 else { return true }
        guard access(path, W_OK) == 0, access(parent, W_OK) == 0 else { return true }
        let sticky = (parentInfo.st_mode & S_ISVTX) != 0
        return sticky && bundleInfo.st_uid != getuid()
    }
}
