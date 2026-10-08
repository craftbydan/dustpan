import Testing

@testable import Dustpan

/// Accessibility checks that run headless in `make test`. A full audit of the live tree
/// (XCUITest `performAccessibilityAudit()`, or walking `NSAccessibility` in-process) isn't
/// possible here: SwiftUI only builds its accessibility tree once an assistive client (VoiceOver,
/// a UI-test runner with Accessibility permission) connects, and granting that permission is a
/// privacy prompt. The view-level audit is in docs/qa-notes.md; these tests cover the logic the
/// views rely on.
@Suite("Accessibility", .serialized)
@MainActor
struct AccessibilityTests {
    @Test("Junk keyboard: arrows move the focused row, space ticks it")
    func junkKeyboard() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.populate()
        let state = await h.appState()
        let junk = state.junk
        await junk.scan(hasFullDiskAccess: true)
        junk.focusedCategory = junk.results.first { $0.items.count > 1 }?.category
        let visible = junk.visibleItems
        #expect(visible.count > 1)
        junk.moveFocus(by: 1)
        #expect(junk.focusedItemID == visible[0].id)
        junk.moveFocus(by: 1)
        #expect(junk.focusedItemID == visible[1].id)
        junk.moveFocus(by: 5)
        #expect(junk.focusedItemID == visible.last?.id)
        let before = junk.isSelected(visible.last!)
        junk.toggleFocused()
        #expect(junk.isSelected(visible.last!) == !before)
        junk.toggleFocused()
        #expect(junk.isSelected(visible.last!) == before)
    }

    @Test("Tile details are read without typographic marks")
    func spokenDetail() {
        #expect(Tile.spoken("3 of 12 safe · Review →") == "3 of 12 safe, Review")
    }
}
