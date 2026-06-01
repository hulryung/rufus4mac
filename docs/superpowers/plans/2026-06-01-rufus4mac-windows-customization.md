# rufus4mac Windows Customization (Phase 2.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users preset Rufus-style "Windows User Experience" options (local account, skip privacy, region/language, disable BitLocker, Win11 bypass) that compose into a single generated `autounattend.xml`.

**Architecture:** Add a `WindowsCustomization` options value type and an `UnattendBuilder` that composes one `autounattend.xml` across windowsPE/specialize/oobeSystem passes; generalize `Win11Bypass` into `WindowsCustomizer` (writes the autounattend + zeroes `appraiserres.dll` only when bypassing); the SwiftUI app surfaces the options and injects the macOS locale/time-zone. All in the existing `WindowsMedia` module.

**Tech Stack:** Swift 6.2, SPM, SwiftUI, xcodegen. Spec: `docs/superpowers/specs/2026-06-01-rufus4mac-windows-customization-design.md`.

**Key facts:**
- A USB has only one `autounattend.xml`; all selected options compose into it. If none selected → no file.
- Creating a local admin account (blank password) also makes OOBE skip the Microsoft-account screens.
- `WindowsMedia` must not read the system locale; the app injects `regionLocale` (BCP-47) and `regionTimeZone` (Windows name).
- Existing 53 tests stay green; the current `Win11Bypass`/`WindowsWriter` Win11-bypass behavior is preserved under `bypassWin11`.

---

## Milestones
1. **M1 — Options + builder:** `WindowsCustomization` + time-zone map (Task 1); `UnattendBuilder` (Task 2).
2. **M2 — Wiring:** generalize to `WindowsCustomizer` + `WindowsWriter` (Task 3).
3. **M3 — App + docs:** UI options + locale/TZ injection (Task 4); docs (Task 5).

---

## File Structure
```
Sources/WindowsMedia/WindowsCustomization.swift  # options struct + WindowsTimeZone IANA→Windows map
Sources/WindowsMedia/UnattendBuilder.swift        # build(_:) -> String? composing autounattend.xml
Sources/WindowsMedia/WindowsCustomizer.swift       # (replaces Win11Bypass.swift) apply(usbRoot:options:)
Tests/WindowsMediaTests/WindowsCustomizationTests.swift
Tests/WindowsMediaTests/UnattendBuilderTests.swift
Tests/WindowsMediaTests/WindowsCustomizerTests.swift  # (replaces Win11BypassTests.swift)
App/WindowsWriter.swift, App/ContentView.swift     # options UI + plumbing (modified)
```

---

## Task 1: `WindowsCustomization` options + time-zone map (pure, TDD)

**Files:**
- Create: `Sources/WindowsMedia/WindowsCustomization.swift`
- Create: `Tests/WindowsMediaTests/WindowsCustomizationTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/WindowsMediaTests/WindowsCustomizationTests.swift`

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WindowsCustomizationTests` → FAIL.

- [ ] **Step 3: Implement** `Sources/WindowsMedia/WindowsCustomization.swift`

```swift
import Foundation

/// Rufus-style "Windows User Experience" options applied via a generated autounattend.xml.
public struct WindowsCustomization: Sendable, Equatable {
    public var bypassWin11: Bool
    /// nil = don't create an account. When set, a local Administrator with a BLANK password is created.
    public var localAccountUsername: String?
    public var skipPrivacy: Bool
    /// BCP-47 locale (e.g. "ko-KR"); nil = don't set region/language.
    public var regionLocale: String?
    /// Windows time-zone name (e.g. "Korea Standard Time"); nil = omit.
    public var regionTimeZone: String?
    public var disableBitLocker: Bool

    public init(bypassWin11: Bool = false, localAccountUsername: String? = nil, skipPrivacy: Bool = false,
                regionLocale: String? = nil, regionTimeZone: String? = nil, disableBitLocker: Bool = false) {
        self.bypassWin11 = bypassWin11
        self.localAccountUsername = localAccountUsername
        self.skipPrivacy = skipPrivacy
        self.regionLocale = regionLocale
        self.regionTimeZone = regionTimeZone
        self.disableBitLocker = disableBitLocker
    }

