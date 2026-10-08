import Foundation
import Testing

@testable import Dustpan

/// A fake network: answers from a handler, records every URL, tracks how many requests overlap.
final class MockHTTP: HTTPFetching, @unchecked Sendable {
    typealias Handler = @Sendable (URL) throws -> Data
    private let lock = NSLock()
    private let handler: Handler
    private let delay: Duration
    private var log: [URL] = []
    private var inFlight = 0
    private var inFlightPerHost: [String: Int] = [:]
    private(set) var maxInFlight = 0
    private(set) var maxInFlightPerHost = 0

    init(delay: Duration = .zero, handler: @escaping Handler) {
        self.delay = delay
        self.handler = handler
    }

    var requests: [URL] { lock.withLock { log } }

    func count(host: String) -> Int { requests.filter { $0.host() == host }.count }

    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        let host = url.host() ?? ""
        lock.withLock {
            log.append(url)
            inFlight += 1
            inFlightPerHost[host, default: 0] += 1
            maxInFlight = max(maxInFlight, inFlight)
            maxInFlightPerHost = max(maxInFlightPerHost, inFlightPerHost[host, default: 0])
        }
        defer {
            lock.withLock {
                inFlight -= 1
                inFlightPerHost[host, default: 1] -= 1
            }
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard url.scheme == "https" else { throw HTTPError.notHTTPS }
        return try handler(url)
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(hours: Double) { lock.withLock { value = value.addingTimeInterval(hours * 3_600) } }
}

@MainActor
final class RecordingOpener: URLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

/// Update checks (Prompt 15): fixture app bundles, fake appcasts, a cask JSON subset and iTunes
/// answers, all served by `MockHTTP`. Nothing touches the network or the real disk outside temp.
@Suite("Updates")
struct UpdateCheckerTests {
    struct Fixture {
        let root: URL
        let apps: URL
        let caskroom: URL
        let cache: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("DustpanUpdates-\(UUID().uuidString)", isDirectory: true)
            root = base
            apps = base.appendingPathComponent("Applications", isDirectory: true)
            caskroom = base.appendingPathComponent("Caskroom", isDirectory: true)
            cache = base.appendingPathComponent("Caches", isDirectory: true)
            for url in [apps, caskroom] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        /// Writes `<apps>/<name>.app` with an Info.plist (and a `_MASReceipt` if asked).
        @discardableResult
        func app(
            _ name: String, id: String, short: String?, build: String?, feed: String? = nil, appStore: Bool = false
        ) throws -> UpdateCandidate {
            let bundle = apps.appendingPathComponent("\(name).app", isDirectory: true)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name]
            if let short { plist["CFBundleShortVersionString"] = short }
            if let build { plist["CFBundleVersion"] = build }
            if let feed { plist["SUFeedURL"] = feed }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            if appStore {
                let receipt = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
                try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: receipt.appendingPathComponent("receipt"))
            }
            return UpdateCandidate(name: name, bundleID: id, url: bundle)
        }

        func brewInstalled(_ token: String, version: String) throws {
            try FileManager.default.createDirectory(
                at: caskroom.appendingPathComponent("\(token)/\(version)", isDirectory: true),
                withIntermediateDirectories: true)
        }

