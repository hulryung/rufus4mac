import XCTest
@testable import WindowsMedia

final class UnattendBuilderTests: XCTestCase {
    func testEmptyOptionsProduceNil() {
        XCTAssertNil(UnattendBuilder.build(WindowsCustomization()))
    }
    func testBypassEmitsLabConfig() {
        let xml = UnattendBuilder.build(WindowsCustomization(bypassWin11: true))!
        XCTAssertTrue(xml.contains("BypassTPMCheck"))
        XCTAssertTrue(xml.contains("BypassSecureBootCheck"))
        XCTAssertTrue(xml.contains("LabConfig"))
        XCTAssertTrue(xml.hasPrefix("<?xml"))
    }
    func testLocalAccountEmitsUserAndHidesOnlineAccount() {
        let xml = UnattendBuilder.build(WindowsCustomization(localAccountUsername: "joe"))!
        XCTAssertTrue(xml.contains("<LocalAccounts>"))
        XCTAssertTrue(xml.contains("<Name>joe</Name>"))
        XCTAssertTrue(xml.contains("Administrators"))
        XCTAssertTrue(xml.contains("HideOnlineAccountScreens"))
    }
    func testSkipPrivacyEmitsProtectYourPC() {
        let xml = UnattendBuilder.build(WindowsCustomization(skipPrivacy: true))!
        XCTAssertTrue(xml.contains("<ProtectYourPC>3</ProtectYourPC>"))
        XCTAssertTrue(xml.contains("HideEULAPage"))
    }
    func testRegionEmitsLocaleAndTimeZone() {
        let xml = UnattendBuilder.build(WindowsCustomization(regionLocale: "ko-KR",
                                                             regionTimeZone: "Korea Standard Time"))!
        XCTAssertTrue(xml.contains("<SystemLocale>ko-KR</SystemLocale>"))
        XCTAssertTrue(xml.contains("<InputLocale>ko-KR</InputLocale>"))
        XCTAssertTrue(xml.contains("<TimeZone>Korea Standard Time</TimeZone>"))
    }
    func testBitLockerEmitsPreventDeviceEncryption() {
        let xml = UnattendBuilder.build(WindowsCustomization(disableBitLocker: true))!
        XCTAssertTrue(xml.contains("PreventDeviceEncryption"))
    }
    func testUsernameWithAmpersandIsXMLEscaped() {
        let xml = UnattendBuilder.build(WindowsCustomization(localAccountUsername: "a&b"))!
        XCTAssertTrue(xml.contains("<Name>a&amp;b</Name>"))
        XCTAssertFalse(xml.contains("<Name>a&b</Name>"))
    }
    func testEmptyUsernameNotTreatedAsAccount() {
        let xml = UnattendBuilder.build(WindowsCustomization(localAccountUsername: "", skipPrivacy: true))
        XCTAssertNotNil(xml)
        XCTAssertFalse(xml!.contains("<LocalAccounts>"))
    }
}
