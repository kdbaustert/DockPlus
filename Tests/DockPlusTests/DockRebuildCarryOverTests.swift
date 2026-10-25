import XCTest
@testable import DockPlus

/// Which docks come back slid away when AppDelegate rebuilds them on a display change.
final class DockRebuildCarryOverTests: XCTestCase {
    private let a = "A-UUID"
    private let b = "B-UUID"

    private func carried(
        _ docks: [(display: String?, isSlidAway: Bool)], remembered: Set<String> = [], mode: DisplayMode
    ) -> Set<String> {
        AppDelegate.slidAwayDisplays(after: docks, remembered: remembered, mode: mode)
    }

    func testSlidAwayDockOnTheSameDisplayComesBackSlidAway() {
        let slidAway = carried([(a, true), (b, false)], mode: .all)
        XCTAssertEqual(slidAway, [a])
        XCTAssertTrue(AppDelegate.startsHidden(display: a, slidAway: slidAway, mode: .all))
        XCTAssertFalse(AppDelegate.startsHidden(display: b, slidAway: slidAway, mode: .all))
    }

    /// Keyed by UUID, so a display that returns under a new CGDirectDisplayID is still found.
    func testRevealedDockClearsItsDisplay() {
        let slidAway = carried([(a, false)], remembered: [a, b], mode: .all)
        XCTAssertEqual(slidAway, [b])
    }

    /// A display gone for the moment keeps its answer for its return.
    func testAbsentDisplayKeepsItsState() {
        XCTAssertEqual(carried([(b, false)], remembered: [a], mode: .all), [a])
    }

    func testFollowPointerCarriesTheLoneDockToWhateverDisplayIsNext() {
        let slidAway = carried([(b, true)], mode: .followPointer)
        XCTAssertTrue(AppDelegate.startsHidden(display: a, slidAway: slidAway, mode: .followPointer))
    }

    func testFollowPointerDropsAnotherModesLeftovers() {
        let slidAway = carried([(a, false)], remembered: [b], mode: .followPointer)
        XCTAssertEqual(slidAway, [])
        XCTAssertFalse(AppDelegate.startsHidden(display: a, slidAway: slidAway, mode: .followPointer))
    }

    /// A rebuild with no screen tears every dock down; the one after it starts from no docks and
    /// must still know which were slid away.
    func testZeroScreenRebuildRoundTrip() {
        let beforeSleep = carried([(a, true), (b, false)], mode: .all)
        let noScreens = carried([], remembered: beforeSleep, mode: .all)
        XCTAssertEqual(noScreens, [a])
        XCTAssertTrue(AppDelegate.startsHidden(display: a, slidAway: noScreens, mode: .all))
        XCTAssertFalse(AppDelegate.startsHidden(display: b, slidAway: noScreens, mode: .all))

        let pointerDock = carried([(a, true)], mode: .followPointer)
        let pointerNoScreens = carried([], remembered: pointerDock, mode: .followPointer)
        XCTAssertTrue(AppDelegate.startsHidden(display: b, slidAway: pointerNoScreens, mode: .followPointer))
    }

    func testDockWithNoUUIDIsNotCarried() {
        XCTAssertEqual(carried([(nil, true)], mode: .all), [])
    }
}
