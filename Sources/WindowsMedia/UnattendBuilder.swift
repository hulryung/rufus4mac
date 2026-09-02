import Foundation

/// Composes a single `autounattend.xml` from the selected `WindowsCustomization` options.
/// Returns nil when nothing is selected.
public enum UnattendBuilder {
    public static func build(_ o: WindowsCustomization) -> String? {
        if o.isEmpty { return nil }
        let hasAccount = !(o.localAccountUsername ?? "").isEmpty

        var passes: [String] = []

        var pe: [String] = []
        if o.bypassWin11 { pe.append(labConfigComponent()) }
        if o.regionLocale != nil || o.imageUILanguage != nil {
            pe.append(intlWinPEComponent(userLocale: o.regionLocale, uiLanguage: o.imageUILanguage))
        }
        if !pe.isEmpty { passes.append(settings("windowsPE", pe)) }

        var sp: [String] = []
        if o.disableBitLocker { sp.append(bitLockerComponent()) }
        if !sp.isEmpty { passes.append(settings("specialize", sp)) }

        if o.skipPrivacy || hasAccount || o.regionTimeZone != nil {
            passes.append(settings("oobeSystem", [shellSetupComponent(o, hasAccount: hasAccount)]))
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
        \(passes.joined(separator: "\n"))
        </unattend>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let wcm = "xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\""
    private static func attrs(_ name: String) -> String {
        "name=\"\(name)\" processorArchitecture=\"amd64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\" \(wcm)"
    }
    private static func settings(_ pass: String, _ components: [String]) -> String {
        "  <settings pass=\"\(pass)\">\n" + components.joined(separator: "\n") + "\n  </settings>"
    }

    private static func labConfigComponent() -> String {
        let keys = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck", "BypassStorageCheck"]
        let cmds = keys.enumerated().map { i, k in
            "        <RunSynchronousCommand wcm:action=\"add\"><Order>\(i + 1)</Order>" +
            "<Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(k) /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"
        }.joined(separator: "\n")
        return """
            <component \(attrs("Microsoft-Windows-Setup"))>
              <RunSynchronous>
        \(cmds)
              </RunSynchronous>
            </component>
        """
    }

    /// `uiLanguage` is what Setup and the installed OS display and MUST exist in the image;
    /// `userLocale` is only formats/keyboard, so the two are emitted independently. Element order
    /// follows the documented sample for this component.
    private static func intlWinPEComponent(userLocale: String?, uiLanguage: String?) -> String {
        let ui = uiLanguage.map(xmlEscape)
        let loc = userLocale.map(xmlEscape)
        var lines: [String] = []
        if let ui { lines.append("      <SetupUILanguage><UILanguage>\(ui)</UILanguage></SetupUILanguage>") }
        if let loc {
            lines.append("      <InputLocale>\(loc)</InputLocale>")
            lines.append("      <SystemLocale>\(loc)</SystemLocale>")
        }
        if let ui { lines.append("      <UILanguage>\(ui)</UILanguage>") }
        if let loc { lines.append("      <UserLocale>\(loc)</UserLocale>") }
        return """
            <component \(attrs("Microsoft-Windows-International-Core-WinPE"))>
        \(lines.joined(separator: "\n"))
            </component>
        """
    }

    private static func bitLockerComponent() -> String {
        """
            <component \(attrs("Microsoft-Windows-Deployment"))>
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
        """
    }

    private static func shellSetupComponent(_ o: WindowsCustomization, hasAccount: Bool) -> String {
        var inner = ""
        if o.skipPrivacy || hasAccount {
            inner += """
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>

        """
        }
        if hasAccount, let user = o.localAccountUsername.map(xmlEscape) {
            inner += """
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(user)</Name>
                    <Group>Administrators</Group>
                    <DisplayName>\(user)</DisplayName>
                    <Password><Value></Value><PlainText>true</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>

        """
        }
        if let tz = o.regionTimeZone {
            inner += "      <TimeZone>\(xmlEscape(tz))</TimeZone>\n"
        }
        return """
            <component \(attrs("Microsoft-Windows-Shell-Setup"))>
        \(inner)    </component>
        """
    }
}
