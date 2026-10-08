import Foundation

// The real Sweep modules. Each one only calls the scanner its feature screen uses, with the
// same settings, so a tile and its screen always agree.

/// Junk: the catalogue's rules, the ignore list, the Full Disk Access gate (`JunkScanRun`).
struct JunkSweepScanner: SweepScanner {
    let catalog: RuleCatalog
    let store: CleanupStore
    let home: URL
    var now: @Sendable () -> Date = { Date() }

    var module: SweepModule { .junk }

    func run(hasFullDiskAccess: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> SweepFinding {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        async let output = JunkScanRun.run(
            catalog: catalog, store: store, home: home, now: now(), hasFullDiskAccess: hasFullDiskAccess,
            progress: continuation)
        for await update in stream { progress(update.fraction) }
        let result = try await output
        try Task.checkCancellation()
        return .junk(result)
    }
}

/// Leftovers of deleted apps (`LeftoverMatcher.orphans`), as the Apps screen's Leftovers tab.
struct OrphanSweepScanner: SweepScanner {
    let scanner: AppScanner
    let home: URL
    let systemLibrary: URL
    var isKnownApp: @Sendable (String) -> Bool = { LaunchServicesApps.isKnown($0) }
    var now: @Sendable () -> Date = { Date() }

    var module: SweepModule { .orphans }

    func run(hasFullDiskAccess: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> SweepFinding {
        let matcher = LeftoverMatcher(
            home: home, systemLibrary: systemLibrary, hasFullDiskAccess: hasFullDiskAccess, now: now())
        let scan = await LeftoverMatcher.findOrphans(scanner: scanner, matcher: matcher, isKnownApp: isKnownApp)
        try Task.checkCancellation()
        return .orphans(scan)
    }
}

/// Installed apps with sizes and last use (`AppScanner.installedApps`); the tile counts those not
/// opened in 180 days. A suggestion only: apps are never part of "Clean recommended".
struct UnusedAppsSweepScanner: SweepScanner {
    let scanner: AppScanner

    var module: SweepModule { .unusedApps }

    func run(hasFullDiskAccess: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> SweepFinding {
        let apps = await scanner.installedApps()
        try Task.checkCancellation()
        return .apps(apps)
    }
}

/// Duplicates in Downloads (`DuplicateFinder`). Downloads needs Full Disk Access; without it the
/// folder isn't touched at all and the tile says so.
struct DownloadsDuplicatesSweepScanner: SweepScanner {
    let finder: DuplicateFinder
    let home: URL

    var module: SweepModule { .duplicates }

    var folder: URL { home.appendingPathComponent("Downloads", isDirectory: true) }

    func run(hasFullDiskAccess: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> SweepFinding {
        guard hasFullDiskAccess else { return .needsAccess }
        let scan = try await finder.find([folder]) { progress($0.phase == .comparing ? $0.fraction : nil) }
        try Task.checkCancellation()
        return scan.needsAccess.isEmpty ? .duplicates(scan) : .needsAccess
    }
}

/// Large & old (`LargeOldFinder`, same 100 MB floor as the Clutter screen, so the list carries
/// over); the tile counts files over 1 GB untouched for a year (`LargeOldFilter.sweep`).
struct LargeOldSweepScanner: SweepScanner {
    let finder: LargeOldFinder

    var module: SweepModule { .largeOld }

    func run(hasFullDiskAccess: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> SweepFinding {
        let scan = try await finder.find()
        try Task.checkCancellation()
        return .largeOld(scan)
    }
}
