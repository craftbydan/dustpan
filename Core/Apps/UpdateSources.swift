import Foundation

// MARK: - Sparkle appcasts

/// One `<item>` of a Sparkle appcast.
struct AppcastItem: Sendable, Equatable {
    /// `sparkle:version`: the build, compared with the app's `CFBundleVersion`.
    var version: String?
    /// `sparkle:shortVersionString`: what people see.
    var shortVersion: String?
    /// `sparkle:channel`; nil is the default channel everyone gets.
    var channel: String?
    var minimumSystemVersion: String?
}

/// Reads a Sparkle appcast with `XMLParser`. Versions come from the item's `sparkle:*` elements or,
/// as in older feeds, from the `enclosure`'s attributes.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var depth = 0
    private var itemDepth = 0

    static func parse(_ data: Data) -> [AppcastItem]? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.items
    }

    /// The newest item a user on the default channel and this macOS would be offered. Items in a
    /// named channel (beta, nightly, …) and items for a newer macOS are skipped.
    static func newest(
        in items: [AppcastItem], systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> AppcastItem? {
        let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        return
            items
            .filter { ($0.channel ?? "").isEmpty }
            .filter { $0.version != nil || $0.shortVersion != nil }
            .filter { item in
                guard let minimum = item.minimumSystemVersion, !minimum.isEmpty else { return true }
                return VersionCompare.compare(minimum, system) != .orderedDescending
            }
            .max { a, b in
                // Builds first (what Sparkle compares), then the visible version.
                if let left = a.version, let right = b.version {
                    let builds = VersionCompare.compare(left, right)
                    if builds != .orderedSame { return builds == .orderedAscending }
                }
                return VersionCompare.compare(a.shortVersion ?? a.version ?? "", b.shortVersion ?? b.version ?? "")
                    == .orderedAscending
            }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        depth += 1
        text = ""
        let name = elementName.lowercased()
        if name == "item" {
            current = AppcastItem()
            itemDepth = depth
        } else if name == "enclosure", current != nil {
            if current?.version == nil, let value = attributes["sparkle:version"], !value.isEmpty {
                current?.version = value
            }
            if current?.shortVersion == nil, let value = attributes["sparkle:shortVersionString"], !value.isEmpty {
                current?.shortVersion = value
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        if current != nil, let string = String(data: cdataBlock, encoding: .utf8) { text += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        defer {
            depth -= 1
            text = ""
        }
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "item" where depth == itemDepth:
            if let item = current { items.append(item) }
            current = nil
        case "sparkle:version" where !value.isEmpty: current?.version = value
        case "sparkle:shortversionstring" where !value.isEmpty: current?.shortVersion = value
        case "sparkle:channel": current?.channel = value
        case "sparkle:minimumsystemversion" where !value.isEmpty: current?.minimumSystemVersion = value
        default: break
        }
    }
}

// MARK: - Homebrew casks

/// The few facts Dustpan keeps about each cask (the full list is ~19 MB; this is well under 1 MB).
struct CaskEntry: Codable, Sendable, Equatable {
    let token: String
    /// App bundle names the cask installs ("Visual Studio Code.app"). Empty for installer-only casks.
    let apps: [String]
    /// Reverse-DNS IDs named in its `uninstall`/`zap` stanzas (quit, launchctl, deleted paths).
    let bundleIDs: [String]
    /// The bundle IDs its `uninstall` stanza quits or signals. Not proof on its own: some casks quit other
    /// vendors' helpers (e.g. `terminal-notifier`).
    let quitIDs: [String]
    /// The cask's display names ("Cloudflare WARP").
    let names: [String]
    /// `.app` names under `/Applications/` that its uninstall/zap stanzas delete, signal or run from.
    let appPaths: [String]
    /// Package receipt IDs its `uninstall` stanza forgets (`pkgutil`).
    let pkgIDs: [String]
    /// `depends_on arch` ("arm", "intel"); empty when any CPU will do.
    let archs: [String]
    let version: String
    let homepage: String?
    /// Older-system versions by Homebrew's variation key (`sequoia`, `arm64_sonoma`, …).
    let variations: [String: String]
    /// `depends_on macos: >=`, when given ("13").
    let minimumMacOS: String?

    /// The version Homebrew offers on this Mac: a variation for this macOS and CPU when the cask
    /// has one, else the main version (which is for the newest macOS). Nil when it needs a newer
    /// macOS or another CPU: there's nothing Homebrew would install here.
    func version(
        for system: OperatingSystemVersion, arm64: Bool = CaskEntry.isARM64
    ) -> String? {
        if !archs.isEmpty, !archs.contains(arm64 ? "arm" : "intel") { return nil }
        if let minimumMacOS,
            VersionCompare.compare(minimumMacOS, "\(system.majorVersion).\(system.minorVersion)")
                == .orderedDescending
        {
            return nil
        }
        if let name = Self.codenames[system.majorVersion],
            let variation = variations[(arm64 ? "arm64_" : "") + name]
        {
            return variation
        }
        return version
    }

    static let codenames: [Int: String] = [
        11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe",
    ]

    static var isARM64: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }
}

/// What is cached on disk: the slim index and when it was downloaded.
struct CaskIndex: Codable, Sendable {
    var fetchedAt: Date
    var casks: [CaskEntry]

    /// Reads Homebrew's `cask.json` one cask at a time: the top-level array is split into its
    /// objects with a byte scan, and each object is decoded on its own (only the fields Dustpan
    /// needs), so the whole document is never held as one decoded tree.
    static func fromAPI(_ data: Data, fetchedAt: Date) throws -> CaskIndex {
        let decoder = JSONDecoder()
        var casks: [CaskEntry] = []
        var sawArray = false
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var depth = 0
            var inString = false
            var escaped = false
            var start = -1
            for index in 0..<bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {  // backslash
                        escaped = true
                    } else if byte == 0x22 {  // quote
                        inString = false
                    }
                    continue
                }
                switch byte {
                case 0x22: inString = true
                case 0x5B, 0x7B:  // [ {
                    if depth == 0 {
                        guard byte == 0x5B else {
                            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not an array"))
                        }
                        sawArray = true
                    } else if depth == 1 {
                        start = index
                    }
                    depth += 1
                case 0x5D, 0x7D:  // ] }
                    depth -= 1
                    if depth == 1, byte == 0x7D, start >= 0 {
                        let slice = Data(UnsafeRawBufferPointer(rebasing: raw[start...index]))
                        start = -1
                        if let cask = try? decoder.decode(RawCask.self, from: slice), let entry = entry(from: cask) {
                            casks.append(entry)
                        }
                    }
                default: break
                }
            }
        }
        guard sawArray else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Empty")) }
        return CaskIndex(fetchedAt: fetchedAt, casks: casks)
    }

    private static func entry(from cask: RawCask) -> CaskEntry? {
        guard cask.disabled != true, let version = cask.version, version != "latest" else { return nil }
        var apps: [String] = []
        var ids = Set<String>()
        var quits = Set<String>()
        var pkgs = Set<String>()
        var paths = Set<String>()
        for artifact in cask.artifacts ?? [] {
            guard case .object(let fields) = artifact else { continue }
            if case .array(let entries)? = fields["app"] {
                // `["Thorium.app", {"target": "Thorium Browser.app"}]` installs the second name.
                let targets = entries.compactMap { entry -> String? in
                    if case .object(let options) = entry, case .string(let target)? = options["target"] {
                        return lastComponent(target)
                    }
                    return nil
                }
                if targets.isEmpty {
                    for case .string(let source) in entries { apps.append(lastComponent(source)) }
                } else {
                    apps.append(contentsOf: targets)
                }
                if case .string(let target)? = fields["target"] { apps.append(lastComponent(target)) }
            }
            for key in ["uninstall", "zap"] {
                fields[key].map { collectIDs($0, into: &ids) }
            }
            fields["uninstall"].map { collectQuits($0, into: &quits) }
            fields["uninstall"].map { collectStrings(under: "pkgutil", in: $0, into: &pkgs) }
            for key in ["uninstall", "zap"] {
                fields[key].map { collectAppPaths($0, into: &paths) }
            }
        }
        let names = Array(Set(apps.filter { $0.lowercased().hasSuffix(".app") })).sorted()
        // Installer-only casks are kept only if they name the app some way.
        guard !names.isEmpty || !quits.isEmpty || !paths.isEmpty else { return nil }
        var variations: [String: String] = [:]
        for (key, value) in cask.variations ?? [:] {
            if let version = value.version, version != "latest" { variations[key] = version }
        }
        return CaskEntry(
            token: cask.token, apps: names, bundleIDs: ids.sorted(), quitIDs: quits.sorted(),
            names: cask.name ?? [], appPaths: paths.sorted(), pkgIDs: pkgs.sorted(),
            archs: (cask.dependsOn?.arch ?? []).compactMap(\.type).map { $0.lowercased() }, version: version,
            homepage: cask.homepage, variations: variations,
            minimumMacOS: cask.dependsOn?.macos?.atLeast?.first.flatMap { $0.first?.isNumber == true ? $0 : nil })
    }

    /// `uninstall: [{quit: "com.foo.Bar"}]`, `quit: ["a", "b"]` or `signal: ["KILL", "com.foo.Bar"]`.
    private static func collectQuits(_ value: JSONValue, into quits: inout Set<String>) {
        switch value {
        case .array(let values): values.forEach { collectQuits($0, into: &quits) }
        case .object(let fields):
            for (key, field) in fields {
                if key == "quit" || key == "signal" {
                    switch field {
                    case .string(let id) where isReverseDNS(id): quits.insert(id.lowercased())
                    case .array(let values):
                        // `signal: ["KILL", "us.zoom.xos"]`: only the IDs.
                        for case .string(let id) in values where isReverseDNS(id) { quits.insert(id.lowercased()) }
                    default: break
                    }
                } else {
                    collectQuits(field, into: &quits)
                }
            }
        default: break
        }
    }

    /// Every string under `key` (lower-cased), at any depth.
    private static func collectStrings(under key: String, in value: JSONValue, into found: inout Set<String>) {
        switch value {
        case .array(let values): values.forEach { collectStrings(under: key, in: $0, into: &found) }
        case .object(let fields):
            for (name, field) in fields {
                if name == key {
                    switch field {
                    case .string(let text): found.insert(text.lowercased())
                    case .array(let values):
                        for case .string(let text) in values { found.insert(text.lowercased()) }
                    default: break
                    }
                } else {
                    collectStrings(under: key, in: field, into: &found)
                }
            }
        default: break
        }
    }

    /// "zoom.us.app" from `/Applications/zoom.us.app` or `/Applications/X.app/Contents/…`; globs skipped.
    private static func collectAppPaths(_ value: JSONValue, into paths: inout Set<String>) {
        switch value {
        case .string(let string):
            let prefix = "/Applications/"
            guard string.hasPrefix(prefix) else { return }
            let first = string.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if first.lowercased().hasSuffix(".app"), !first.contains("*") { paths.insert(first) }
        case .array(let values): values.forEach { collectAppPaths($0, into: &paths) }
        case .object(let fields): fields.values.forEach { collectAppPaths($0, into: &paths) }
        default: break
        }
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Reverse-DNS names inside strings such as `"com.foo.Bar"` or
    /// `"~/Library/Preferences/com.foo.Bar.plist"`.
    private static func collectIDs(_ value: JSONValue, into ids: inout Set<String>) {
        switch value {
        case .string(let string):
            var name = lastComponent(string)
            if name.hasPrefix("*.") { name.removeFirst(2) }
            for suffix in [".plist", ".savedState", ".binarycookies", ".sfl2", ".sfl3", ".sfl*", "*"]
            where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
            }
            if isReverseDNS(name) { ids.insert(name.lowercased()) }
        case .array(let values): values.forEach { collectIDs($0, into: &ids) }
        case .object(let fields): fields.values.forEach { collectIDs($0, into: &ids) }
        default: break
        }
    }

    static func isReverseDNS(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        // Two parts are allowed (`md.obsidian`, `notion.id`); a match also needs the app's exact name.
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    private struct RawCask: Decodable {
        struct Variation: Decodable {
            let version: String?
        }

        struct DependsOn: Decodable {
            struct MacOS: Decodable {
                let atLeast: [String]?
                enum CodingKeys: String, CodingKey { case atLeast = ">=" }
            }
            struct Arch: Decodable {
                let type: String?
            }
            let macos: MacOS?
            let arch: [Arch]?

            enum CodingKeys: String, CodingKey { case macos, arch }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                macos = try? container.decodeIfPresent(MacOS.self, forKey: .macos)
                arch = try? container.decodeIfPresent([Arch].self, forKey: .arch)
            }
        }

        let token: String
        let name: [String]?
        let version: String?
        let homepage: String?
        let disabled: Bool?
        let artifacts: [JSONValue]?
        let variations: [String: Variation]?
        let dependsOn: DependsOn?

        enum CodingKeys: String, CodingKey {
            case token, name, version, homepage, disabled, artifacts, variations
            case dependsOn = "depends_on"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = try container.decode(String.self, forKey: .token)
            name = try? container.decodeIfPresent([String].self, forKey: .name)
            version = try? container.decodeIfPresent(String.self, forKey: .version)
            homepage = try? container.decodeIfPresent(String.self, forKey: .homepage)
            disabled = try? container.decodeIfPresent(Bool.self, forKey: .disabled)
            artifacts = try? container.decodeIfPresent([JSONValue].self, forKey: .artifacts)
            variations = try? container.decodeIfPresent([String: Variation].self, forKey: .variations)
            dependsOn = try? container.decodeIfPresent(DependsOn.self, forKey: .dependsOn)
        }
    }
}

/// Just enough JSON to walk a cask's `artifacts` (mixed arrays, objects and strings).
enum JSONValue: Decodable, Sendable, Equatable {
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case other

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            self = .other
        }
    }
}

// MARK: - App Store

/// The iTunes Lookup API's answer (`/lookup?bundleId=a,b,c`).
struct ITunesLookup: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        let bundleId: String?
        let version: String?
        let trackViewUrl: String?
        let trackId: Int?
    }

    let results: [Result]
}
