import ApplicationServices
import XCTest
@testable import DockPlus

final class DockModelClickTests: XCTestCase {
    private func action(
        _ kind: DockItem.Kind, hasURL: Bool = true, command: Bool = false, option: Bool = false,
        frontmost: Bool = false, hidesFrontmost: Bool = false
    ) -> DockModel.ClickAction {
        DockModel.clickAction(
            kind: kind, hasURL: hasURL, command: command, option: option, isFrontmost: frontmost,
            hidesFrontmost: hidesFrontmost)
    }

    // MARK: - clickAction

    func testPlainClickOpens() {
        XCTAssertEqual(action(.app), .open)
        XCTAssertEqual(action(.folder), .open)
        XCTAssertEqual(action(.trash, hasURL: false), .open)
    }

    func testCommandClickReveals() {
        XCTAssertEqual(action(.app, command: true), .reveal)
        XCTAssertEqual(action(.folder, command: true), .reveal)
    }

    /// Nothing to reveal — the Trash, or an app with no bundle — so the click does what it always does.
    func testCommandClickWithNothingToRevealOpens() {
        XCTAssertEqual(action(.trash, hasURL: false, command: true), .open)
        XCTAssertEqual(action(.app, hasURL: false, command: true), .open)
    }

    /// Command wins when both are held, as in the macOS Dock.
    func testCommandOutranksOption() {
        XCTAssertEqual(action(.app, command: true, option: true), .reveal)
    }

    func testOptionClickOnAnAppHidesTheOthers() {
        XCTAssertEqual(action(.app, option: true), .openHidingOthers)
        XCTAssertEqual(action(.app, option: true, frontmost: true, hidesFrontmost: true), .openHidingOthers)
    }

    func testOptionClickOnAFolderJustOpens() {
        XCTAssertEqual(action(.folder, option: true), .open)
    }

    func testFrontmostAppHidesOnlyWithTheSettingOn() {
        XCTAssertEqual(action(.app, frontmost: true), .open)
        XCTAssertEqual(action(.app, frontmost: true, hidesFrontmost: true), .hide)
        XCTAssertEqual(action(.app, frontmost: false, hidesFrontmost: true), .open)
    }

    // MARK: - isRunning

    private let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
    private let xcodeBeta = URL(fileURLWithPath: "/Applications/Xcode-beta.app")

    /// Launch Services reopens the running copy whatever path was clicked, so a bounce started for
    /// the release while the beta runs would never be ended by a launch event.
    func testAnotherCopyWithTheSameBundleIDCountsAsRunning() {
        XCTAssertTrue(DockModel.isRunning(
            xcode, bundleID: "com.apple.dt.Xcode", among: [(bundleID: "com.apple.dt.Xcode", bundleURL: xcodeBeta)]))
        XCTAssertFalse(DockModel.isRunning(
            xcode, bundleID: "com.apple.dt.Xcode", among: [(bundleID: "com.apple.Safari", bundleURL: xcodeBeta)]))
    }

    /// A bundle with no identifier, on either side, still matches by where it is.
    func testWithoutABundleIDThePathDecides() {
        XCTAssertTrue(DockModel.isRunning(xcode, bundleID: nil, among: [(bundleID: nil, bundleURL: xcode)]))
        XCTAssertTrue(DockModel.isRunning(
            xcode, bundleID: "com.apple.dt.Xcode", among: [(bundleID: nil, bundleURL: xcode)]))
        XCTAssertFalse(DockModel.isRunning(xcode, bundleID: nil, among: [(bundleID: nil, bundleURL: xcodeBeta)]))
        XCTAssertFalse(DockModel.isRunning(xcode, bundleID: nil, among: [(bundleID: nil, bundleURL: nil)]))
    }

    // MARK: - menuWindows

    func testMenuListsTitledStandardWindowsInOrder() {
        let listed = DockModel.menuWindows(from: [
            (id: 1, title: "Inbox", subrole: kAXStandardWindowSubrole),
            (id: 2, title: "Untitled", subrole: kAXStandardWindowSubrole),
        ])
        XCTAssertEqual(listed, [.init(id: 1, title: "Inbox"), .init(id: 2, title: "Untitled")])
    }

    /// Panels and dialogs, untitled windows, and windows with no id to raise them by stay out.
    func testMenuLeavesOutWhatItCannotListOrRaise() {
        let listed = DockModel.menuWindows(from: [
            (id: 1, title: "Colors", subrole: kAXFloatingWindowSubrole),
            (id: 2, title: "", subrole: kAXStandardWindowSubrole),
            (id: 3, title: nil, subrole: kAXStandardWindowSubrole),
            (id: nil, title: "No id", subrole: kAXStandardWindowSubrole),
            (id: 4, title: "Save", subrole: kAXDialogSubrole),
            (id: 5, title: "Kept", subrole: kAXStandardWindowSubrole),
        ])
        XCTAssertEqual(listed, [.init(id: 5, title: "Kept")])
    }
}
