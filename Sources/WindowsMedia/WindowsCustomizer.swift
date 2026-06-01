import Foundation

/// Applies Windows User Experience customizations to an already-populated USB volume:
/// writes a composed `autounattend.xml` (if any options are set) and, when bypassing Win11,
/// zeroes `sources/appraiserres.dll` to disable the compatibility appraiser.
public enum WindowsCustomizer {
    public static func apply(usbRoot: String, options: WindowsCustomization) throws {
        let fm = FileManager.default
        if options.bypassWin11 {
            let appraiser = (usbRoot as NSString).appendingPathComponent("sources/appraiserres.dll")
            if fm.fileExists(atPath: appraiser) {
                try Data().write(to: URL(fileURLWithPath: appraiser))
            }
        }
        if let xml = UnattendBuilder.build(options) {
            let path = (usbRoot as NSString).appendingPathComponent("autounattend.xml")
            try xml.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
