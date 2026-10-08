import Foundation
import Testing

@testable import Dustpan

@Suite("Protected list")
struct ProtectedListTests {
    @Test("Every CLAUDE.md root is protected, inside and out")
    func roots() throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        let list = ProtectedList(home: fixture.url)
        let home = fixture.url.path
        for path in [
            "/System/Library", "/Library/Apple/usr", "/usr/bin/true", "/bin", "/sbin/mount",
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/a.txt",
            "\(home)/Library/CloudStorage/Dropbox/a.txt",
            "\(home)/Library/Mail/V10",
            "\(home)/Pictures/Photos Library.photoslibrary/database",
            "\(home)/Library/Containers/com.apple.Notes/Data",
            "\(home)/Library/Group Containers/group.com.apple.notes/x",
            "\(home)/Library/Group Containers/com.apple.Home.group/x",
            "\(home)/Library/Group Containers/com.apple.notes",
            "\(home)/Library/Keychains/login.keychain-db",
            "\(home)/Library/Application Support/MobileSync/Backup/abc",
            // Ancestors of a root: acting on them would include the root.
            "\(home)/Library", "\(home)/Library/Containers", home, "/",
        ] {
            #expect(list.isProtectedPath(path), "\(path)")
        }
        for path in [
            "\(home)/Library/Caches/com.example", "\(home)/Library/Containers/com.docker.docker/Data/log",
            "\(home)/Library/Group Containers/group.com.example/x", "\(home)/Pictures/holiday.jpg",
            "\(home)/Library/Logs/x.log", "\(home)/Library/Application Support/Code/CachedData",
        ] {
            #expect(!list.isProtectedPath(path), "\(path)")
        }
        // Case-insensitive, like APFS.
        #expect(list.isProtectedPath("\(home)/library/mail"))
    }

    @Test("MobileSync is allowed only when the iOS-backup rule is selected")
    func mobileSync() throws {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let path = "/Users/fixture/Library/Application Support/MobileSync/Backup"
        #expect(ProtectedList(home: home).isProtectedPath(path))
        #expect(!ProtectedList(home: home, allowMobileSync: true).isProtectedPath(path))
    }

    @Test("Symlinks are resolved before checking")
    func symlinks() throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try fixture.file("Library/Mail/V10/msg.emlx", bytes: 100)
        try fixture.symlink("Library/Caches/sneaky", to: fixture.path("Library/Mail"))
        let list = ProtectedList(home: fixture.url)
        #expect(list.isProtected(fixture.path("Library/Caches/sneaky")))
        #expect(list.isProtected(fixture.path("Library/Caches/sneaky/V10/msg.emlx")))
    }

    @Test("Folders holding app databases are protected outside Caches")
    func databases() throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try fixture.file("Library/Application Support/Notes App/store.sqlite", bytes: 10)
        try fixture.file("Library/Application Support/Realm App/data/default.realm", bytes: 10)
        try fixture.file("Library/Application Support/Plain/settings.json", bytes: 10)
        try fixture.file("Library/Caches/com.example/cache.db", bytes: 10)
        try fixture.file(".Trash/old/thing.db", bytes: 10)
        // Deep inside: the walk is full depth.
        try fixture.file("Library/Application Support/Deep/a/b/c/d/deep.db", bytes: 10)
        let list = ProtectedList(home: fixture.url)
        #expect(list.isProtected(fixture.path("Library/Application Support/Notes App")))
        #expect(list.isProtected(fixture.path("Library/Application Support/Notes App/store.sqlite")))
        #expect(list.isProtected(fixture.path("Library/Application Support/Realm App")))
        #expect(!list.isProtected(fixture.path("Library/Application Support/Plain")))
        #expect(!list.isProtected(fixture.path("Library/Caches/com.example")))
        #expect(!list.isProtected(fixture.path(".Trash/old")))
        #expect(list.isProtected(fixture.path("Library/Application Support/Deep")))
    }

    @Test("The database walk fails closed at its entry limit, but Caches skip the walk")
    func databaseLimit() throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        for index in 0..<10 {
            try fixture.file("Library/Application Support/Big/f\(index).json", bytes: 10)
            try fixture.file("Library/Caches/com.example.big/f\(index).bin", bytes: 10)
        }
        let list = ProtectedList(home: fixture.url, databaseSearchLimit: 3)
        #expect(list.isProtected(fixture.path("Library/Application Support/Big")))
        #expect(!list.isProtected(fixture.path("Library/Caches/com.example.big")))
        #expect(!ProtectedList(home: fixture.url).isProtected(fixture.path("Library/Application Support/Big")))
    }

    @Test("A folder that can't be fully read is protected (it could hide a database)")
    func unreadable() throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try fixture.file("Library/Application Support/Locked/readable.json", bytes: 10)
        try fixture.file("Library/Application Support/Locked/secret/x.json", bytes: 10)
        let locked = fixture.path("Library/Application Support/Locked/secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(ProtectedList(home: fixture.url).isProtected(fixture.path("Library/Application Support/Locked")))
    }
}
