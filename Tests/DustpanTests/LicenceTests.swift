import Foundation
import Testing

@testable import Dustpan

/// MIT, BSD and Apache require their notices in every copy, so the app must carry them.
@Suite("Licences")
struct LicenceTests {
    @Test("The app bundle ships its own licence, the third-party notices and the rule sources")
    func bundledTexts() throws {
        let files: [(String, String?, String)] = [
            ("LICENSE", nil, "MIT License"),
            ("THIRD_PARTY_NOTICES", "md", "GRDB"),
            ("RULES_ATTRIBUTION", "md", "Apache License"),
        ]
        for (name, ext, needle) in files {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: ext), "\(name) missing")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains(needle), "\(name) doesn't look right")
        }
    }

    @Test("Every dependency in the project has a notice")
    func everyPackageCredited() throws {
        let url = try #require(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        for name in [
            "GRDB", "PermissionsKit", "swift-collections", "xxHash", "Archivo", "MenuBarExtraAccess",
            "LaunchAtLogin",
        ] {
            #expect(text.contains(name), "no notice for \(name)")
        }
    }

    @Test("Info.plist carries a copyright with the no-warranty line")
    func copyright() {
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
        #expect(copyright.contains("MIT"))
        #expect(copyright.contains("without warranty"))
    }
}