        func checker(http: MockHTTP, clock: TestClock = TestClock(Date()), country: String = "us") -> UpdateChecker {
            UpdateChecker(
                http: http, cacheDirectory: cache, caskroomRoots: [caskroom],
                gate: RequestGate(maxConcurrent: 4, maxPerHost: 2, spacing: .zero), now: { clock.now },
                storeCountry: country,
                systemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Fake answers

    static func appcast(_ items: [String]) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel><title>Feed</title>
            \(items.joined(separator: "\n"))
            </channel></rss>
            """.utf8)
    }

    /// Feedy: 1.10 (build 210) is the newest release; a 2.0 beta and a 1.9 also listed; 3.0 needs macOS 15.
    static let feedyAppcast = appcast([
        """
        <item><title>1.9</title><sparkle:version>190</sparkle:version>
        <sparkle:shortVersionString>1.9</sparkle:shortVersionString>
        <enclosure url="https://feedy.example/1.9.zip" length="1" type="application/octet-stream"/></item>
        """,
        """
        <item><title>2.0 beta</title><sparkle:channel>beta</sparkle:channel>
        <enclosure url="https://feedy.example/2.0b1.zip" sparkle:version="300" sparkle:shortVersionString="2.0b1"/></item>
        """,
        """
        <item><title>1.10</title>
        <enclosure url="https://feedy.example/1.10.zip" sparkle:version="210" sparkle:shortVersionString="1.10"/></item>
        """,
        """
        <item><title>3.0</title><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
        <enclosure url="https://feedy.example/3.0.zip" sparkle:version="400" sparkle:shortVersionString="3.0"/></item>
        """,
    ])

    /// Builds only, no short versions.
    static let buildsOnlyAppcast = appcast([
        "<item><enclosure url=\"https://current.example/a.zip\" sparkle:version=\"345\"/></item>",
        "<item><sparkle:version>346</sparkle:version><enclosure url=\"https://current.example/b.zip\"/></item>",
    ])

    static let caskJSON = Data(
        """
        [
          {"token": "brewed", "version": "1.5,77", "homepage": "https://brewed.example/",
           "artifacts": [{"app": ["Brewed.app"], "target": "/Applications/Brewed.app"}], "disabled": false},
          {"token": "zapped", "version": "3.2.0", "homepage": "https://zapped.example/",
           "artifacts": [{"uninstall": [{"quit": "com.zapped.app"}]}, {"app": ["Zapped.app"]},
                         {"zap": [{"trash": ["~/Library/Preferences/com.zapped.app.plist"]}]}]},
          {"token": "lookalike", "version": "9.0", "homepage": "https://other.example/",
           "artifacts": [{"app": ["Lookalike.app"]}, {"zap": [{"trash": ["~/Library/Caches/com.other.vendor"]}]}]},
          {"token": "renamed", "version": "2.0", "homepage": "http://insecure.example/",
           "artifacts": [{"app": ["Source.app", {"target": "Renamed.app"}], "target": "/Applications/Renamed.app"}]},
          {"token": "gone", "version": "1.0", "disabled": true, "artifacts": [{"app": ["Gone.app"]}]},
          {"token": "nightly", "version": "latest", "artifacts": [{"app": ["Nightly.app"]}]},
          {"token": "zapped@beta", "version": "4.0b1", "artifacts": [{"app": ["Zapped.app"]},
                         {"zap": [{"trash": ["~/Library/Preferences/com.zapped.app.plist"]}]}]},
          {"token": "pkgonly", "name": ["Pkg Thing"], "version": "7.1", "homepage": "https://pkg.example/",
           "desc": "Tricky \\"quoted\\" text with } and ] and { inside",
           "artifacts": [{"uninstall": [{"quit": ["com.pkg.agent", "com.pkg.Installer"], "pkgutil": "com.pkg"}]},
                         {"pkg": ["Pkg.pkg"]}]},
          {"token": "layered", "version": "5.0", "homepage": "https://layered.example/",
           "depends_on": {"macos": {">=": ["13"]}},
           "variations": {"arm64_sonoma": {"version": "4.2", "url": "https://x"}, "sonoma": {"version": "4.1"},
                          "sequoia": {"url": "https://y"}},
           "artifacts": [{"app": ["Layered.app"]}, {"zap": [{"trash": ["~/Library/Caches/com.layered.app"]}]}]},
          {"token": "future", "version": "9.0", "depends_on": {"macos": {">=": ["30"]}},
           "artifacts": [{"app": ["Future.app"]}, {"uninstall": [{"quit": "com.future.app"}]}]},
          {"token": "headset-suite", "name": ["Headset Suite"], "version": "8.3",
           "artifacts": [{"uninstall": [{"quit": ["com.headset.suite", "nl.superalloy.oss.terminal-notifier"],
                                         "pkgutil": "com.headset.suite", "delete": "/Applications/Headset Suite.app"}]},
                         {"pkg": ["Setup.pkg"]}]},
          {"token": "meetings", "name": ["Meetings"], "version": "7.2.2.88465", "homepage": "https://meet.example/",
           "artifacts": [{"uninstall": [{"signal": ["KILL", "us.meet.xos"], "pkgutil": "us.meet.pkg",
                                         "delete": ["/Applications/meet.us.app", "/Library/Logs/meet*"]}]},
                         {"pkg": ["meet.pkg"]}]},
          {"token": "meetings-admins", "name": ["Meetings for Admins"], "version": "7.2.2.88465",
           "artifacts": [{"uninstall": [{"signal": ["KILL", "us.meet.xos"], "pkgutil": "us.meet.pkg",
                                         "delete": "/Applications/meet.us.app"}]}, {"pkg": ["meet-admin.pkg"]}]},
          {"token": "office-suite", "name": ["Office Suite"], "version": "16.1",
           "artifacts": [{"uninstall": [{"quit": "com.vendor.autoupdate", "pkgutil": ["com.vendor.word"],
                                         "delete": "/Applications/Team Chat.app"}]}, {"pkg": ["office.pkg"]}]},
          {"token": "team-chat", "name": ["Team Chat"], "version": "26.1",
           "artifacts": [{"uninstall": [{"quit": "com.vendor.autoupdate", "pkgutil": ["com.vendor.teamchat2"],
                                         "delete": "/Applications/Team Chat.app"}]}, {"pkg": ["chat.pkg"]}]},
          {"token": "dup-one", "version": "2.0", "artifacts": [{"uninstall": [{"delete": "/Applications/Dup.app"}]},
                         {"pkg": ["a.pkg"]}]},
          {"token": "dup-two", "version": "3.0", "artifacts": [{"uninstall": [{"delete": "/Applications/Dup.app"}]},
                         {"pkg": ["b.pkg"]}]},
          {"token": "intel-only", "version": "4.0", "depends_on": {"arch": [{"type": "intel", "bits": 64}]},
           "artifacts": [{"app": ["Intel Only.app"]}]}
        ]
        """.utf8)

    static func itunes(_ results: [(String, String, Int)]) -> Data {
        let items = results.map {
            "{\"bundleId\": \"\($0.0)\", \"version\": \"\($0.1)\", \"trackId\": \($0.2), \"trackViewUrl\": \"https://apps.apple.com/us/app/x/id\($0.2)\"}"
        }
        return Data("{\"resultCount\": \(results.count), \"results\": [\(items.joined(separator: ","))]}".utf8)
    }

    static func handler(
        store: [(String, String, Int)] = [("com.storey.app", "2.0.1", 42), ("com.storesame.app", "2.0", 43)]
    ) -> MockHTTP.Handler {
        { url in
            switch url.host() {
            case "feedy.example": return feedyAppcast
            case "current.example": return buildsOnlyAppcast
            case "formulae.brew.sh": return caskJSON
            case "itunes.apple.com": return itunes(store)
            case "broken.example": throw HTTPError.status(500)
            case "html.example": return Data("<html><body>Not a feed".utf8)
            default: throw URLError(.cannotFindHost)
            }
        }
    }

    func status(_ report: UpdateReport, _ name: String) -> UpdateStatus? {
        report.updates.first { $0.app.name == name }?.status
    }

    // MARK: - Version comparison

    @Test("Version compare: 1.10 > 1.9, 2.0 == 2.0.0, builds in brackets, pre-releases")
    func versionCompare() {
        #expect(VersionCompare.compare("1.10", "1.9") == .orderedDescending)
        #expect(VersionCompare.compare("1.9", "1.10") == .orderedAscending)
        #expect(VersionCompare.compare("2.0", "2.0.0") == .orderedSame)
        #expect(VersionCompare.compare("2.0.0", "2") == .orderedSame)
        #expect(VersionCompare.compare("2.0.1", "2.0") == .orderedDescending)
        #expect(VersionCompare.compare("1.2 (345)", "1.2 (346)") == .orderedAscending)
        #expect(VersionCompare.compare("1.2 (345)", "1.2") == .orderedSame)
        #expect(VersionCompare.compare("1.3 (1)", "1.2 (999)") == .orderedDescending)
        #expect(VersionCompare.compare("v3.1", "3.1") == .orderedSame)
        #expect(VersionCompare.compare("2.0b4", "2.0") == .orderedAscending)
        #expect(VersionCompare.compare("2.0-beta.2", "2.0-beta.1") == .orderedDescending)
        #expect(VersionCompare.compare("1.5,77", "1.5") == .orderedSame)
        #expect(VersionCompare.compare("7.2.2 (88465)", "7.2.2.88465") == .orderedSame)
        #expect(VersionCompare.compare("7.2.2.88465", "7.2.2 (88465)") == .orderedSame)
        #expect(VersionCompare.compare("7.2.2 (88464)", "7.2.2.88465") == .orderedAscending)
        #expect(VersionCompare.compare("7.1.9 (88375)", "7.2.2.88465") == .orderedAscending)
        #expect(VersionCompare.compare("1.05", "1.5") == .orderedSame)
        #expect(VersionCompare.compare("2026.01.39", "2025.12.1") == .orderedDescending)
        #expect(VersionCompare.isNewer("346", than: "345"))
        #expect(!VersionCompare.isNewer("345", than: "345"))
        #expect(VersionCompare.parse("1.5,77") == .init(main: ["1", "5"], build: ["77"]))
    }

    // MARK: - Appcast parsing

    @Test("Appcast: newest default-channel item for this macOS, from elements or enclosure attributes")
    func appcastNewest() throws {
        let items = try #require(AppcastParser.parse(Self.feedyAppcast))
        #expect(items.count == 4)
        #expect(items[1].channel == "beta")
        let system = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        let newest = try #require(AppcastParser.newest(in: items, systemVersion: system))
        #expect(newest.version == "210")
        #expect(newest.shortVersion == "1.10")
        // On macOS 15 the 3.0 item counts.
        let later = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        #expect(AppcastParser.newest(in: items, systemVersion: later)?.shortVersion == "3.0")

        let builds = try #require(AppcastParser.parse(Self.buildsOnlyAppcast))
        #expect(AppcastParser.newest(in: builds, systemVersion: system)?.version == "346")
        #expect(AppcastParser.parse(Data("<html><body>nope".utf8)) == nil)
    }

    // MARK: - Cask index

    @Test("Cask list: only needed fields; renamed targets, disabled and 'latest' casks, zap bundle IDs")
    func caskIndex() throws {
        let index = try CaskIndex.fromAPI(Self.caskJSON, fetchedAt: Date())
        let tokens = index.casks.map(\.token)
        #expect(
            tokens == [
                "brewed", "zapped", "lookalike", "renamed", "zapped@beta", "pkgonly", "layered", "future",
                "headset-suite", "meetings", "meetings-admins", "office-suite", "team-chat", "dup-one", "dup-two",
                "intel-only",
            ])
        let meetings = try #require(index.casks.first { $0.token == "meetings" })
        #expect(meetings.appPaths == ["meet.us.app"])
        #expect(meetings.pkgIDs == ["us.meet.pkg"])
        #expect(meetings.names == ["Meetings"])
        let intel = try #require(index.casks.first { $0.token == "intel-only" })
        #expect(intel.archs == ["intel"])
        let pkg = try #require(index.casks.first { $0.token == "pkgonly" })
        #expect(pkg.apps.isEmpty)
        #expect(pkg.quitIDs == ["com.pkg.agent", "com.pkg.installer"])
        let layered = try #require(index.casks.first { $0.token == "layered" })
        #expect(layered.variations == ["arm64_sonoma": "4.2", "sonoma": "4.1"])
        #expect(layered.minimumMacOS == "13")
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        #expect(intel.version(for: tahoe, arm64: true) == nil)
        #expect(intel.version(for: tahoe, arm64: false) == "4.0")
        #expect(layered.version(for: sonoma, arm64: true) == "4.2")
        #expect(layered.version(for: sonoma, arm64: false) == "4.1")
        #expect(layered.version(for: tahoe, arm64: true) == "5.0")
        let future = try #require(index.casks.first { $0.token == "future" })
        #expect(future.version(for: tahoe) == nil)
        #expect(throws: (any Error).self) { try CaskIndex.fromAPI(Data("{\"a\": 1}".utf8), fetchedAt: Date()) }
        let renamed = try #require(index.casks.first { $0.token == "renamed" })
        #expect(renamed.apps == ["Renamed.app"])
        let zapped = try #require(index.casks.first { $0.token == "zapped" })
        #expect(zapped.bundleIDs == ["com.zapped.app"])
        #expect(CaskIndex.isReverseDNS("com.foo.Bar"))
        #expect(CaskIndex.isReverseDNS("md.obsidian"))
        #expect(!CaskIndex.isReverseDNS("Obsidian"))
        #expect(!CaskIndex.isReverseDNS("My App.app"))
    }

    // MARK: - End to end

    @Test("Outdated, up to date and can't-check are reported per source")
    func endToEnd() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let apps = [
            try fixture.app(
                "Feedy", id: "com.feedy.app", short: "1.9", build: "190", feed: "https://feedy.example/cast.xml"),
            try fixture.app(
                "Current", id: "com.current.app", short: "3.4", build: "346", feed: "https://current.example/a"),
            try fixture.app(
                "Plain", id: "com.plain.app", short: "1.0", build: "1", feed: "http://plain.example/cast.xml"),
            try fixture.app("Storey", id: "com.storey.app", short: "2.0", build: "200", appStore: true),
            try fixture.app("StoreSame", id: "com.storesame.app", short: "2.0.0", build: "5", appStore: true),
            try fixture.app("StoreGone", id: "com.storegone.app", short: "1.0", build: "1", appStore: true),
            try fixture.app("Brewed", id: "com.brewed.app", short: "1.4", build: "70"),
            try fixture.app("Zapped", id: "com.zapped.app", short: "3.2", build: "320"),
            try fixture.app("Lookalike", id: "com.lookalike.app", short: "1.0", build: "1"),
            try fixture.app("Mystery", id: "com.mystery.app", short: "0.1", build: "1"),
            try fixture.app("Broken", id: "com.broken.app", short: "1.0", build: "1", feed: "https://broken.example/x"),
            try fixture.app("Html", id: "com.html.app", short: "1.0", build: "1", feed: "https://html.example/x"),
        ]
        try fixture.brewInstalled("brewed", version: "1.4,70")
        let http = MockHTTP(handler: Self.handler())
        let report = await fixture.checker(http: http).check(apps)

        #expect(report.updates.count == apps.count)
        #expect(status(report, "Feedy") == .available("1.10"))
        #expect(status(report, "Current") == .upToDate)
        #expect(status(report, "Plain") == .cantCheck(.insecureFeed))
        #expect(status(report, "Storey") == .available("2.0.1"))
        #expect(status(report, "StoreSame") == .upToDate)
        #expect(status(report, "StoreGone") == .cantCheck(.notInStore))
        #expect(status(report, "Brewed") == .available("1.5"))
        #expect(status(report, "Zapped") == .upToDate)
        #expect(status(report, "Lookalike") == .cantCheck(.noSource))
        #expect(status(report, "Mystery") == .cantCheck(.noSource))
        #expect(status(report, "Broken") == .cantCheck(.failed))
        #expect(status(report, "Html") == .cantCheck(.feedUnreadable))
        #expect(!report.offline)

        let byName = Dictionary(uniqueKeysWithValues: report.updates.map { ($0.app.name, $0) })
        #expect(byName["Feedy"]?.source == .sparkle)
        #expect(byName["Feedy"]?.open == .app(apps[0].url))
        #expect(byName["Storey"]?.source == .appStore)
        #expect(byName["Storey"]?.open == .appStore(URL(string: "macappstore://apps.apple.com/app/id42")!))
        #expect(byName["Brewed"]?.source == .homebrew)
        #expect(byName["Brewed"]?.brewToken == "brewed")
        #expect(byName["Brewed"]?.open == .web(URL(string: "https://brewed.example/")!))
        #expect(byName["Zapped"]?.brewToken == nil)
        #expect(byName["Mystery"]?.source == nil)

        // The http feed is never requested; App Store apps go in one batched lookup.
        #expect(!http.requests.contains { $0.scheme == "http" })
        #expect(http.count(host: "plain.example") == 0)
        #expect(http.count(host: "itunes.apple.com") == 1)
        let lookup = try #require(http.requests.first { $0.host() == "itunes.apple.com" })
        #expect(lookup.query()?.contains("com.storey.app,com.storesame.app,com.storegone.app") == true)
        #expect(http.count(host: "formulae.brew.sh") == 1)
    }

    @Test("Installer casks match by the bundle ID they quit; variations and macOS minimums apply")
    func installerAndVariations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let apps = [
            try fixture.app("Pkg Thing", id: "com.pkg.Installer", short: "7.0", build: "70"),
            try fixture.app("Layered", id: "com.layered.app", short: "4.1", build: "41"),
            try fixture.app("Future", id: "com.future.app", short: "8.0", build: "80"),
        ]
        let report = await fixture.checker(http: MockHTTP(handler: Self.handler())).check(apps)
        #expect(status(report, "Pkg Thing") == .available("7.1"))
        // This checker runs as macOS 14.5: the sonoma variation applies, by CPU.
        #expect(status(report, "Layered") == (CaskEntry.isARM64 ? .available("4.2") : .upToDate))
        // 9.0 needs macOS 30: nothing to install here.
        #expect(status(report, "Future") == .upToDate)
    }

    @Test("Installer casks: a quit of another vendor's helper isn't enough; exact unique paths are")
    func installerSecondSign() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let apps = [
            // headset-suite quits terminal-notifier but has no other sign of it.
            try fixture.app("terminal-notifier", id: "nl.superalloy.oss.terminal-notifier", short: "2.0", build: "1"),
            // Named only by a deleted path (and a signal), like zoom.us.
            try fixture.app("meet.us", id: "us.meet.xos", short: "7.1.9 (88375)", build: "88375"),
            // Two casks delete /Applications/Dup.app: ambiguous unless Homebrew installed one.
            try fixture.app("Dup", id: "com.dup.app", short: "1.0", build: "1"),
            // office-suite and team-chat both delete /Applications/Team Chat.app; only team-chat's
            // package receipt is this bundle ID.
            try fixture.app("Team Chat", id: "com.vendor.teamchat2", short: "26.0", build: "1"),
        ]
        let report = await fixture.checker(http: MockHTTP(handler: Self.handler())).check(apps)
        #expect(status(report, "terminal-notifier") == .cantCheck(.noSource))
        // Two casks (meetings, meetings-admins) fit equally and offer the same version: either answers.
        #expect(status(report, "meet.us") == .available("7.2.2.88465"))
        #expect(report.updates.first { $0.app.name == "meet.us" }?.source == .homebrew)
        #expect(status(report, "Dup") == .cantCheck(.noSource))
        #expect(status(report, "Team Chat") == .available("26.1"))

        try fixture.brewInstalled("dup-two", version: "3.0")
        let brewed = await fixture.checker(http: MockHTTP(handler: Self.handler())).check([apps[2]])
        #expect(brewed.updates.first?.status == .available("3.0"))
        #expect(brewed.updates.first?.brewToken == "dup-two")

        // Same release written two ways: "7.2.2 (88465)" vs Homebrew's "7.2.2.88465".
        let current = try Fixture()
        defer { current.remove() }
        let meet = try current.app("meet.us", id: "us.meet.xos", short: "7.2.2 (88465)", build: "88465")
        let same = await current.checker(http: MockHTTP(handler: Self.handler())).check([meet])
        #expect(same.updates.first?.status == .upToDate)
    }

    @Test("Only apps no other source covers trigger the Homebrew list")
    func noCaskDownloadWhenNotNeeded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let apps = [
            try fixture.app("Feedy", id: "com.feedy.app", short: "1.9", build: "190", feed: "https://feedy.example/c"),
            try fixture.app("Storey", id: "com.storey.app", short: "2.0", build: "200", appStore: true),
        ]
        let http = MockHTTP(handler: Self.handler())
        let report = await fixture.checker(http: http).check(apps)
        #expect(report.outdated.count == 2)
        #expect(http.count(host: "formulae.brew.sh") == 0)
        #expect(report.caskListDate == nil)
    }

    @Test("A variant cask (zapped@beta) never matches unless Homebrew installed it")
    func variantCask() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Zapped", id: "com.zapped.app", short: "3.2", build: "320")
        try fixture.brewInstalled("zapped@beta", version: "4.0b1")
        let report = await fixture.checker(http: MockHTTP(handler: Self.handler())).check([app])
        #expect(report.updates.first?.brewToken == "zapped@beta")
        #expect(report.updates.first?.status == .available("4.0b1"))
    }

    @Test("App Store: a region miss is looked up again in the US store")
    func storeRegionFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Storey", id: "com.storey.app", short: "2.0", build: "200", appStore: true)
        let http = MockHTTP { url in
            let country = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "country" }?.value
            return country == "us" ? Self.itunes([("com.storey.app", "2.1", 42)]) : Self.itunes([])
        }
        let report = await fixture.checker(http: http, country: "th").check([app])
        #expect(report.updates.first?.status == .available("2.1"))
        #expect(http.count(host: "itunes.apple.com") == 2)
    }

    // MARK: - Cache

    @Test("Cask list is cached on disk for 24 hours, then downloaded again")
    func caskCacheTTL() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Brewed", id: "com.brewed.app", short: "1.4", build: "70")
        try fixture.brewInstalled("brewed", version: "1.4")
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = MockHTTP(handler: Self.handler())

        _ = await fixture.checker(http: http, clock: clock).check([app])
        #expect(http.count(host: "formulae.brew.sh") == 1)
        #expect(
            FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("homebrew-casks-v3.json").path))

        // A new checker (as after relaunching) 23 h later reads the disk copy.
        clock.advance(hours: 23)
        let second = await fixture.checker(http: http, clock: clock).check([app])
        #expect(http.count(host: "formulae.brew.sh") == 1)
        #expect(second.updates.first?.status == .available("1.5"))
        #expect(!second.caskListStale)

        // Past 24 h it's downloaded again, also by the same checker.
        let checker = fixture.checker(http: http, clock: clock)
        _ = await checker.check([app])
        clock.advance(hours: 2)
        _ = await checker.check([app])
        #expect(http.count(host: "formulae.brew.sh") == 2)
        #expect(!UpdateChecker.isFresh(Date(timeIntervalSince1970: 0), now: clock.now))
    }

    @Test("Offline: a stale cask list is used, feeds say offline, report is flagged")
    func offline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let apps = [
            try fixture.app("Brewed", id: "com.brewed.app", short: "1.4", build: "70"),
            try fixture.app("Feedy", id: "com.feedy.app", short: "1.9", build: "190", feed: "https://feedy.example/c"),
            try fixture.app("Mystery", id: "com.mystery.app", short: "0.1", build: "1"),
            try fixture.app("Storey", id: "com.storey.app", short: "2.0", build: "200", appStore: true),
        ]
        try fixture.brewInstalled("brewed", version: "1.4")
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        _ = await fixture.checker(http: MockHTTP(handler: Self.handler()), clock: clock).check(apps)
        clock.advance(hours: 30)

        let offline = MockHTTP { _ in throw URLError(.notConnectedToInternet) }
        let report = await fixture.checker(http: offline, clock: clock).check(apps)
        #expect(report.offline)
        #expect(report.caskListStale)
        #expect(status(report, "Brewed") == .available("1.5"))
        #expect(status(report, "Feedy") == .cantCheck(.offline))
        #expect(status(report, "Storey") == .cantCheck(.offline))
        #expect(status(report, "Mystery") == .cantCheck(.noSource))

        // No cache at all: apps without a source say offline rather than "no source".
        try? FileManager.default.removeItem(at: fixture.cache)
        let bare = await fixture.checker(http: offline, clock: clock).check(apps)
        #expect(status(bare, "Mystery") == .cantCheck(.offline))
        #expect(status(bare, "Brewed") == .cantCheck(.offline))
    }

    // MARK: - Rate limiting

    @Test("At most 4 requests at once, 2 per host")
    func rateLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var apps: [UpdateCandidate] = []
        for index in 0..<18 {
            let host = ["feedy.example", "current.example", "html.example"][index % 3]
            apps.append(
                try fixture.app(
                    "App\(index)", id: "com.app\(index).x", short: "1.0", build: "1", feed: "https://\(host)/\(index)"))
        }
        let http = MockHTTP(delay: .milliseconds(30), handler: Self.handler())
        let report = await fixture.checker(http: http).check(apps)
        #expect(report.updates.count == 18)
        #expect(http.requests.count == 18 + 1)  // + the cask list for the unreadable feeds
        #expect(http.maxInFlight <= 4)
        #expect(http.maxInFlightPerHost <= 2)
        #expect(http.maxInFlight >= 2)
    }

    @Test("Requests to one host are spaced out")
    func hostSpacing() async throws {
        let gate = RequestGate(maxConcurrent: 4, maxPerHost: 4, spacing: .milliseconds(60))
        let url = URL(string: "https://one.example/x")!
        let clock = ContinuousClock()
        let starts = await withTaskGroup(of: ContinuousClock.Instant.self, returning: [ContinuousClock.Instant].self) {
            group in
            for _ in 0..<4 {
                group.addTask { (try? await gate.run(url) { clock.now }) ?? clock.now }
            }
            var starts: [ContinuousClock.Instant] = []
            for await start in group { starts.append(start) }
            return starts.sorted()
        }
        for (a, b) in zip(starts, starts.dropFirst()) {
            #expect(b - a >= .milliseconds(50))
        }
    }

    @Test("Timeouts bound the whole transfer: 15 s for feeds and lookups, 90 s for the cask list")
    func timeouts() {
        let client = URLSessionHTTPClient()
        let feed = client.sessionConfiguration(timeout: UpdateLimits.requestTimeout)
        #expect(feed.timeoutIntervalForResource == 15)
        #expect(feed.timeoutIntervalForRequest == 15)
        let casks = client.sessionConfiguration(timeout: UpdateLimits.downloadTimeout)
        #expect(casks.timeoutIntervalForResource == 90)
        #expect(casks.timeoutIntervalForRequest == 15)
        #expect(casks.httpCookieAcceptPolicy == .never)
    }

    @Test("The real client refuses plain http before any connection")
    func httpRejected() async {
        await #expect(throws: HTTPError.notHTTPS) {
            _ = try await URLSessionHTTPClient().get(
                URL(string: "http://example.invalid/appcast.xml")!, timeout: 1, maxBytes: 10)
        }
    }

    // MARK: - Model

    @Test("The tab checks once when opened, again only after an hour or on request; Open goes to the right place")
    @MainActor
    func model() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let feedy = try fixture.app(
            "Feedy", id: "com.feedy.app", short: "1.9", build: "190", feed: "https://feedy.example/c")
        let storey = try fixture.app("Storey", id: "com.storey.app", short: "2.0", build: "200", appStore: true)
        let mystery = try fixture.app("Mystery", id: "com.mystery.app", short: "0.1", build: "1")
        let records = [feedy, storey, mystery].map {
            AppRecord(
                bundleID: $0.bundleID, teamID: nil, name: $0.name, url: $0.url, version: "", size: 1, lastUsed: nil)
        }
        let clock = TestClock(Date())
        let http = MockHTTP(handler: Self.handler())
        let opener = RecordingOpener()
        let model = UpdatesModel(checker: fixture.checker(http: http, clock: clock), opener: opener, now: { clock.now })

        await model.tabOpened(apps: records)
        #expect(model.outdated.map(\.app.name) == ["Feedy", "Storey"])
        #expect(model.cantCheck.map(\.app.name) == ["Mystery"])
        #expect(model.headline == "2 updates available")
        #expect(model.summary == "2 of 3 apps checked · 1 can't be checked")
        let firstCount = http.requests.count

        await model.tabOpened(apps: records)
        #expect(http.requests.count == firstCount)
        clock.advance(hours: 2)
        await model.tabOpened(apps: records)
        #expect(http.requests.count > firstCount)

        model.open(model.outdated[0])
        model.open(model.outdated[1])
        #expect(opener.opened == [feedy.url, URL(string: "macappstore://apps.apple.com/app/id42")!])
        #expect(CantCheckReason.noSource.explanation.contains("No update feed"))

        // A web target that isn't https is never opened.
        let insecure = AppUpdate(
            app: mystery, installedVersion: "0.1", status: .available("1"), source: .homebrew,
            open: .web(URL(string: "http://insecure.example")!), brewToken: nil)
        model.open(insecure)
        #expect(opener.opened.count == 2)

        // The partial-check notice: no connection vs an old Homebrew list.
        model.debugShow(
            UpdateReport(updates: [], offline: true, caskListDate: nil, caskListStale: false, checkedAt: clock.now))
        #expect(model.noticeSymbol == "wifi.slash")
        model.debugShow(
            UpdateReport(
                updates: [], offline: false, caskListDate: clock.now.addingTimeInterval(-90_000), caskListStale: true,
                checkedAt: clock.now))
        #expect(model.noticeSymbol == "clock.arrow.circlepath")
        #expect(model.notice?.contains("couldn't be refreshed") == true)
    }
}
