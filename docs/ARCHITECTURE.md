# rufus4mac — Architecture & Internals

How rufus4mac is built and why. For a quick overview and install instructions, see the
[README](../README.md). For the full design history, see the specs and plans under
`docs/superpowers/`.

## Not a literal port

Rufus is Windows-only C/Win32. rufus4mac is a fresh Swift + SwiftUI rebuild. Device discovery
uses IOKit / DiskArbitration; the raw write to `/dev/rdiskN` goes through Apple's `authopen`, so
there is **no persistent privileged helper and no Full Disk Access** — just a one-time
authorization prompt.

## Write paths

rufus4mac picks a path based on the selected image:

- **Linux / general images (raw/DD).** `.iso`/`.img`/`.dmg` are streamed byte-for-byte to the
  device with progress and an optional post-write SHA-256 verification.
- **Windows 10/11 ISOs (FAT32 + split).** Auto-detected and handled by the Windows path below.

### Raw/DD path

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

`authopen` is Apple's setuid-root tool, entitled
(`com.apple.private.tcc.check-allow-on-responsible-process` for removable volumes) to open
removable volumes on behalf of the **responsible app**. Because rufus4mac is that responsible app
(and declares `NSRemovableVolumesUsageDescription`), the user gets a standard authorization prompt
instead of a Full Disk Access settings trip. The write is sector-padded to satisfy raw devices;
verification reads the device back and compares hashes.

**Why not a privileged `SMAppService` daemon?** On macOS 26 a background daemon (and an
`osascript`-elevated root process) is denied raw-disk access — `open()` returns `EPERM` even for
read — because non-TTY processes need a TCC grant (Full Disk Access) for raw devices; only an
interactive TTY `sudo` is exempt. The `authopen` route sidesteps that with an inline prompt. Full
rationale: `docs/superpowers/plans/2026-05-31-rufus4mac-phase1.md`.

### Windows path

Windows install ISOs can't be raw-written: UEFI boots only from FAT, but `sources/install.wim` is
usually larger than FAT32's 4 GB per-file limit. So:

