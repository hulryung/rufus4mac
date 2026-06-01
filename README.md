# rufus4mac

A macOS-native equivalent of [Rufus](https://rufus.ie) — create bootable USB drives
(Linux distros and general disk images) on macOS.

> **Not a literal port.** Rufus is Windows-only C/Win32; rufus4mac is a fresh
> Swift + SwiftUI rebuild. Device discovery uses IOKit / DiskArbitration; the raw
> write to `/dev/rdiskN` goes through Apple's `authopen`, so there is **no persistent
> privileged helper and no Full Disk Access** — just a one-time authorization prompt.

## Status

**Phase 1 (raw / DD image writer) — works on real hardware.** Verified end-to-end:
selecting a Linux ISO and writing it to a USB stick (write + SHA-256 verify) on macOS 26,
Apple Silicon.

- ✅ Pure-Swift core: sector-aligned streaming write, post-write SHA-256 verification,
  removable-disk discovery (the boot disk is structurally excluded), whole-disk unmount.
  23 unit/integration tests, including end-to-end runs against `hdiutil`-backed devices.
- ✅ SwiftUI app with an inline authorization flow — no daemon install, no manual settings.

## Install

Download `rufus4mac-<version>.dmg` from the [Releases](https://github.com/hulryung/rufus4mac/releases)
page, open it, and drag **RufusApp** to Applications. Requires **macOS 13+** (Apple Silicon or Intel).

> The build is signed with a Developer ID but not yet notarized, so on first launch macOS Gatekeeper
> may block it. Right-click the app → **Open** → **Open** to run it once; subsequent launches are normal.

Writing to a USB triggers a one-time macOS authorization prompt (via `authopen`) — no Full Disk
Access or background helper is installed.

## How it works

```
┌──────────────────────────────┐
│ rufus4mac (SwiftUI app)       │
│  • pick image, pick USB disk  │
│  • SHA-256 the source         │
│  • diskutil unmountDisk       │   (removable media unmounts without root)
│  • stream image ──▶ authopen  │   /usr/libexec/authopen -w /dev/rdiskN
│  • read back ◀── authopen     │   verify SHA-256
└──────────────────────────────┘
```

`authopen` is Apple's setuid-root tool, entitled to open removable volumes on behalf of
the **responsible app**. Because rufus4mac is that responsible app (and declares
`NSRemovableVolumesUsageDescription`), the user gets a standard authorization prompt
instead of a Full Disk Access settings trip. The write is sector-padded to satisfy raw
devices; verification reads the device back and compares hashes.

Why not a privileged `SMAppService` daemon? A background daemon can't receive the TCC
prompt and is denied raw-disk access (EPERM) without manual Full Disk Access. The
`authopen` route avoids that — see `docs/` for the full write-up.

## Layout

```
Package.swift            Swift package: the pure-logic core (no Xcode needed)
Sources/RufusCore/       WriteEngine, device/file block I/O, SHA-256 verify
Sources/DiskDiscovery/   removableDisks(), unmountDisk(), DiskInfo
Sources/TestSupport/     hdiutil-backed test fixtures
Tests/                   unit + integration tests (incl. real-device, unprivileged)
App/                     SwiftUI app — ContentView, view-models, ElevatedWriter (authopen)
project.yml              xcodegen project definition
rufus4mac.xcodeproj      generated Xcode project (run `xcodegen generate` to refresh)
scripts/make-icon.swift  regenerates the app icon (AppKit/CoreGraphics, no deps)
scripts/build-dmg.sh     sign + notarize + DMG (needs a Developer ID + notary profile)
docs/                    design spec, implementation plan, manual test checklist
```

## Build & test

Core library (no Xcode required):

```sh
swift test            # 23 tests
swift build
```

App (Xcode 26 / xcodegen):

```sh
xcodegen generate
xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -destination 'platform=macOS' build
# add CODE_SIGNING_ALLOWED=NO to compile without a signing identity
```

Or just `open rufus4mac.xcodeproj` in Xcode and run the **RufusApp** scheme.

## Package / release

```sh
./scripts/build-dmg.sh        # see the script header for prerequisites
```

## Using it

1. Click **Choose…** and pick an `.iso`, `.img`, or `.dmg`.
2. Pick the target USB from **Target disk** (internal disks are never listed).
3. Click **Write** → confirm → enter your password when macOS prompts.
4. Watch **Writing… → Verifying… → Done**.

> ⚠️ Writing erases the entire target disk. Double-check the selection.

## Notes & limits

- Raw writes are sector-aligned; non-512-aligned images are zero-padded to the next sector.
- Verification reads the whole device back, so on slow USB 2.0 sticks the total time is
  roughly *write + read*. (A "verify after writing" toggle is a planned option.)
- macOS 13+ (built/tested on macOS 26, Apple Silicon). Distribution is a notarized DMG —
  raw disk access can't be sandboxed, so this isn't a Mac App Store app.

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| **1 — MVP** | Device selection, image selection, raw/DD write to USB, verify | ✅ done |
| **2 — Windows media** | UEFI Windows 10/11 install USB: GPT/FAT32 + `install.wim` split (bundled `wimlib`), optional Windows 11 TPM/Secure Boot/RAM bypass | ✅ done |
| **3 — Full format options** | MBR/GPT, FAT32/exFAT/NTFS formatting, cluster size, labels, bad-block check | planned |
| **4 — Extras** | ISO downloader, Linux persistence, checksums, localization | planned |

**Windows ISOs are auto-detected** (`sources/install.wim`/`install.esd` + UEFI boot files). They're
written as a GPT/FAT32 volume with files copied from the mounted ISO; an `install.wim` over 4 GB is
split into `install.swm` via a bundled `wimlib-imagex` (so it fits FAT32 yet Windows Setup still
reads it). Enable "Bypass Windows 11 compatibility checks" to zero `appraiserres.dll` and add an
`autounattend.xml` with the LabConfig bypass keys. Formatting uses `diskutil` (no elevation needed
for removable media).

## License

TBD
