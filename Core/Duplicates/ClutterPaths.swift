import Foundation

/// Where the Clutter tools (Large & old, Duplicates) never look, shared with the Cleaner's
/// clutter checks so what is listed is exactly what can be moved.
enum ClutterPaths {
    /// Folder extensions that are packages (one thing to the user, many files inside). Their
    /// insides are never listed or moved one file at a time. `isPackage` from the file system
    /// catches the rest.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "bundle", "framework",
        "plugin", "appex", "kext", "xpc", "xcodeproj", "xcworkspace", "xcarchive", "playground", "logicx", "band",
        "rtfd", "pages", "numbers", "key", "sparsebundle", "dtbase2", "aplibrary", "lrdata", "lrlibrary",
        "photolibrary", "migratedphotolibrary",
    ]

    /// Folders whose files belong to a tool that manages them (dependencies, build output,
    /// version control). A "duplicate" in there is a copy the tool needs.
    static let toolFolderNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "pods", "deriveddata", ".build", "venv", ".venv",
        "__pycache__", ".gradle", ".m2", ".cargo", ".rustup", "site-packages", ".pnpm-store",
        // Caches tools rebuild (Junk's job, not Clutter's): their blobs aren't user files.
        "caches", ".cache", ".npm", ".yarn", ".bun", ".cocoapods", ".nuget", ".pub-cache", ".conda",
        "sourcepackages", ".swiftpm",
    ]

    /// By name only (no disk access).
    static func isPackageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && packageExtensions.contains(ext)
    }

    static func isToolFolderName(_ name: String) -> Bool { toolFolderNames.contains(name.lowercased()) }

    /// Whether any folder strictly between `root` and `path` is a package or a tool folder.
    /// Asks the file system (`isPackage`) for folders whose name doesn't tell. Call only after
    /// the Full Disk Access guard has passed for `path`.
    static func isInsidePackageOrToolFolder(_ path: String, root: String) -> Bool {
        guard PathTools.isStrictlyInside(path, root: root) else { return false }
        let relative = PathTools.components(String(path.dropFirst(root.count)))
        var current = root
        for name in relative.dropLast() {
            current += "/" + name
            if isPackageName(name) || isToolFolderName(name) { return true }
            let values = try? URL(fileURLWithPath: current, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
            if values?.isPackage == true { return true }
        }
        return false
    }
}

/// CLAUDE.md safety rule 2 for single files: a file is protected when any folder above it,
/// strictly inside the home folder, directly holds an app database (`.sqlite`, `.realm`, `.db`)
/// and isn't inside a `Caches` folder (or the Trash). Each folder is listed once (cached). Fails
/// closed: a folder that can't be listed counts as holding a database.
final class DatabaseFolderCheck {
    private let home: String
    private let protectedList: ProtectedList
    private var holdsDatabase: [String: Bool] = [:]

    init(home: String, protectedList: ProtectedList) {
        self.home = home
        self.protectedList = protectedList
    }

    func isInsideDatabaseFolder(_ path: String) -> Bool {
        assertNotMainThread()
        guard PathTools.isStrictlyInside(path, root: home) else { return false }
        let relative = PathTools.components(String(path.dropFirst(home.count)))
        var folder = home
        for name in relative.dropLast() {
            folder += "/" + name
            guard protectedList.databaseRuleApplies(to: folder) else { continue }
            if directlyHoldsDatabase(folder) { return true }
        }
        return false
    }

    private func directlyHoldsDatabase(_ folder: String) -> Bool {
        if let known = holdsDatabase[folder] { return known }
        let answer: Bool
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder) {
            answer = names.contains { ProtectedList.isDatabaseFile(URL(fileURLWithPath: $0)) }
        } else {
            answer = true
        }
        holdsDatabase[folder] = answer
        return answer
    }
}