    public var isEmpty: Bool {
        !bypassWin11 && localAccountUsername == nil && !skipPrivacy
            && regionLocale == nil && !disableBitLocker
    }
}

/// Best-effort IANA → Windows time-zone name lookup for common zones.
public enum WindowsTimeZone {
    static let map: [String: String] = [
        "UTC": "UTC",
        "America/Los_Angeles": "Pacific Standard Time",
        "America/Denver": "Mountain Standard Time",
        "America/Chicago": "Central Standard Time",
        "America/New_York": "Eastern Standard Time",
        "America/Sao_Paulo": "E. South America Standard Time",
        "Europe/London": "GMT Standard Time",
        "Europe/Berlin": "W. Europe Standard Time",
        "Europe/Paris": "Romance Standard Time",
        "Europe/Moscow": "Russian Standard Time",
        "Asia/Seoul": "Korea Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time",
        "Asia/Shanghai": "China Standard Time",
        "Asia/Kolkata": "India Standard Time",
        "Asia/Dubai": "Arabian Standard Time",
        "Australia/Sydney": "AUS Eastern Standard Time",
    ]
    public static func windowsName(forIANA iana: String) -> String? { map[iana] }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WindowsCustomizationTests` → PASS (4 tests). Then full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowsMedia/WindowsCustomization.swift Tests/WindowsMediaTests/WindowsCustomizationTests.swift
git commit -m "feat: WindowsCustomization options + IANA→Windows time-zone map"
```

---

## Task 2: `UnattendBuilder` — compose autounattend.xml (TDD + xmllint)

**Files:**
- Create: `Sources/WindowsMedia/UnattendBuilder.swift`
- Create: `Tests/WindowsMediaTests/UnattendBuilderTests.swift`

- [ ] **Step 1: Write the failing tests** in `Tests/WindowsMediaTests/UnattendBuilderTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class UnattendBuilderTests: XCTestCase {
    func testEmptyOptionsProduceNil() {
        XCTAssertNil(UnattendBuilder.build(WindowsCustomization()))
    }

    func testBypassEmitsLabConfigAndAppraiserNotHere() {
        let xml = UnattendBuilder.build(WindowsCustomization(bypassWin11: true))!
        XCTAssertTrue(xml.contains("BypassTPMCheck"))
        XCTAssertTrue(xml.contains("BypassSecureBootCheck"))
        XCTAssertTrue(xml.contains("LabConfig"))
        XCTAssertTrue(xml.hasPrefix("<?xml"))   // no leading whitespace
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

    func testEmptyUsernameNotTreatedAsAccount() {
        // builder treats empty username as no account (caller should pass nil, but be defensive)
        let xml = UnattendBuilder.build(WindowsCustomization(localAccountUsername: "", skipPrivacy: true))
        XCTAssertNotNil(xml)
        XCTAssertFalse(xml!.contains("<LocalAccounts>"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter UnattendBuilderTests` → FAIL.

- [ ] **Step 3: Implement** `Sources/WindowsMedia/UnattendBuilder.swift`

```swift
import Foundation

/// Composes a single `autounattend.xml` from the selected `WindowsCustomization` options.
/// Returns nil when nothing is selected.
public enum UnattendBuilder {
    public static func build(_ o: WindowsCustomization) -> String? {
        if o.isEmpty { return nil }
        let hasAccount = !(o.localAccountUsername ?? "").isEmpty

        var passes: [String] = []

        // ---- windowsPE ----
        var pe: [String] = []
        if o.bypassWin11 { pe.append(labConfigComponent()) }
        if let loc = o.regionLocale { pe.append(intlWinPEComponent(loc)) }
        if !pe.isEmpty { passes.append(settings("windowsPE", pe)) }

        // ---- specialize ----
        var sp: [String] = []
        if o.disableBitLocker { sp.append(bitLockerComponent()) }
        if !sp.isEmpty { passes.append(settings("specialize", sp)) }

        // ---- oobeSystem ----
        if o.skipPrivacy || hasAccount || o.regionTimeZone != nil {
            passes.append(settings("oobeSystem",
                                   [shellSetupComponent(o, hasAccount: hasAccount)]))
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
        \(passes.joined(separator: "\n"))
        </unattend>
        """
    }

    // MARK: - helpers
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter UnattendBuilderTests` → PASS (7 tests). Then validate well-formedness:
write a representative XML to a temp file and run `xmllint --noout` on it (do this in a throwaway
check or temporarily in a test). If `xmllint` reports a parse error, fix the emitted structure and
re-run. Confirm the no-leading-whitespace `<?xml` (the `testBypass…` test asserts `hasPrefix("<?xml")`).

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowsMedia/UnattendBuilder.swift Tests/WindowsMediaTests/UnattendBuilderTests.swift
git commit -m "feat: UnattendBuilder composes autounattend.xml from customization options"
```

**✅ Milestone 1 complete.**

---

## Task 3: Generalize `Win11Bypass` → `WindowsCustomizer` + wire `WindowsWriter`

**Files:**
- Create: `Sources/WindowsMedia/WindowsCustomizer.swift`
- Delete: `Sources/WindowsMedia/Win11Bypass.swift`
- Move/replace: `Tests/WindowsMediaTests/Win11BypassTests.swift` → `Tests/WindowsMediaTests/WindowsCustomizerTests.swift`
- Modify: `Sources/WindowsMedia/WindowsUSBWriter.swift`? (No — WindowsUSBWriter doesn't call Win11Bypass; the app's `WindowsWriter` does. Confirm with grep.)
- Modify: `App/WindowsWriter.swift`

- [ ] **Step 1: grep current Win11Bypass usage**

Run: `grep -rn "Win11Bypass" Sources App Tests`
Expected callers: `App/WindowsWriter.swift` (`Win11Bypass.apply(usbRoot:)`) and `Tests/WindowsMediaTests/Win11BypassTests.swift`. (If `WindowsUSBWriter.swift` references it, note it — per current code it does not.)

- [ ] **Step 2: Write the failing test** in `Tests/WindowsMediaTests/WindowsCustomizerTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class WindowsCustomizerTests: XCTestCase {
    private func tmpUSB() throws -> URL {
        let usb = FileManager.default.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: usb.appendingPathComponent("sources"),
                                                withIntermediateDirectories: true)
        return usb
    }

