import XCTest
@testable import DockPlus

final class WeatherSymbolTests: XCTestCase {
    func testClearAndPartlyCloudyTurnToTheMoonAtNight() {
        XCTAssertEqual(WidgetsModel.symbol(for: 0, isDay: true), "sun.max.fill")
        XCTAssertEqual(WidgetsModel.symbol(for: 0, isDay: false), "moon.stars.fill")
        XCTAssertEqual(WidgetsModel.symbol(for: 1, isDay: true), "cloud.sun.fill")
        XCTAssertEqual(WidgetsModel.symbol(for: 1, isDay: false), "cloud.moon.fill")
        XCTAssertEqual(WidgetsModel.symbol(for: 2, isDay: false), "cloud.moon.fill")
    }

    func testOtherCodesDoNotCareAboutTheHour() {
        XCTAssertEqual(WidgetsModel.symbol(for: 63, isDay: false), "cloud.rain.fill")
        XCTAssertEqual(WidgetsModel.symbol(for: 63, isDay: true), "cloud.rain.fill")
    }

    /// A reading with no code is unknown, not a clear sky.
    func testAMissingCodeIsACloudNotASun() {
        XCTAssertEqual(WidgetsModel.symbol(for: nil, isDay: true), "cloud.fill")
        XCTAssertEqual(WidgetsModel.symbol(for: nil, isDay: false), "cloud.fill")
    }
}
