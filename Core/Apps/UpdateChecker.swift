import Foundation
import os

/// Where a newer version was looked up.
enum UpdateSource: String, Sendable, Codable, CaseIterable {
    case sparkle, homebrew, appStore

    var title: String {
        switch self {
        case .sparkle: "Sparkle"
        case .homebrew: "Homebrew"
        case .appStore: "App Store"
        }
    }
}

/// Why an app couldn't be checked.
enum CantCheckReason: String, Sendable, Codable, Equatable {
    /// No App Store receipt, no update feed in its Info.plist, no matching Homebrew cask.
    case noSource
    /// Its feed is plain `http://`; Dustpan only reads feeds over HTTPS.
    case insecureFeed
    /// The feed answered but held no version Dustpan could read.
    case feedUnreadable
    /// The App Store lookup didn't list it.
    case notInStore
    /// No internet connection.
    case offline
    /// The source didn't answer (server error, timeout).
    case failed

    var explanation: String {
        switch self {
        case .noSource: "No update feed Dustpan can read. The app may check for updates itself."
        case .insecureFeed: "Its update feed isn't encrypted (http), so Dustpan doesn't read it."
        case .feedUnreadable: "Its update feed didn't list a version Dustpan could read."
        case .notInStore: "The App Store didn't list it for your region."
        case .offline: "Dustpan couldn't connect. Check again when you're online."
        case .failed: "Its update source didn't answer this time."
        }
    }
}

enum UpdateStatus: Sendable, Equatable {
    case available(String)
    case upToDate
    case cantCheck(CantCheckReason)
}

/// What "Open" does. Nothing is ever downloaded or installed by Dustpan.
enum UpdateOpenTarget: Sendable, Equatable {
    /// The app's App Store page (`macappstore://…`).
    case appStore(URL)
    /// The app itself, so its own updater can run.
    case app(URL)
    /// A developer page (a cask's homepage). Always `https://`.
    case web(URL)
}

/// An installed app to check.
struct UpdateCandidate: Sendable, Hashable {
    let name: String
    let bundleID: String
    let url: URL
}

/// One app's result.
struct AppUpdate: Sendable, Identifiable, Equatable {
    let app: UpdateCandidate
    /// As people read it ("4.2.1", or "4.2.1 (812)" when only the build differs).
    let installedVersion: String
    let status: UpdateStatus
    let source: UpdateSource?
    let open: UpdateOpenTarget?
    /// The cask token, when Homebrew installed the app (`brew upgrade --cask <token>`).
    let brewToken: String?

    var id: String { app.url.path }

    var isOutdated: Bool {
        if case .available = status { return true }
        return false
    }

    var availableVersion: String? {
        if case .available(let version) = status { return version }
        return nil
    }
}

struct UpdateReport: Sendable {
    var updates: [AppUpdate]
    /// No connection at all: some or every app shows "can't check".
    var offline: Bool
    /// When the Homebrew cask list in use was downloaded (nil when it wasn't needed or failed).
    var caskListDate: Date?
    /// The cask list in use is older than a day because a fresh copy couldn't be downloaded.
    var caskListStale: Bool
    var checkedAt: Date

    var outdated: [AppUpdate] { updates.filter(\.isOutdated) }
}

/// What an app's own bundle says about its version and update feed.
struct LocalVersionInfo: Sendable, Equatable {
    var shortVersion: String?
    var buildVersion: String?
    var feedURL: String?
    var hasAppStoreReceipt: Bool

    var display: String { shortVersion ?? buildVersion ?? "?" }

