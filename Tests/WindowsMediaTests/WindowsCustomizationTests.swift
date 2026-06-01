import XCTest
@testable import WindowsMedia

final class WindowsCustomizationTests: XCTestCase {
    func testIsEmptyWhenNothingSet() {
        XCTAssertTrue(WindowsCustomization().isEmpty)
    }
    func testNotEmptyWhenBypassOn() {
        XCTAssertFalse(WindowsCustomization(bypassWin11: true).isEmpty)
    }
    func testNotEmptyWhenLocalAccountSet() {
        XCTAssertFalse(WindowsCustomization(localAccountUsername: "joe").isEmpty)
    }
    func testTimeZoneMapKnownAndUnknown() {
        XCTAssertEqual(WindowsTimeZone.windowsName(forIANA: "Asia/Seoul"), "Korea Standard Time")
        XCTAssertEqual(WindowsTimeZone.windowsName(forIANA: "America/New_York"), "Eastern Standard Time")
        XCTAssertEqual(WindowsTimeZone.windowsName(forIANA: "UTC"), "UTC")
        XCTAssertNil(WindowsTimeZone.windowsName(forIANA: "Mars/Olympus"))
    }
}
