import XCTest
import Darwin
@testable import DiskDiscovery

final class DiskDiscoveryTests: XCTestCase {
    /// Safety regression guard: the whole disk backing "/" must NEVER be listed
    /// as a removable target (writing to it would destroy the running system).
    func testRemovableDisksExcludesBootDisk() {
        var fs = statfs()
        XCTAssertEqual(statfs("/", &fs), 0, "statfs(/) failed")
        let mntFrom = withUnsafeBytes(of: &fs.f_mntfromname) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        // e.g. "/dev/disk3s1s1" -> whole disk "disk3"
        guard let match = mntFrom.range(of: #"disk\d+"#, options: .regularExpression) else {
            return XCTFail("could not parse boot disk from \(mntFrom)")
        }
        let bootWhole = String(mntFrom[match])
        let names = DiskDiscovery.removableDisks().map(\.bsdName)
        XCTAssertFalse(names.contains(bootWhole),
                       "boot disk \(bootWhole) must not appear in removable list; got \(names)")
    }
}
