import XCTest
@testable import DockPlus

@MainActor
final class SystemDockOriginalsTests: XCTestCase {
    func testUserValuesAreKept() {
        let live: [String: Any] = ["autohide": false, "autohide-delay": 0.5, "no-bouncing": false]
        XCTAssertEqual(SystemDock.userOriginals(live).count, 3)
    }

    func testOwnDelayDropsAllThree() {
        let live: [String: Any] = ["autohide": true, "autohide-delay": 1000.0, "no-bouncing": true]
        XCTAssertTrue(SystemDock.userOriginals(live).isEmpty)
    }

    func testAbsentDelayKeepsTheRest() {
        let live: [String: Any] = ["autohide": true]
        XCTAssertEqual(SystemDock.userOriginals(live).count, 1)
    }
}
