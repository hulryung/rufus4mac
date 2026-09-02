import Foundation

/// Applies Windows User Experience customizations to an already-populated USB volume:
/// writes a composed `autounattend.xml` (if any options are set) and, when bypassing Win11,
/// zeroes `sources/appraiserres.dll` to disable the compatibility appraiser.
///
/// The answer file's UI language is resolved against the medium's own `sources/lang.ini` here —
/// requesting a language the image lacks makes Setup fail with 0x8007000D.
public enum WindowsCustomizer {
    public static func apply(usbRoot: String, options: WindowsCustomization) throws {
        let fm = FileManager.default
        if options.bypassWin11 {
            let appraiser = (usbRoot as NSString).appendingPathComponent("sources/appraiserres.dll")
            if fm.fileExists(atPath: appraiser) {
                try Data().write(to: URL(fileURLWithPath: appraiser))
            }
        }
        // The UI language must be one the image ships (a Korean ISO has only ko-KR), so it is read
        // off the medium rather than taken from the Mac. Only relevant when region matching is on.
        var options = options
        if options.regionLocale != nil {
            options.imageUILanguage = WindowsImageLanguage.uiLanguage(root: usbRoot,
                                                                      desired: options.regionLocale)
        }
        if let xml = UnattendBuilder.build(options) {
            let path = (usbRoot as NSString).appendingPathComponent("autounattend.xml")
            try xml.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