    func testBypassZeroesAppraiserAndWritesAutounattend() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try Data(count: 4096).write(to: usb.appendingPathComponent("sources/appraiserres.dll"))

        try WindowsCustomizer.apply(usbRoot: usb.path,
                                    options: .init(bypassWin11: true, skipPrivacy: true))

        let appraiser = usb.appendingPathComponent("sources/appraiserres.dll").path
        XCTAssertEqual(((try? fm.attributesOfItem(atPath: appraiser))?[.size] as? NSNumber)?.intValue, 0)
        let xml = try String(contentsOfFile: usb.appendingPathComponent("autounattend.xml").path, encoding: .utf8)
        XCTAssertTrue(xml.contains("LabConfig"))
        XCTAssertTrue(xml.contains("ProtectYourPC"))
    }

    func testNoBypassDoesNotZeroAppraiserButStillWritesAutounattendForOtherOptions() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try Data(count: 4096).write(to: usb.appendingPathComponent("sources/appraiserres.dll"))

        try WindowsCustomizer.apply(usbRoot: usb.path, options: .init(localAccountUsername: "joe"))

        let appraiser = usb.appendingPathComponent("sources/appraiserres.dll").path
        XCTAssertEqual(((try? fm.attributesOfItem(atPath: appraiser))?[.size] as? NSNumber)?.intValue, 4096) // untouched
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("autounattend.xml").path))
    }

    func testEmptyOptionsWritesNothing() throws {
        let fm = FileManager.default
        let usb = try tmpUSB(); defer { try? fm.removeItem(at: usb) }
        try WindowsCustomizer.apply(usbRoot: usb.path, options: .init())
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("autounattend.xml").path))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter WindowsCustomizerTests` → FAIL.

- [ ] **Step 4: Implement** `Sources/WindowsMedia/WindowsCustomizer.swift` and delete `Win11Bypass.swift`

```swift
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
```
Then `git rm Sources/WindowsMedia/Win11Bypass.swift` and `git rm Tests/WindowsMediaTests/Win11BypassTests.swift` (its behavior is now covered by WindowsCustomizerTests + UnattendBuilderTests).

- [ ] **Step 5: Update `App/WindowsWriter.swift`** to take options and call `WindowsCustomizer`

Change `start(...)` and `run(...)` to thread a `WindowsCustomization` through, replacing the old `bypassWin11: Bool` + `Win11Bypass.apply`:
- `func start(isoPath: String, bsdName: String, customization: WindowsCustomization)` — store/forward it.
- In `run(...)`, replace the block:
  ```swift
  if bypassWin11 {
      await set("bypassing", 1)
      try Win11Bypass.apply(usbRoot: mp)
  }
  ```
  with:
  ```swift
  if !customization.isEmpty {
      await set("customizing", 1)
      try WindowsCustomizer.apply(usbRoot: mp, options: customization)
  }
  ```
  and change `run`'s signature to accept `customization: WindowsCustomization` instead of `bypassWin11: Bool`. (Keep `import WindowsMedia`.)

- [ ] **Step 6: Run**

Run: `swift test` (WindowsCustomizerTests pass; full suite green — note Win11BypassTests is gone, replaced). Then build the app via xcodebuild to confirm `App/WindowsWriter.swift` compiles against the new signature — but ContentView still calls the OLD `start(isoPath:bsdName:bypassWin11:)`, so the app won't build until Task 4. That's expected; for THIS task just run `swift test` (the package compiles fine — App isn't in the package). Do not run xcodebuild yet.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: generalize Win11Bypass into WindowsCustomizer (options-driven autounattend)"
```

