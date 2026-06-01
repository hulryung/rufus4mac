import Foundation

/// Applies the Windows 11 hardware-check bypass to an already-populated USB volume:
/// 1) zero `sources/appraiserres.dll` (disables the compatibility appraiser), and
/// 2) drop an `autounattend.xml` with LabConfig bypass keys for the Setup checks.
public enum Win11Bypass {
    public static func apply(usbRoot: String) throws {
        let fm = FileManager.default
        let appraiser = (usbRoot as NSString).appendingPathComponent("sources/appraiserres.dll")
        if fm.fileExists(atPath: appraiser) {
            try Data().write(to: URL(fileURLWithPath: appraiser))   // truncate to 0 bytes
        }
        let autoun = (usbRoot as NSString).appendingPathComponent("autounattend.xml")
        try autounattendXML.write(toFile: autoun, atomically: true, encoding: .utf8)
    }

    static let autounattendXML = """
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>5</Order>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"""
}
