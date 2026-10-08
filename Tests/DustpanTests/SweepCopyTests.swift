import Foundation
import Testing

@testable import Dustpan

/// The Sweep results wording. Safety rule 3 (nothing changed in the last 7 days is pre-selected)
/// stays; the copy must not claim "nothing needs cleaning" when safe junk is just recent.
@Suite("Sweep copy states", .serialized)
@MainActor
struct SweepCopyTests {
    static func sweep(_ fill: (SweepHarness) throws -> Void) async throws -> (SweepHarness, AppState) {
        let h = try SweepHarness()
        try fill(h)
        let state = await OpenAppsTests.appState(h, running: MutableRunningApps())
        await state.sweep.sweep()
        #expect(state.sweep.phase == .results)
        return (h, state)
    }

    @Test("Something recommended: the size headline and 'N of M recommended'")
    func recommended() async throws {
        let (h, state) = try await Self.sweep { h in
            try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 12_000, ageDays: 30)
            try h.fixture.file("Library/Caches/com.example.young/b.bin", bytes: 4_000, ageDays: 1)
        }
        defer { h.remove() }
        let sweep = state.sweep
        #expect(sweep.headline == .ready(sweep.recommendedBytes))
        #expect(sweep.junkTileDetail == "1 of 2 recommended · Review →")
        #expect(sweep.bytes(.junk) == state.junk.totalBytes)
    }

    @Test("Only recently used safe items: 'Nothing to clean automatically', why, and Review safe items")
    func nothingAutomatic() async throws {
        let (h, state) = try await Self.sweep { h in
            try h.fixture.file("Library/Caches/com.example.young/b.bin", bytes: 4_000, ageDays: 1)
            try h.fixture.file("Library/Caches/com.example.fresh/c.bin", bytes: 9_000, ageDays: 2)
        }
        defer { h.remove() }
        let sweep = state.sweep
        #expect(sweep.recommendedItems.isEmpty)  // rule 3 still holds
        #expect(sweep.headline == .nothingAutomatic(safe: 2, recentSafe: 2))
        #expect(sweep.junkTileDetail == "2 safe, none recommended · Review →")
        let line = SweepCopy.nothingAutomatic(safe: 2, recentSafe: 2)
        #expect(line.contains("2 safe items were used in the last week"))
        #expect(line.contains("You can still choose them yourself."))

        state.junk.riskFilter = .review
        state.reviewSafeJunk()
        #expect(state.section == .junk)
        #expect(state.junk.riskFilter == .safe)
        #expect(state.junk.focusedCategory == .userCache)
        #expect(state.junk.selection.isEmpty)  // nothing ticked for the user
    }

    @Test("Every module empty: only then 'Nothing needs cleaning right now'")
    func allEmpty() async throws {
        let (h, state) = try await Self.sweep { _ in }
        defer { h.remove() }
        #expect(state.sweep.headline == .allEmpty)
    }

    @Test("No safe junk but other tiles have something: review-only, never 'nothing needs cleaning'")
    func reviewOnly() async throws {
        let (h, state) = try await Self.sweep { h in
            try h.fixture.file(".cache/zzreview/d.bin", bytes: 8_000, ageDays: 30)
        }
        defer { h.remove() }
        #expect(state.sweep.headline == .reviewOnly)
        #expect(state.sweep.junkTileDetail == "1 item to review · Review →")
    }
}