**✅ Milestone 2 complete.**

---

## Task 4: App — Windows customization UI + locale/TZ injection (build-verified)

**Files:**
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Add @AppStorage state** near the other Windows state in `ContentView`

```swift
    @AppStorage("winLocalAccount") private var winLocalAccount = false
    @AppStorage("winUsername") private var winUsername = ""
    @AppStorage("winSkipPrivacy") private var winSkipPrivacy = false
    @AppStorage("winUseRegion") private var winUseRegion = false
    @AppStorage("winDisableBitLocker") private var winDisableBitLocker = false
```
(Keep the existing `@AppStorage("bypassWin11") private var bypassWin11`.) Add `import WindowsMedia` if not present.

- [ ] **Step 2: Add a helper that builds the `WindowsCustomization` from UI state**

```swift
    private func windowsCustomization() -> WindowsCustomization {
        let locale: String? = winUseRegion ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : nil
        let tz: String? = winUseRegion ? WindowsTimeZone.windowsName(forIANA: TimeZone.current.identifier) : nil
        let user = winLocalAccount ? winUsername.trimmingCharacters(in: .whitespaces) : ""
        return WindowsCustomization(
            bypassWin11: bypassWin11,
            localAccountUsername: user.isEmpty ? nil : user,
            skipPrivacy: winSkipPrivacy,
            regionLocale: locale,
            regionTimeZone: tz,
            disableBitLocker: winDisableBitLocker)
    }
```
(`Locale.current.identifier` like `ko_KR` → `ko-KR`. This is the macOS-side injection the spec requires.)

- [ ] **Step 3: Expand the Windows section** — replace the existing `if image.isWindows { field("Windows install media") { Toggle bypass } }` with:

```swift
            if image.isWindows {
                field(title: "Windows install media", systemImage: "window.shade.closed") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Bypass Windows 11 compatibility checks", isOn: $bypassWin11)
                        Toggle("Skip privacy questions", isOn: $winSkipPrivacy)
                        Toggle("Use this Mac's region & language", isOn: $winUseRegion)
                        Toggle("Disable BitLocker auto-encryption", isOn: $winDisableBitLocker)
                        Toggle("Create local account", isOn: $winLocalAccount)
                        if winLocalAccount {
                            TextField("Username", text: $winUsername)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .toggleStyle(.checkbox).font(.callout)
                }
            }
```

- [ ] **Step 4: Update `startWrite()`** to pass the customization to `winWriter.start`

```swift
        if image.isWindows {
            winWriter.start(isoPath: url.path, bsdName: disk.bsdName, customization: windowsCustomization())
        } else if let hash = image.sha256Base64 {
            ...
        }
```
(Matches the new `WindowsWriter.start(isoPath:bsdName:customization:)` from Task 3.)

- [ ] **Step 5: Build-verify + run**

Run: `xcodegen generate && xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -configuration Debug -derivedDataPath build/run -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. Fix any Swift 6 issues minimally. `swift test` still green. Launch with a Windows ISO selected (or just confirm it builds + the app launches): the Windows section shows all five toggles; "Create local account" reveals the Username field.

- [ ] **Step 6: Commit**

```bash
git add App/ContentView.swift project.yml rufus4mac.xcodeproj/project.pbxproj
git commit -m "feat: Windows User Experience options in the UI (local account, privacy, region, BitLocker)"
```

**✅ Milestone 3 (app) complete.**

---

## Task 5: Docs

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/manual-test-checklist.md`

- [ ] **Step 1: README** — under the Windows usage note, add: "For Windows ISOs you can also preset **Windows User Experience** options — create a local account, skip privacy questions, match this Mac's region/language, and disable BitLocker auto-encryption — applied via a generated `autounattend.xml`."

- [ ] **Step 2: ARCHITECTURE.md** — in the Windows-path section, note that `UnattendBuilder` composes a single `autounattend.xml` from `WindowsCustomization` across the windowsPE/specialize/oobeSystem passes, and `WindowsCustomizer` writes it (+ zeroes `appraiserres.dll` only under `bypassWin11`); the app injects macOS locale/time-zone.

- [ ] **Step 3: manual-test-checklist.md** — add to the Phase 2 section:
```markdown
### Windows User Experience options
- [ ] Enable "Create local account" + username → after install, OOBE skips the Microsoft-account screen and the named local admin exists (blank password).
- [ ] Enable "Skip privacy questions" → OOBE privacy screens are skipped.
- [ ] Enable "Use this Mac's region & language" → installed Windows uses the matching locale (and time zone if mapped).
- [ ] Enable "Disable BitLocker auto-encryption" → the system drive is not auto-encrypted.
- [ ] With all options off (and no bypass), no `autounattend.xml` is written.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ARCHITECTURE.md docs/manual-test-checklist.md
git commit -m "docs: Windows User Experience customization options"
```

**✅ Milestone 3 (docs) complete.**

---

## Self-Review Notes (addressed)
- **Spec coverage:** options struct + TZ map (Task 1); UnattendBuilder pass composition for bypass/local-account/privacy/region/bitlocker + nil-when-empty (Task 2); WindowsCustomizer generalization + appraiserres-only-under-bypass + WindowsWriter wiring (Task 3); UI for all options + macOS locale/TZ injection (Task 4); docs (Task 5). Error handling: empty username → treated as no account (UnattendBuilder + the UI helper both guard); file-write failures surface via WindowsWriter.errorText.
- **Placeholder scan:** none.
- **Type consistency:** `WindowsCustomization(bypassWin11:localAccountUsername:skipPrivacy:regionLocale:regionTimeZone:disableBitLocker:)`/`.isEmpty`, `WindowsTimeZone.windowsName(forIANA:)`, `UnattendBuilder.build(_:)`, `WindowsCustomizer.apply(usbRoot:options:)`, `WindowsWriter.start(isoPath:bsdName:customization:)` used consistently across tasks. `Win11Bypass` is fully removed (Task 3).
- **Deferral:** domain join, product key, account password, Wi-Fi — out of scope per spec.
