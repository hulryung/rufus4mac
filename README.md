# rufus4mac

A macOS-native equivalent of [Rufus](https://rufus.ie) — create bootable USB drives
(Linux distros and general disk images) on macOS.

> **Not a literal port.** Rufus is Windows-only C/Win32; rufus4mac is a fresh
> Swift + SwiftUI rebuild. The privileged disk work uses IOKit / DiskArbitration and
> raw `/dev/rdiskN` access via a root LaunchDaemon helper reached over XPC.

## Status

**Phase 1 (raw/DD image writer) — core complete, app pending final hardware/signing steps.**

- ✅ **Pure-Swift core (Milestones 1–2):** image streaming, sector-aligned raw writing,
  SHA-256 verification, removable-disk discovery (boot disk excluded), whole-disk unmount.
  23 unit/integration tests, validated end-to-end against real `hdiutil` device nodes.
- ✅ **App + helper (Milestones 3–4):** SwiftUI app (`RufusApp`), root XPC helper
  (`RufusHelper`) with fail-closed target validation, SMAppService registration, bundle
  embedding. All build-verified via `xcodebuild`.
- ⏳ **Remaining (manual):** Developer ID signing + notarization (`scripts/build-dmg.sh`),
  and the destructive real-USB pass (`docs/manual-test-checklist.md`). SMAppService
  registration and the privileged write only work from a signed build.

See the design spec and implementation plan under `docs/superpowers/`.

## Layout

```
Package.swift            Swift package: the pure-logic core (no Xcode needed)
Sources/RufusCore/       WriteEngine, device/file block I/O, SHA-256 verify
Sources/DiskDiscovery/   removableDisks(), unmountDisk(), DiskInfo
Sources/XPCProtocol/     app↔helper @objc XPC contract
Sources/TestSupport/     hdiutil-backed test fixtures
Tests/                   unit + integration tests (incl. real-device, unprivileged)
App/                     SwiftUI app (RufusApp target)
Helper/                  root LaunchDaemon (RufusHelper target) + its plist
project.yml              xcodegen project definition
rufus4mac.xcodeproj      generated Xcode project (run `xcodegen generate` to refresh)
scripts/build-dmg.sh     sign + notarize + DMG (needs Developer ID + notary profile)
docs/                    design spec, implementation plan, manual test checklist
```

## Build & test

Core library (no Xcode required):

```sh
swift test            # 23 tests
swift build
```

App + helper (Xcode 26 / xcodegen):

```sh
xcodegen generate
xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp    -destination 'platform=macOS' build
xcodebuild -project rufus4mac.xcodeproj -scheme RufusHelper -destination 'platform=macOS' build
# add CODE_SIGNING_ALLOWED=NO to compile without a signing identity
```

Or open `rufus4mac.xcodeproj` in Xcode.

## Package / release

```sh
./scripts/build-dmg.sh        # see the script header for prerequisites
```

## Roadmap

| Phase | Scope |
|-------|-------|
| **1 — MVP (current)** | Device selection, image selection, raw/DD write to USB, verify |
| **2 — Windows media** | install.wim split for FAT32, UEFI:NTFS, Windows 11 TPM/Secure Boot bypass |
| **3 — Full format options** | MBR/GPT, FAT32/exFAT/NTFS formatting, cluster size, labels, bad-block check |
| **4 — Extras** | ISO downloader, Linux persistence, checksums, localization |

## License

TBD
