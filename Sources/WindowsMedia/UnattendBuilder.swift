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
        if let loc = o.regionLocale { pe.append(intlWinPEComponent(loc)) }
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

    private static func intlWinPEComponent(_ loc: String) -> String {
        """
            <component \(attrs("Microsoft-Windows-International-Core-WinPE"))>
              <SetupUILanguage><UILanguage>\(loc)</UILanguage></SetupUILanguage>
              <InputLocale>\(loc)</InputLocale>
              <SystemLocale>\(loc)</SystemLocale>
              <UILanguage>\(loc)</UILanguage>
              <UserLocale>\(loc)</UserLocale>
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
        if hasAccount, let user = o.localAccountUsername {
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
            inner += "      <TimeZone>\(tz)</TimeZone>\n"
        }
        return """
            <component \(attrs("Microsoft-Windows-Shell-Setup"))>
        \(inner)    </component>
        """
    }
}
