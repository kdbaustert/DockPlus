import XCTest
@testable import DockPlus

/// Finding a window's entry in its app's Window menu, which a raise presses to have the Dock travel
/// to the window's Desktop. The menu names a window by its title and nothing else.
final class WindowMenuMatchTests: XCTestCase {
    func testTheItemWithTheWindowsTitleIsFound() {
        XCTAssertEqual(WindowActions.windowMenuIndex(forTitle: "Drafts", in: ["Inbox", "Drafts"]), 1)
    }

    func testCaseIsIgnored() {
        XCTAssertEqual(WindowActions.windowMenuIndex(forTitle: "pull requests", in: ["Pull Requests"]), 0)
    }

    /// A terminal's spinner changes between the two readings: measured on Ghostty, one frame apart.
    func testLeadingGlyphsAreIgnoredOnBothSides() {
        XCTAssertEqual(
            WindowActions.windowMenuIndex(forTitle: "◐ Features and improvements", in: ["◑ Features and improvements"]),
            0)
    }

    func testATitleTheMenuDoesNotListFindsNothing() {
        XCTAssertNil(WindowActions.windowMenuIndex(forTitle: "Issues", in: ["Inbox", "Drafts"]))
        XCTAssertNil(WindowActions.windowMenuIndex(forTitle: "Issues", in: []))
    }

    /// An untitled window must not match an item whose title is also nothing but decoration.
    func testATitleWithNothingToCompareFindsNothing() {
        XCTAssertNil(WindowActions.windowMenuIndex(forTitle: "", in: ["", "Inbox"]))
        XCTAssertNil(WindowActions.windowMenuIndex(forTitle: " • ", in: ["•", "Inbox"]))
    }

    func testTwoWindowsWithOneTitleMatchTheFirst() {
        XCTAssertEqual(WindowActions.windowMenuIndex(forTitle: "Untitled", in: ["Notes", "Untitled", "Untitled"]), 1)
    }
}
