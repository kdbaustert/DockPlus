import IOKit.ps
import XCTest
@testable import DockPlus

/// The battery and calendar widgets' decisions, apart from IOKit and EventKit.
final class BatteryCalendarWidgetTests: XCTestCase {
    // MARK: - Battery

    func testReadingFromAPowerSourceDescription() throws {
        let reading = try XCTUnwrap(BatteryReading(description: [
            kIOPSCurrentCapacityKey: 61, kIOPSMaxCapacityKey: 100,
            kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
        ]))
        XCTAssertEqual(reading, BatteryReading(percent: 61, isCharging: false, isPluggedIn: false))
        XCTAssertEqual(reading.status, "On Battery")
    }

    /// Older Macs report capacity in mAh rather than percent; the ratio is what counts.
    func testReadingScalesACapacityThatIsNotAPercentage() {
        let reading = BatteryReading(description: [
            kIOPSCurrentCapacityKey: 2500, kIOPSMaxCapacityKey: 5000,
            kIOPSIsChargingKey: true, kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ])
        XCTAssertEqual(reading, BatteryReading(percent: 50, isCharging: true, isPluggedIn: true))
    }

    func testNoReadingWithoutACapacity() {
        XCTAssertNil(BatteryReading(description: [kIOPSCurrentCapacityKey: 50]))
        XCTAssertNil(BatteryReading(description: [kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 0]))
    }

    func testSymbolIsTheBoltWhileChargingElseTheNearestQuarter() {
        XCTAssertEqual(BatteryReading(percent: 30, isCharging: true, isPluggedIn: true).symbol, "battery.100percent.bolt")
        let steps = [(0, 0), (12, 0), (13, 25), (61, 50), (63, 75), (88, 100), (100, 100)]
        for (percent, step) in steps {
            XCTAssertEqual(
                BatteryReading(percent: percent, isCharging: false, isPluggedIn: false).symbol,
                "battery.\(step)percent", "\(percent)%")
        }
    }

    /// Full, or held at 80% by macOS: on the adapter without charging.
    func testPluggedInButNotCharging() {
        XCTAssertEqual(BatteryReading(percent: 80, isCharging: false, isPluggedIn: true).status, "Plugged In")
    }

    // MARK: - Calendar

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func entry(_ title: String, _ start: Double, _ end: Double) -> CalendarEntry {
        CalendarEntry(title: title, start: at(start), end: at(end))
    }

    func testShowsTheNextEventToStart() {
        let entries = [entry("Later", 120, 150), entry("Next", 60, 90), entry("Done", -60, -30)]
        XCTAssertEqual(WidgetsModel.calendarEvent(in: entries, at: at(0))?.title, "Next")
    }

    /// What is on now beats what is next; of two on now, the later to start — a meeting inside an
    /// all-afternoon block.
    func testShowsWhatIsOnNowLatestStartedFirst() {
        let entries = [entry("Block", -60, 240), entry("Meeting", -5, 25), entry("Next", 30, 60)]
        XCTAssertEqual(WidgetsModel.calendarEvent(in: entries, at: at(0))?.title, "Meeting")
        XCTAssertEqual(WidgetsModel.calendarEvent(in: entries, at: at(26))?.title, "Block")
    }

    func testNothingOnceTheDaysEventsHaveEnded() {
        XCTAssertNil(WidgetsModel.calendarEvent(in: [entry("Done", -60, -30)], at: at(0)))
        XCTAssertNil(WidgetsModel.calendarEvent(in: [], at: at(0)))
    }

    /// An event ends the moment its end arrives: not "now" any longer.
    func testAnEventAtItsEndIsOver() {
        XCTAssertNil(WidgetsModel.calendarEvent(in: [entry("Done", -30, 0)], at: at(0)))
    }

    func testTimeTextForComingAndUnderWay() {
        let time: (Date) -> String = { "T\(Int($0.timeIntervalSince(self.t0) / 60))" }
        XCTAssertEqual(WidgetsModel.calendarTimeText(for: entry("A", 60, 90), at: at(0), time: time), "T60")
        XCTAssertEqual(WidgetsModel.calendarTimeText(for: entry("A", -5, 25), at: at(0), time: time), "Now, until T25")
    }

    /// A block ending days from now must say which day, or it reads as ending today.
    func testTimeTextNamesTheDayOfAnEventEndingAfterToday() {
        let time: (Date) -> String = { "T\(Int($0.timeIntervalSince(self.t0) / 60))" }
        let text = WidgetsModel.calendarTimeText(for: entry("A", -5, 3 * 24 * 60), at: at(0), time: time)
        XCTAssertTrue(text.hasPrefix("Now, until "))
        XCTAssertTrue(text.hasSuffix(" T4320"), text)
    }

    /// A weekday alone names this week's: from seven days out, the date has to say it.
    func testTimeTextNamesTheDateOfAnEventEndingAWeekOut() {
        let time: (Date) -> String = { "T\(Int($0.timeIntervalSince(self.t0) / 60))" }
        let end = entry("A", -5, 7 * 24 * 60 + 60).end
        let weekday = end.formatted(.dateTime.weekday(.abbreviated))
        let date = end.formatted(.dateTime.month(.abbreviated).day())
        let text = WidgetsModel.calendarTimeText(for: entry("A", -5, 7 * 24 * 60 + 60), at: at(0), time: time)
        XCTAssertEqual(text, "Now, until \(date) T10140")
        XCTAssertNotEqual(text, "Now, until \(weekday) T10140")
    }

    /// The one timer waits for the soonest start or end still ahead, else the day's end.
    func testNextBoundaryIsTheSoonestStartOrEndAhead() {
        let dayEnd = at(600)
        let entries = [entry("On", -10, 20), entry("Next", 15, 45)]
        XCTAssertEqual(WidgetsModel.nextCalendarBoundary(in: entries, after: at(0), dayEnd: dayEnd), at(15))
        XCTAssertEqual(WidgetsModel.nextCalendarBoundary(in: entries, after: at(15), dayEnd: dayEnd), at(20))
        XCTAssertEqual(WidgetsModel.nextCalendarBoundary(in: entries, after: at(45), dayEnd: dayEnd), dayEnd)
        // An event running past midnight still wakes the tile at midnight, for the new day.
        XCTAssertEqual(WidgetsModel.nextCalendarBoundary(in: [entry("Late", 500, 700)], after: at(550), dayEnd: dayEnd), dayEnd)
    }
}