1. Auto-detect a Windows ISO (`sources/install.wim`/`install.esd` + a UEFI boot file).
2. `diskutil eraseDisk MS-DOS WIN MBR /dev/diskN` — formats MBR/FAT32 (no password for removable
   media). **MBR, not GPT:** on a disk of real USB size `diskutil` prepends a 200 MB EFI System
   Partition to a GPT disk, and Windows Setup can adopt that ESP — the one on the USB — as the
   boot volume instead of creating one on the target disk, leaving a machine that boots only
   while the USB is attached. (The ESP is size-dependent: a small disk image gets none, so the
   integration tests can't catch this — `WindowsUSBWriterTests` asserts the argv instead.) The
   code still locates the FAT volume by label rather than a fixed slice index.
3. Mount the ISO (`hdiutil`) and copy its files to the FAT32 volume.
4. If `install.wim` > 4 GB, split it into `install.swm` chunks with the bundled `wimlib-imagex`
   (Windows Setup reads split SWM natively). The app reads the user-picked file itself, so
   TCC-protected sources like `~/Downloads` work.
5. Optional **Windows User Experience** customization: `UnattendBuilder` composes a single
   `autounattend.xml` from a `WindowsCustomization` across the windowsPE / specialize / oobeSystem
   passes — Win11 bypass (`LabConfig` TPM/SecureBoot/RAM/CPU/Storage), a local admin account
   (blank password, which also skips the MS-account screen), skip-privacy OOBE settings, region &
   language, and disabling BitLocker auto-encryption. `WindowsCustomizer.apply` writes that file
   and, only under the Win11 bypass, zeroes `sources/appraiserres.dll`. The username is
   XML-escaped. If no option is selected, no `autounattend.xml` is written.

   Region & language is *not* a straight copy of the Mac's settings, and getting that wrong is fatal:
   Setup rejects an answer file naming a locale it doesn't know with **0x8007000D
   (ERROR_INVALID_DATA)**. Two rules follow.

   - `Locale.current.identifier` is an ICU id (`en_KR` on a Mac set to English in Korea), not a
     Windows culture name. `WindowsLocale` maps language+region onto a real Windows locale, falling
     back to the language's default when the pair isn't one (`en-KR` → `en-US`).
   - `UILanguage` must name a language the medium actually ships, so `WindowsImageLanguage` reads it
     from the medium's own `sources/lang.ini` — a retail ko-KR ISO lists only `ko-KR`, and asking it
     for `en-US` fails Setup just as hard as an invalid locale. When `lang.ini` is missing we emit no
     `UILanguage` at all and let Setup use the image default.

   So `UILanguage` follows the image while `SystemLocale`/`UserLocale`/`InputLocale` follow the Mac.

### Why the Windows path verifies itself

Neither `copyItem` nor `wimlib-imagex split` reliably reports failure when a USB stops accepting
writes — a stick that drops off the bus mid-write (a hub or dock makes this likelier) leaves a
truncated `install.swm`, and `wimlib-imagex` still exits 0. The write then looks successful and only
fails hours later inside Windows Setup with **0x8007000D**, far from any evidence.

So `copyAndSplit` checks its own work before reporting success: `verifyCopy` compares every copied
file's size against the ISO, and `verifySplit` requires the `.swm` parts to total at least 97% of
the source (splitting rewrites each part's header and XML, so the parts come in slightly under),
each to stay under FAT32's 4 GiB file limit, and each to survive `wimlib-imagex info` — a WIM keeps
its XML data at the *end* of the file, so that call fails on a part whose tail never reached the
device. `WindowsWriter` likewise surfaces a failed `diskutil eject` instead of reporting a clean
finish, since an unejected volume may still hold unflushed data.

Design: `docs/superpowers/specs/2026-06-01-rufus4mac-phase2-windows-design.md`.

### Format mode

Select **no image** and the primary button becomes **Format**: the `DiskFormat` module's
`DiskFormatter` runs `diskutil eraseDisk <personality> <label> <scheme> /dev/<bsd>` to quick-format
the USB with the chosen options. `FormatOptions` maps the UI choices — partition scheme (MBR/GPT),
file system (exFAT → `ExFAT`, FAT32 → `MS-DOS FAT32`), and a normalized volume label
(uppercase/`A–Z0–9`, length-capped, default `RUFUS4MAC`). FAT32 + exFAT only (both `diskutil`-native);
NTFS, Mac filesystems, full/zero erase, bad-block scan, and custom cluster size are deferred. No
`sudo` — `diskutil` formats removable media as the console user. When an image *is* selected, the
write path determines the on-disk format, so the format options are hidden.

Design: `docs/superpowers/specs/2026-06-01-rufus4mac-phase3-format-design.md`.

### Checksums

`Checksums.compute` (RufusCore) reads the selected image once, updating MD5 / SHA-1 / SHA-256
(CryptoKit `Insecure.MD5`/`Insecure.SHA1`/`SHA256`) together, and returns lowercase hex. The app's
`ChecksumRunner` runs it off-main on demand and the UI shows the three hashes (selectable to copy).

## Repository layout

```
Package.swift            Swift package: the pure-logic core (no Xcode needed)
Sources/RufusCore/       WriteEngine, device/file block I/O, SHA-256 verify, Checksums (MD5/SHA-1/SHA-256)
Sources/DiskDiscovery/   removableDisks() (boot disk excluded), unmountDisk(), DiskInfo
Sources/SystemTools/     ProcessRunner / ProcessResult / SystemProcessRunner (shared)
Sources/WindowsMedia/    ISOInspector, WimTool, WindowsUSBWriter, Win11Bypass
Sources/DiskFormat/      FormatOptions, DiskFormatter (diskutil quick format)
Sources/TestSupport/     hdiutil-backed test fixtures
Tests/                   unit + integration tests (incl. real-device, unprivileged)
App/                     SwiftUI app — ContentView, view-models, ElevatedWriter (raw/DD), WindowsWriter, FormatRunner
project.yml              xcodegen project definition
rufus4mac.xcodeproj      generated Xcode project (run `xcodegen generate` to refresh)
scripts/make-icon.swift  regenerates the app icon (AppKit/CoreGraphics, no deps)
scripts/bundle-wimlib.sh bundles a relocatable wimlib-imagex into the app
scripts/build-dmg.sh     build + sign + notarize + DMG
docs/                    architecture, manual test checklist, design specs & plans
```

## Build & test

Core library (no Xcode required):

```sh
swift test            # 53 tests
swift build
```

App (Xcode 26 / xcodegen):

```sh
xcodegen generate
xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -destination 'platform=macOS' build
# add CODE_SIGNING_ALLOWED=NO to compile without a signing identity
```

Or `open rufus4mac.xcodeproj` and run the **RufusApp** scheme.

## Package / release

```sh
# one-time: store an App Store Connect app-specific password for notarization
xcrun notarytool store-credentials rufus4mac-notary \
  --apple-id <id> --team-id XGJ87M8ZZR --password <app-specific-password>

./scripts/build-dmg.sh        # builds, bundles wimlib, signs inside-out, notarizes, staples
```

## Notes & limits

- Raw writes are sector-aligned; non-512-aligned images are zero-padded to the next sector.
- Verification reads the whole device back, so on slow USB 2.0 sticks total time is roughly
  *write + read*; turn off "Verify after writing" to skip it.
- Bundled `wimlib-imagex` is LGPLv3 (dynamically linked, relinkable). 
- macOS 13+. Raw disk access can't be sandboxed, so this is a notarized DMG, not a Mac App Store app.
- The Windows-USB path's automated tests use synthetic `hdiutil` images; end-to-end boot on real
  hardware is tracked in `docs/manual-test-checklist.md`.
