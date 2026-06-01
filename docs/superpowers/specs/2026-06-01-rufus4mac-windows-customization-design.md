# rufus4mac — Windows User Experience Customization (Phase 2.1)

**Date:** 2026-06-01
**Status:** Approved for planning
**Scope:** Rufus-style "Windows User Experience" options applied via a generated `autounattend.xml`.

---

## Context

Phase 2 creates Windows install USBs and, for the Win11 bypass, writes a minimal `autounattend.xml`
(LabConfig keys) plus zeroes `sources/appraiserres.dll`. This feature **generalizes that fixed
autounattend into an options-driven builder** so the user can preset common Windows OOBE
customizations — like Rufus's "Windows User Experience" dialog. A USB may contain only one
`autounattend.xml`, so all selected options compose into a single file.

**Decisions (from brainstorming):** include all of the common Rufus options; local-account password
is always blank.

## Scope

### In scope — `WindowsCustomization` options
- `bypassWin11` (existing): TPM/Secure Boot/RAM/CPU/Storage checks (LabConfig) + zero `appraiserres.dll`.
- **Create local account**: `localAccountUsername` (nil = don't create). Creates a local Administrator
  account with a **blank password**; this also makes OOBE skip the Microsoft-account screens.
- **Skip privacy questions**: skip OOBE privacy/data-collection screens (`ProtectYourPC=3`, hide EULA,
  hide online-account screens, etc.).
- **Use this Mac's region & language**: set Windows locale (input/system/UI/user) from the macOS
  BCP-47 locale, and time zone from a best-effort IANA→Windows map (omit if unknown).
- **Disable BitLocker auto-encryption**: `PreventDeviceEncryption=1` in the specialize pass.

All selected options compose into one `autounattend.xml` at the USB root. If none are selected, no
file is written.

### Out of scope (deferred)
Domain join, product-key injection, account password, Wi-Fi pre-config.

## Architecture

This extends the `WindowsMedia` module.

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `WindowsCustomization` (new) | Value type holding the options (see below). The app resolves macOS locale/time-zone and injects `regionLocale`/`regionTimeZone`, keeping `WindowsMedia` free of system-locale reads. | Foundation |
| `UnattendBuilder` (new) | `static func build(_ options: WindowsCustomization) -> String?` — composes a complete `autounattend.xml` from the selected options across the windowsPE / specialize / oobeSystem passes. Returns `nil` if nothing is selected. | Foundation |
| `WindowsCustomizer` (generalized from `Win11Bypass`) | `apply(usbRoot:options:)`: write the built `autounattend.xml` (when non-nil); zero `sources/appraiserres.dll` only when `bypassWin11`. | UnattendBuilder |
| `App` (modified) | Windows-section UI controls for the options; resolve macOS locale/time-zone; pass `WindowsCustomization` through `WindowsWriter` to `WindowsCustomizer`. | WindowsMedia |

```swift
public struct WindowsCustomization: Sendable, Equatable {
    public var bypassWin11: Bool
    public var localAccountUsername: String?   // nil = don't create; created as local admin, blank password
    public var skipPrivacy: Bool
    public var regionLocale: String?           // BCP-47, e.g. "ko-KR"; nil = don't set region
    public var regionTimeZone: String?         // Windows time-zone name; nil = omit
    public var disableBitLocker: Bool
    public var isEmpty: Bool { !bypassWin11 && localAccountUsername == nil && !skipPrivacy
                                && regionLocale == nil && !disableBitLocker }
}
```

### `UnattendBuilder` pass composition
- **windowsPE** (`Microsoft-Windows-Setup`): LabConfig `RunSynchronous` bypass keys — only if `bypassWin11`.
- **windowsPE** (`Microsoft-Windows-International-Core-WinPE`): `InputLocale`/`SystemLocale`/`UILanguage`/`UserLocale` = `regionLocale` — only if `regionLocale != nil`.
- **specialize** (`Microsoft-Windows-Deployment` `RunSynchronous`): `reg add …\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f` — only if `disableBitLocker`.
- **oobeSystem** (`Microsoft-Windows-Shell-Setup`):
  - `OOBE`: `HideEULAPage=true`, `HideOnlineAccountScreens=true`, `HideWirelessSetupInOOBE=true`, `ProtectYourPC=3` — emitted if `skipPrivacy` (and the online-account hide is also implied when creating a local account).
  - `UserAccounts/LocalAccounts`: one `LocalAccount` (username, **blank password**, group `Administrators`) + `AutoLogon` — only if `localAccountUsername != nil`.
  - `TimeZone` = `regionTimeZone` — only if non-nil.
  - International (`UILanguage`/etc.) — if `regionLocale != nil`.
- XML is well-formed, `<?xml …?>` at column 0, single-backslash registry paths.

### Region resolution (app side)
- `regionLocale` = macOS `Locale.current` formatted as BCP-47 (e.g. `ko-KR`, `en-US`).
- `regionTimeZone` = a built-in small IANA→Windows map for common zones (e.g. `Asia/Seoul`→`Korea Standard Time`, `America/Los_Angeles`→`Pacific Standard Time`, `America/New_York`→`Eastern Standard Time`, `Europe/London`→`GMT Standard Time`, `Europe/Berlin`→`W. Europe Standard Time`, `Asia/Tokyo`→`Tokyo Standard Time`, `UTC`→`UTC`); `nil` if the current zone isn't in the map. Done in `WindowsMedia` as a pure lookup the app calls, or inline in the app — pure and unit-testable either way.

### UI (Windows section, shown only for Windows ISOs)
Toggles + a username field, persisted via `@AppStorage`:
- "Bypass Windows 11 compatibility checks" (default on)
- "Create local account" (default off) + a "Username" `TextField` enabled when on
- "Skip privacy questions" (default off)
- "Use this Mac's region & language" (default off)
- "Disable BitLocker auto-encryption" (default off)

`WindowsWriter.start` gains the `WindowsCustomization` parameter and forwards it to `WindowsCustomizer.apply`.

## Error handling
- Empty username while "Create local account" is on → treated as not creating an account
  (or the UI disables Write until a username is entered — UI choice; builder treats empty as nil).
- Writing the file uses the same path as today; failures surface through `WindowsWriter.errorText`.
- No new privilege needs (files written to the mounted FAT32 volume).

## Testing
- `UnattendBuilder.build`: unit tests over option combinations — assert presence/absence of each block
  (LabConfig, `<LocalAccounts>` + username, `ProtectYourPC`, `PreventDeviceEncryption`, locale/time-zone),
  and that all-false/nil → `nil`.
- Generated XML well-formedness via `xmllint --noout` on representative outputs.
- IANA→Windows time-zone map: unit tests (known zone → mapped name; unknown → nil).
- `WindowsCustomizer.apply`: writes the file when non-empty; zeroes `appraiserres.dll` only when
  `bypassWin11`; no file when options empty.
- App build-verify; existing 53 tests stay green.
- Final manual: install Windows with each option and confirm the OOBE behaves as set.

## Constraints
- macOS 13+. No new dependencies.
- `WindowsMedia` stays free of system-locale reads (the app injects locale/time-zone), preserving testability.
- This replaces the fixed `Win11Bypass.autounattendXML`; the appraiserres-zeroing behavior is retained under `bypassWin11`.
