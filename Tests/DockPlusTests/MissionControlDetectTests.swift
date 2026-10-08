import CoreGraphics
import XCTest
@testable import DockPlus

/// Spotting Mission Control from the on-screen window list: the real Dock's full-display backdrop at
/// the Dock window level. Window-server coordinates, y down, on a 1440×900 display. The Dock window
/// level is 20 here, as `CGWindowLevelForKey(.dockWindow)` returns on this OS.
final class MissionControlDetectTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let dockLevel = 20
    private let me: pid_t = 100
    private let dock: pid_t = 200

    private func window(
        _ bounds: CGRect, pid: Int = 200, layer: Int = 20, alpha: Double? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
        ]
        if let alpha { info[kCGWindowAlpha as String] = alpha }
        return info
    }

    private func active(_ windows: [[String: Any]]) -> Bool {
        DockController.missionControlActive(
            over: display, dockLevel: dockLevel, windows: windows, ownPID: me, dockPID: dock)
    }

    func testNoWindowsIsNotActive() {
        XCTAssertFalse(active([]))
    }

    /// The backdrop fills the whole display at the Dock level.
    func testFullDisplayBackdropIsActive() {
        XCTAssertTrue(active([window(display)]))
    }

    /// Short of the top by a menu bar's worth still counts.
    func testBackdropShortByTheMenuBarIsActive() {
        XCTAssertTrue(active([window(CGRect(x: 0, y: 37, width: 1440, height: 863))]))
    }

    /// DockPlus's own resting bar is a bottom strip at the same level — never a false positive.
    func testOwnEdgeStripIsNotActive() {
        XCTAssertFalse(active([window(CGRect(x: 0, y: 840, width: 1440, height: 60), pid: Int(me))]))
    }

    /// Even full-display, DockPlus's own window does not count.
    func testOwnFullDisplayWindowIsNotActive() {
        XCTAssertFalse(active([window(display, pid: Int(me))]))
    }

    /// A maximized app window reaching the screen edges sits at the normal layer, not the Dock's.
    func testFullScreenAppAtNormalLayerIsNotActive() {
        XCTAssertFalse(active([window(display, layer: 0)]))
    }

    /// The real Dock's own bar, shown, is an edge strip — not the full-display backdrop.
    func testDockEdgeBarIsNotActive() {
        XCTAssertFalse(active([window(CGRect(x: 0, y: 840, width: 1440, height: 60))]))
    }

    /// Covers most of the display but well short in height: an overlay, not the backdrop.
    func testPartialHeightWindowIsNotActive() {
        XCTAssertFalse(active([window(CGRect(x: 0, y: 0, width: 1440, height: 700))]))
    }

    /// Full height but narrow: a sidebar, not the backdrop.
    func testNarrowWindowIsNotActive() {
        XCTAssertFalse(active([window(CGRect(x: 0, y: 0, width: 1200, height: 900))]))
    }

    /// The backdrop on another display does not count for this one.
    func testBackdropOnAnotherDisplayIsNotActive() {
        XCTAssertFalse(active([window(CGRect(x: 1440, y: 0, width: 1440, height: 900))]))
    }

    /// One qualifying window among windows that do not is enough.
    func testBackdropAmongOtherWindowsIsActive() {
        XCTAssertTrue(active([
            window(CGRect(x: 100, y: 100, width: 400, height: 300), layer: 0),
            window(display, pid: Int(me)),
            window(display),
        ]))
    }

    /// A full-display window at the Dock level from some other app is not the Dock's backdrop.
    func testFullDisplayWindowOfAnotherAppIsNotActive() {
        XCTAssertFalse(active([window(display, pid: 300)]))
    }

    /// An invisible backdrop shows nothing to hide from; a missing alpha reads as visible.
    func testFullyTransparentBackdropIsNotActive() {
        XCTAssertFalse(active([window(display, alpha: 0)]))
        XCTAssertTrue(active([window(display, alpha: 1)]))
    }

    /// Entries the window server describes without the keys are skipped, not trusted.
    func testMalformedEntriesAreNotActive() {
        XCTAssertFalse(active([[kCGWindowLayer as String: dockLevel, kCGWindowOwnerPID as String: 200]]))
    }
}
