import Foundation
import Testing

@testable import Dustpan

@Suite("Rule catalogue")
struct RuleCatalogTests {
    /// Validation is pure string checks against this fake home; nothing is read from disk.
    let protectedList = ProtectedList(home: URL(fileURLWithPath: "/Users/fixture"))

    private func bundledRules() throws -> [Rule] {
        let url = try #require(Bundle.main.url(forResource: "rules", withExtension: "json"))
        return try RuleCatalog.decode(try Data(contentsOf: url), protectedList: protectedList)
    }

    @Test("Bundled rules.json loads at least 120 valid rules")
    func bundledCatalogIsValid() throws {
        let rules = try bundledRules()
        #expect(rules.count >= 120)
        #expect(Set(rules.map(\.id)).count == rules.count)
        #expect(Set(rules.map(\.category)) == Set(JunkCategory.allCases))
        for rule in rules {
            #expect(rule.why.count <= RuleCatalog.maxWhyLength, "\(rule.id)")
            #expect(["mac-cleanup-py", "PureMac", "dustpan"].contains(rule.source), "\(rule.id)")
        }
    }

    @Test("Copy avoids banned words")
    func copyIsCalm() throws {
        let banned = ["junk-infested", "threats detected", "speed up your mac", "optimize"]
        for rule in try bundledRules() {
            let text = (rule.title + " " + rule.why).lowercased()
            #expect(!banned.contains { text.contains($0) }, "\(rule.id)")
        }
    }

    @Test("Prompt 3 rule groups are present")
    func requiredGroups() throws {
        let rules = try bundledRules()
        let paths = Set(rules.flatMap(\.paths))
        for required in [
            "~/Library/Caches", "~/Library/Logs", "~/Library/Logs/DiagnosticReports",
            "~/Library/Saved Application State",
            "~/Downloads", "~/.Trash", "~/Library/Developer/Xcode/DerivedData", "~/Library/Developer/Xcode/Archives",
            "~/.npm/_cacache", "~/Library/Caches/ms-playwright", "~/.cache/uv", "~/.cache/huggingface/hub",
            "~/Library/Containers/com.docker.docker/Data/vms", "~/Library/Caches/com.spotify.client",
        ] {
            #expect(paths.contains(required), "\(required)")
        }
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        #expect(byID["cache.apple"]?.risk == .review)
        #expect(byID["cache.spotify.never"]?.risk == .never)
        #expect(byID["ai.playwright"]?.risk == .review)
        #expect(byID["ai.huggingface"]?.risk == .review)
        #expect(byID["dev.docker.disk"]?.risk == .review)
        #expect(byID["xcode.archives"]?.risk == .review)
        #expect(byID["installers.dmg"]?.minAgeDays == 14)
        #expect(byID["logs.user"]?.minAgeDays == 7)
    }

    @Test("Docker rules and the Trash are detection-only and never pre-selectable")
    func detectionOnly() throws {
        let rules = try bundledRules()
        let docker = rules.filter { $0.paths.contains { $0.contains("com.docker.docker") } }
        #expect(!docker.isEmpty)
        #expect(docker.allSatisfy { $0.detectionOnly && $0.risk == .review })
        #expect(rules.first { $0.id == "trash.home" }?.detectionOnly == true)
        #expect(rules.filter(\.detectionOnly).allSatisfy { $0.risk == .review })
    }

    private func rulesJSON(_ overrides: [String: any Sendable]) throws -> Data {
        var rule: [String: Any] = [
            "id": "test.rule", "title": "Test", "category": "userCache", "paths": ["~/Library/Caches"],
            "globs": ["*"], "minAgeDays": 0, "risk": "safe", "why": "Short reason.", "requiresQuit": false,
            "source": "dustpan",
        ]
        rule.merge(overrides.mapValues { $0 as Any }) { $1 }
        return try JSONSerialization.data(withJSONObject: [rule])
    }

    @Test("A valid one-rule catalogue decodes")
    func validMinimal() throws {
        #expect(try RuleCatalog.decode(try rulesJSON([:]), protectedList: protectedList).count == 1)
    }

    @Test(
        "Invalid rules fail",
        arguments: [
            ["why": String(repeating: "a", count: 141)],
            ["why": ""],
            ["paths": ["~/Library/Mail"]],
            ["paths": ["~/Library/Mobile Documents/com~apple~CloudDocs"]],
            ["paths": ["~/Library/Containers/com.apple.Safari/Data/Library/Caches"]],
            ["paths": ["~/Library"], "globs": [String]()],
            ["paths": ["/Library/Caches"]],
            ["paths": ["~/Library/Caches/../Mail"]],
            ["paths": [String]()],
            ["risk": "dangerous"],
            ["category": "ram"],
            ["minAgeDays": -1],
            ["requiresQuit": true],
            ["detectionOnly": true],
            ["detectionOnly": true, "risk": "never"],
        ] as [[String: any Sendable]]
    )
    func invalidRulesFail(override: [String: any Sendable]) throws {
        let data = try rulesJSON(override)
        #expect(throws: DustpanError.self) { try RuleCatalog.decode(data, protectedList: protectedList) }
    }

    @Test("Duplicate IDs fail")
    func duplicateIDs() throws {
        let json = """
            [
              {"id":"a","title":"A","category":"logs","paths":["~/Library/Logs"],"globs":["*"],"minAgeDays":7,
               "risk":"safe","why":"Logs.","requiresQuit":false,"source":"dustpan"},
              {"id":"a","title":"B","category":"logs","paths":["~/Library/Logs/X"],"minAgeDays":7,
               "risk":"safe","why":"Logs.","requiresQuit":false,"source":"dustpan"}
            ]
            """
        #expect(throws: DustpanError.self) {
            try RuleCatalog.decode(Data(json.utf8), protectedList: protectedList)
        }
    }

    @Test("Malformed JSON fails")
    func malformed() {
        #expect(throws: DustpanError.self) {
            try RuleCatalog.decode(Data("[{".utf8), protectedList: protectedList)
        }
    }

    @Test("RuleCatalog actor loads the bundled file")
    func actorLoads() async throws {
        let catalog = RuleCatalog(protectedList: protectedList)
        #expect(try await catalog.rules().count >= 120)
    }
}
