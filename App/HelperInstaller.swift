import Foundation
import ServiceManagement

enum HelperInstaller {
    /// The daemon plist embedded at Contents/Library/LaunchDaemons/<plistName>.
    static let plistName = "com.huconn.rufus4mac.helper.plist"

    static var service: SMAppService { .daemon(plistName: plistName) }

    /// Register the daemon if not already enabled. If macOS requires the user to
    /// approve it, open Login Items settings and return false. Returns true once enabled.
    @discardableResult
    static func ensureInstalled() throws -> Bool {
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return false
        default:
            try service.register()
            return service.status == .enabled
        }
    }
}