    static func read(_ appURL: URL) -> LocalVersionInfo {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        var info = LocalVersionInfo(shortVersion: nil, buildVersion: nil, feedURL: nil, hasAppStoreReceipt: false)
        if let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            func text(_ key: String) -> String? {
                (plist[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            info.shortVersion = text("CFBundleShortVersionString")
            info.buildVersion = text("CFBundleVersion")
            info.feedURL = text("SUFeedURL")
        }
        info.hasAppStoreReceipt = FileManager.default.fileExists(
            atPath: contents.appendingPathComponent("_MASReceipt/receipt").path)
        return info
    }
}

/// Finds newer versions of installed apps from three sources, read-only:
///
/// 1. **App Store** apps (with `Contents/_MASReceipt/receipt`): the iTunes Lookup API, 20 bundle
///    IDs per request.
/// 2. **Sparkle** apps: the `SUFeedURL` in the app's Info.plist (HTTPS only). The newest item on
///    the default channel for this macOS; its `sparkle:version` is compared with `CFBundleVersion`.
/// 3. **Homebrew** casks, for the rest: `formulae.brew.sh/api/cask.json`, kept on disk as a slim
///    index for 24 h. A cask matches only when it installs an `.app` of exactly this name **and**
///    either Homebrew's Caskroom has that cask installed or the cask names this bundle ID.
///
/// Never downloads or installs an update, never scrapes web pages.
actor UpdateChecker {
    static let caskListURL = URL(literal: "https://formulae.brew.sh/api/cask.json")
    static let caskCacheTTL: TimeInterval = 24 * 60 * 60
    static let lookupBatch = 20

    private let http: any HTTPFetching
    private let cacheDirectory: URL
    private let caskroomRoots: [URL]
    private let gate: RequestGate
    private let now: @Sendable () -> Date
    private let storeCountry: String
    private let systemVersion: OperatingSystemVersion
    private var caskIndex: CaskIndex?
    private let logger = Logger(subsystem: "app.dustpan", category: "updates")

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.dustpan.Dustpan", isDirectory: true)
    }

    static let defaultCaskroomRoots = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true),
    ]

    init(
        http: any HTTPFetching = URLSessionHTTPClient(),
        cacheDirectory: URL = UpdateChecker.defaultCacheDirectory,
        caskroomRoots: [URL] = UpdateChecker.defaultCaskroomRoots,
        gate: RequestGate = RequestGate(),
        now: @escaping @Sendable () -> Date = { Date() },
        storeCountry: String? = nil,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.http = http
        self.cacheDirectory = cacheDirectory
        self.caskroomRoots = caskroomRoots
        self.gate = gate
        self.now = now
        self.storeCountry = (storeCountry ?? Locale.current.region?.identifier ?? "us").lowercased()
        self.systemVersion = systemVersion
    }

    nonisolated var caskCacheFile: URL { cacheDirectory.appendingPathComponent("homebrew-casks-v3.json") }

    // MARK: - Checking

    /// Checks every app. `progress` gets (apps done, apps total).
    func check(
        _ apps: [UpdateCandidate], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> UpdateReport {
        assertNotMainThread()
        let total = apps.count
        let locals = apps.map { LocalVersionInfo.read($0.url) }
        var results: [Int: AppUpdate] = [:]
        var pending: [Int: CantCheckReason] = [:]
        var offline = false
        func finish(_ index: Int, _ update: AppUpdate) {
            results[index] = update
            pending[index] = nil
        }

        // Phase 1: App Store and Sparkle feeds, in parallel (the gate limits the requests).
        let storeIndices = apps.indices.filter { locals[$0].hasAppStoreReceipt }
        var feedIndices: [(Int, URL)] = []
        for index in apps.indices where !locals[index].hasAppStoreReceipt {
            guard let raw = locals[index].feedURL else {
                pending[index] = .noSource
                continue
            }
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host() != nil else {
                pending[index] = .insecureFeed
                continue
            }
            feedIndices.append((index, url))
        }

        enum Outcome: Sendable {
            case store([Int], [String: ITunesLookup.Result], failure: CantCheckReason?)
            case feed(Int, [AppcastItem]?, failure: CantCheckReason?)
        }
        let storeBatches = stride(from: 0, to: storeIndices.count, by: Self.lookupBatch).map {
            Array(storeIndices[$0..<min($0 + Self.lookupBatch, storeIndices.count)])
        }
        let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
            for batch in storeBatches {
                let ids = batch.map { apps[$0].bundleID }
                group.addTask { [self] in
                    let (found, failure) = await self.lookUpInStore(ids)
                    return .store(batch, found, failure: failure)
                }
            }
            for (index, url) in feedIndices {
                group.addTask { [self] in
                    let (items, failure) = await self.fetchAppcast(url)
                    return .feed(index, items, failure: failure)
                }
            }
            var outcomes: [Outcome] = []
            var answered = 0
            for await outcome in group {
                outcomes.append(outcome)
                switch outcome {
                case .store(let batch, _, _): answered += batch.count
                case .feed: answered += 1
                }
                progress(answered, total)
            }
            return outcomes
        }
        for outcome in outcomes {
            switch outcome {
            case .store(let batch, let found, let failure):
                if failure == .offline { offline = true }
                for index in batch {
                    let app = apps[index]
                    let local = locals[index]
                    let result = found[app.bundleID.lowercased()]
                    if let result, let version = result.version {
                        finish(index, Self.storeResult(app: app, local: local, version: version, result: result))
                    } else {
                        finish(
                            index,
                            AppUpdate(
                                app: app, installedVersion: local.display, status: .cantCheck(failure ?? .notInStore),
                                source: .appStore, open: Self.storeOpenTarget(result) ?? .app(app.url),
                                brewToken: nil))
                    }
                }
            case .feed(let index, let items, let failure):
                if failure == .offline { offline = true }
                if let items, let newest = AppcastParser.newest(in: items, systemVersion: systemVersion) {
                    finish(index, Self.sparkleResult(app: apps[index], local: locals[index], item: newest))
                } else {
                    pending[index] = failure ?? .feedUnreadable
                }
            }
        }

        // Phase 2: Homebrew casks for whatever is left (no feed, an http feed, or a failed feed).
        var caskListDate: Date?
        var caskListStale = false
        if !pending.isEmpty {
            let (index, failure) = await loadCaskIndex()
            if failure == .offline { offline = true }
            if let index {
                caskListDate = index.fetchedAt
                caskListStale = now().timeIntervalSince(index.fetchedAt) >= Self.caskCacheTTL
                let tokens = installedCaskTokens()
                for appIndex in pending.keys.sorted() {
                    let app = apps[appIndex]
                    guard let match = Self.matchCask(app: app, index: index, installedTokens: tokens) else { continue }
                    finish(
                        appIndex,
                        Self.caskResult(
                            app: app, local: locals[appIndex], cask: match.cask, viaBrew: match.viaBrew,
                            systemVersion: systemVersion))
                }
            } else if let failure {
                // The reason the app had no other source still stands, unless nothing could connect.
                for key in pending.keys where failure == .offline && pending[key] == .noSource {
                    pending[key] = .offline
                }
            }
        }
        for (index, reason) in pending.sorted(by: { $0.key < $1.key }) {
            let app = apps[index]
            finish(
                index,
                AppUpdate(
                    app: app, installedVersion: locals[index].display, status: .cantCheck(reason),
                    source: locals[index].feedURL != nil && reason != .noSource ? .sparkle : nil, open: .app(app.url),
                    brewToken: nil))
        }
        let updates = apps.indices.compactMap { results[$0] }
        progress(total, total)
        let outdatedCount = updates.filter(\.isOutdated).count
        logger.info(
            "Updates: \(updates.count, privacy: .public) apps checked, \(outdatedCount, privacy: .public) outdated")
        return UpdateReport(
            updates: updates, offline: offline, caskListDate: caskListDate, caskListStale: caskListStale,
            checkedAt: now())
    }

    // MARK: - Results

    static func sparkleResult(app: UpdateCandidate, local: LocalVersionInfo, item: AppcastItem) -> AppUpdate {
        // Sparkle compares the build (`sparkle:version` vs CFBundleVersion); fall back to the
        // visible versions when either side lacks a build.
        let newer: Bool
        if let build = item.version, let installedBuild = local.buildVersion {
            newer = VersionCompare.isNewer(build, than: installedBuild)
        } else if let short = item.shortVersion ?? item.version,
            let installed = local.shortVersion ?? local.buildVersion
        {
            newer = VersionCompare.isNewer(short, than: installed)
        } else {
            return AppUpdate(
                app: app, installedVersion: local.display, status: .cantCheck(.feedUnreadable), source: .sparkle,
                open: .app(app.url), brewToken: nil)
        }
        var installed = local.display
        var available = item.shortVersion ?? item.version ?? ""
        if newer, installed == available, let build = item.version, let installedBuild = local.buildVersion {
            installed += " (\(installedBuild))"
            available += " (\(build))"
        }
        return AppUpdate(
            app: app, installedVersion: installed, status: newer ? .available(available) : .upToDate,
            source: .sparkle, open: .app(app.url), brewToken: nil)
    }

    static func storeResult(
        app: UpdateCandidate, local: LocalVersionInfo, version: String, result: ITunesLookup.Result
    ) -> AppUpdate {
        let installed = local.shortVersion ?? local.buildVersion ?? ""
        let newer = !installed.isEmpty && VersionCompare.isNewer(version, than: installed)
        return AppUpdate(
            app: app, installedVersion: local.display, status: newer ? .available(version) : .upToDate,
            source: .appStore, open: storeOpenTarget(result), brewToken: nil)
    }

    static func storeOpenTarget(_ result: ITunesLookup.Result?) -> UpdateOpenTarget? {
        guard let result else { return nil }
        if let id = result.trackId, let url = URL(string: "macappstore://apps.apple.com/app/id\(id)") {
            return .appStore(url)
        }
        if let raw = result.trackViewUrl, let url = URL(string: raw), url.scheme == "https",
            url.host()?.hasSuffix("apple.com") == true
        {
            return .appStore(url)
        }
        return nil
    }

    static func caskResult(
        app: UpdateCandidate, local: LocalVersionInfo, cask: CaskEntry, viaBrew: Bool,
        systemVersion: OperatingSystemVersion
    ) -> AppUpdate {
        // "2.1.3,2202": the part before the comma is the app's visible version. Nil: the newest
        // needs a newer macOS than this one, so there's nothing to install here.
        let offered = cask.version(for: systemVersion)
        let available = offered.map { VersionCompare.parse($0).main.joined(separator: ".") } ?? ""
        let installed = local.shortVersion ?? local.buildVersion ?? ""
        let open: UpdateOpenTarget =
            cask.homepage.flatMap { URL(string: $0) }.flatMap { $0.scheme?.lowercased() == "https" ? .web($0) : nil }
            ?? .app(app.url)
        if offered == nil, !installed.isEmpty {
            return AppUpdate(
                app: app, installedVersion: local.display, status: .upToDate, source: .homebrew, open: open,
                brewToken: viaBrew ? cask.token : nil)
        }
        guard !available.isEmpty, !installed.isEmpty else {
            return AppUpdate(
                app: app, installedVersion: local.display, status: .cantCheck(.feedUnreadable), source: .homebrew,
                open: open, brewToken: viaBrew ? cask.token : nil)
        }
        let newer = VersionCompare.compare(available, installed) == .orderedDescending
        return AppUpdate(
            app: app, installedVersion: local.display, status: newer ? .available(available) : .upToDate,
            source: .homebrew, open: open, brewToken: viaBrew ? cask.token : nil)
    }

    /// The cask for this app, or nil. Name must match exactly; then either Homebrew installed that
    /// cask (Caskroom) or the cask names this bundle ID in its uninstall/zap stanzas. Variant casks
    /// (`firefox@beta`) count only when installed. Ambiguous matches are dropped.
    static func matchCask(
        app: UpdateCandidate, index: CaskIndex, installedTokens: Set<String>
    ) -> (cask: CaskEntry, viaBrew: Bool)? {
        let fileName = app.url.lastPathComponent
        let id = app.bundleID.lowercased()
        let named = index.casks.filter { cask in
            cask.apps.contains { $0.caseInsensitiveCompare(fileName) == .orderedSame }
        }
        if !named.isEmpty {
            let brewed = named.filter { installedTokens.contains($0.token.lowercased()) }
            if brewed.count == 1 { return (brewed[0], true) }
            if brewed.count > 1 { return nil }
            let confirmed = named.filter { !$0.token.contains("@") && $0.bundleIDs.contains(id) }
            return confirmed.count == 1 ? (confirmed[0], false) : nil
        }
        // Installer (pkg) casks list no app. A quit of this exact ID counts only together with a
        // second sign (the cask's name is the app's name, it deletes `/Applications/<this>.app`, or
        // its package receipt is this ID), because some casks quit other vendors' helpers. A path
        // alone counts when it's exact and Homebrew installed the cask, or only one cask has it.
        let appName = (fileName as NSString).deletingPathExtension
        let installers = index.casks.filter { $0.apps.isEmpty }
        let hasPath = { (cask: CaskEntry) in
            cask.appPaths.contains { $0.caseInsensitiveCompare(fileName) == .orderedSame }
        }
        let confirmedByQuit = installers.filter { cask in
            cask.quitIDs.contains(id)
                && (cask.names.contains { $0.caseInsensitiveCompare(appName) == .orderedSame } || hasPath(cask)
                    || cask.pkgIDs.contains(id))
        }
        let byPath = installers.filter(hasPath)
        let brewed = (confirmedByQuit + byPath).filter { installedTokens.contains($0.token.lowercased()) }
        let brewedTokens = Set(brewed.map(\.token))
        if brewedTokens.count == 1, let cask = brewed.first { return (cask, true) }
        guard brewedTokens.isEmpty else { return nil }
        var seen = Set<String>()
        let plain = (confirmedByQuit + byPath).filter { !$0.token.contains("@") && seen.insert($0.token).inserted }
        return pickOne(plain, appName: appName, id: id).map { ($0, false) }
    }

    /// One cask out of several candidates for the same installer-made app: the one with the most
    /// signs (cask name = app name, package receipt = bundle ID, quits/signals the bundle ID); if
    /// several are left and they all offer the same version (e.g. `zoom` and `zoom-for-it-admins`),
    /// any of them gives the same answer, so the first token wins. Otherwise none.
    static func pickOne(_ candidates: [CaskEntry], appName: String, id: String) -> CaskEntry? {
        guard candidates.count > 1 else { return candidates.first }
        func signs(_ cask: CaskEntry) -> Int {
            (cask.names.contains { $0.caseInsensitiveCompare(appName) == .orderedSame } ? 1 : 0)
                + (cask.pkgIDs.contains(id) ? 1 : 0) + (cask.quitIDs.contains(id) ? 1 : 0)
        }
        let best = candidates.map(signs).max() ?? 0
        let top = candidates.filter { signs($0) == best }.sorted { $0.token < $1.token }
        if top.count == 1 { return top[0] }
        return Set(top.map(\.version)).count == 1 ? top.first : nil
    }

    // MARK: - Network

    private func fetchAppcast(_ url: URL) async -> ([AppcastItem]?, CantCheckReason?) {
        do {
            let http = http
            let data = try await gate.run(url) {
                try await http.get(url, timeout: UpdateLimits.requestTimeout, maxBytes: UpdateLimits.appcastMaxBytes)
            }
            guard let items = AppcastParser.parse(data) else { return (nil, .feedUnreadable) }
            return (items, nil)
        } catch {
            return (nil, Self.reason(for: error))
        }
    }

    /// Looks the IDs up in this region's store, then in the US store for any not found.
    private func lookUpInStore(_ ids: [String]) async -> ([String: ITunesLookup.Result], CantCheckReason?) {
        var found: [String: ITunesLookup.Result] = [:]
        var failure: CantCheckReason?
        for country in storeCountry == "us" ? ["us"] : [storeCountry, "us"] {
            let missing = ids.filter { found[$0.lowercased()] == nil }
            guard !missing.isEmpty else { break }
            guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { break }
            components.queryItems = [
                URLQueryItem(name: "bundleId", value: missing.joined(separator: ",")),
                URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "entity", value: "macSoftware"),
            ]
            guard let url = components.url else { continue }
            do {
                let http = http
                let data = try await gate.run(url) {
                    try await http.get(url, timeout: UpdateLimits.requestTimeout, maxBytes: UpdateLimits.lookupMaxBytes)
                }
                let lookup = try JSONDecoder().decode(ITunesLookup.self, from: data)
                for result in lookup.results {
                    if let id = result.bundleId?.lowercased(), found[id] == nil { found[id] = result }
                }
                failure = nil
            } catch {
                failure = Self.reason(for: error)
                if failure == .offline { break }
            }
        }
        return (found, failure)
    }

    /// The slim cask index: from memory, from the disk cache if under a day old, else downloaded.
    /// A failed download falls back to an older cached copy.
    func loadCaskIndex() async -> (CaskIndex?, CantCheckReason?) {
        assertNotMainThread()
        let current = now()
        if let caskIndex, Self.isFresh(caskIndex.fetchedAt, now: current) { return (caskIndex, nil) }
        let cached = readCachedIndex()
        if let cached, Self.isFresh(cached.fetchedAt, now: current) {
            caskIndex = cached
            return (cached, nil)
        }
        do {
            let http = http
            let url = Self.caskListURL
            let data = try await gate.run(url) {
                try await http.get(url, timeout: UpdateLimits.downloadTimeout, maxBytes: UpdateLimits.caskListMaxBytes)
            }
            let index = try CaskIndex.fromAPI(data, fetchedAt: current)
            caskIndex = index
            writeCachedIndex(index)
            logger.info("Updates: Homebrew cask list downloaded, \(index.casks.count, privacy: .public) casks")
            return (index, nil)
        } catch {
            let reason = Self.reason(for: error)
            logger.error("Updates: cask list failed: \(String(describing: error), privacy: .private)")
            if let cached {
                caskIndex = cached
                return (cached, reason)
            }
            return (nil, reason)
        }
    }

    static func isFresh(_ fetchedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= -60 && age < caskCacheTTL
    }

    private func readCachedIndex() -> CaskIndex? {
        guard let data = try? Data(contentsOf: caskCacheFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CaskIndex.self, from: data)
    }

    private func writeCachedIndex(_ index: CaskIndex) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try encoder.encode(index).write(to: caskCacheFile, options: .atomic)
        } catch {
            logger.error("Updates: cask cache not written: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Cask tokens Homebrew has installed (folder names in its Caskroom).
    private func installedCaskTokens() -> Set<String> {
        var tokens = Set<String>()
        for root in caskroomRoots {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where !name.hasPrefix(".") { tokens.insert(name.lowercased()) }
        }
        return tokens
    }

    private static func reason(for error: any Error) -> CantCheckReason {
        if error.isOffline { return .offline }
        if error is DecodingError { return .feedUnreadable }
        return .failed
    }
}
