import Foundation
import Testing

@testable import Dustpan

/// Copy review (CLAUDE.md Conventions → Copy, Don'ts): no scare words, no "speed up" or "free
/// RAM" promises, no licence/trial talk (Dustpan is free), and no other product's name anywhere
/// in the app, its rules or its built bundle.
@Suite("Copy")
struct CopyTests {
    /// Banned in anything a user can read. Case-insensitive regular expressions.
    static let bannedCopy = [
        "junk-infested", "threats? detected", "speed up", "speeds up", "optimi[sz]", "free (up )?ram", "boost",
        // Paywall talk only: naming Dustpan's open-source licence (Settings › About) is fine.
        "licen[cs]e (key|code)", "(activate|enter|buy) (a |your )?licen[cs]e", "unlicensed", "free trial",
        "trial (period|ends|expired)", "purchase", "buy now", "upgrade to",
    ]
    /// Banned anywhere in the app's sources, rules and bundle (not only in visible strings).
    static let bannedNames = ["clean ?my ?mac", "macpaw"]

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every app source file (DEBUG-only helpers included: they ship in no release, but their
    /// copy still shows up in screenshots).
    static func sources() -> [URL] {
        ["App", "Core", "Features", "DesignSystem"].flatMap { folder -> [URL] in
            let base = repo.appendingPathComponent(folder)
            let names = FileManager.default.enumerator(atPath: base.path)?.compactMap { $0 as? String } ?? []
            return names.filter { $0.hasSuffix(".swift") }.map { base.appendingPathComponent($0) }
        }
    }

    /// String literals in a Swift file (single-line ones; interpolations kept as text).
    static func literals(in text: String) -> [String] {
        text.matches(of: #/"(?:[^"\\\n]|\\.)*"/#).map { String(text[$0.range]) }
            .filter { $0.contains(" ") }  // words, not keys or identifiers
    }

    static func hits(_ text: String, _ patterns: [String]) -> [String] {
        patterns.filter { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    @Test("Every rule's title and explanation is free of banned words and reads as a sentence")
    func rules() async throws {
        let rules = try await RuleCatalog().rules()
        #expect(rules.count > 100)
        for rule in rules {
            let text = rule.title + " " + rule.why
            #expect(Self.hits(text, Self.bannedCopy + Self.bannedNames).isEmpty, "\(rule.id): \(text)")
            #expect(rule.why.count <= 140, "\(rule.id) explanation is longer than 140 characters")
            // A sentence: a capital first, unless it opens with a name like "iCloud" or ".NET".
            let firstWord = rule.why.split(separator: " ").first.map(String.init) ?? ""
            #expect(
                rule.why.first?.isLowercase == false || firstWord.contains(where: \.isUppercase),
                "\(rule.id) explanation should start a sentence")
            #expect(rule.why.hasSuffix("."), "\(rule.id) explanation should end with a full stop")
            #expect(!rule.why.contains("`"), "\(rule.id): no code formatting in plain words")
            #expect(rule.why.range(of: #"\ba [aeiouAEIOU]"#, options: .regularExpression) == nil, "\(rule.id): a/an")
        }
    }

    @Test("User-facing strings in the sources are free of banned words")
    func sourceStrings() throws {
        let files = Self.sources()
        #expect(files.count > 50)
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.literals(in: text) {
                let bad = Self.hits(literal, Self.bannedCopy)
                if !bad.isEmpty { found.append("\(file.lastPathComponent): \(literal)") }
            }
            for name in Self.hits(text, Self.bannedNames) { found.append("\(file.lastPathComponent) mentions \(name)") }
        }
        // `SkipReason`, `DustpanError` and every other explanation are covered: they are literals.
        #expect(found.isEmpty, "\(found)")
    }

    @Test("Error messages and skip reasons are free of banned words")
    func explanations() {
        let errors: [DustpanError] = [
            .databaseUnavailable, .diskSpaceUnavailable, .rulesInvalid("x"), .trashUnreadable, .trashNotEmptied,
            .cleanupNotLogged, .putBackFailed(2), .ignoreNotSaved, .appDidNotQuit("App"),
            .notMoved("It's already gone."),
            .folderNotAllowed, .sweepPartly(["Junk"]),
        ]
        let reasons: [SkipReason] = [
            .detectionOnly, .protected, .leavesRuleRoot, .isSymlink, .appRunning("App"), .unknownRule, .notFound,
            .moveFailed, .ruleMismatch, .tooRecent, .ignored, .needsFullDiskAccess, .changedDuringClean, .notAnApp,
            .appleApp, .notALeftover, .needsHelper, .appNotRemoved, .appMoveFailed, .homeFolder, .outsideHome,
            .dustpanItself, .insideApp, .alreadyInTrash, .pathMismatch, .notAFile, .insidePackage, .cloudOnly,
            .lastCopy, .keeperMissing, .contentChanged, .appDatabaseFolder, .neverTouched,
        ]
        let texts = errors.compactMap(\.errorDescription) + reasons.map(\.explanation)
        for text in texts {
            #expect(Self.hits(text, Self.bannedCopy + Self.bannedNames).isEmpty, "\(text)")
            #expect(text.hasSuffix(".") || text.hasSuffix("?"), "\(text)")
        }
    }

    @Test("The built app bundle never names another cleaner or its maker")
    func bundle() throws {
        let app = Bundle.main.bundleURL
        #expect(app.pathExtension == "app")
        let plugIns = app.appendingPathComponent("Contents/PlugIns").path
        let files =
            FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? []
        // Byte search (fast) for the spellings a name could take.
        let needles = ["CleanMyMac", "cleanmymac", "CLEANMYMAC", "Clean My Mac", "MacPaw", "macpaw", "MACPAW"]
            .map { Data($0.utf8) }
        // The MIT licence requires PermissionsKit's copyright line in the shipped notices, so that
        // one file may carry the maker's name in exactly those two places and nowhere else.
        let requiredNotice = ["Copyright (c) 2018 MacPaw", "github.com/MacPaw/PermissionsKit"]
        var checked = 0
        for file in files where !file.path.hasPrefix(plugIns) {  // the test bundle itself is in PlugIns
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                var data = try? Data(contentsOf: file, options: .alwaysMapped)
            else { continue }
            if file.lastPathComponent == "THIRD_PARTY_NOTICES.md" {
                var text = String(decoding: data, as: UTF8.self)
                for notice in requiredNotice {
                    #expect(text.contains(notice), "notices lost \(notice)")
                    text = text.replacingOccurrences(of: notice, with: "")
                }
                data = Data(text.utf8)
            }
            checked += 1
            for needle in needles {
                #expect(
                    data.range(of: needle) == nil,
                    "\(file.lastPathComponent) contains \(String(decoding: needle, as: UTF8.self))")
            }
        }
        #expect(checked > 3)
        let info = Bundle.main.infoDictionary?.values.compactMap { $0 as? String }.joined(separator: " ") ?? ""
        #expect(Self.hits(info, Self.bannedCopy + Self.bannedNames).isEmpty)
    }
}
