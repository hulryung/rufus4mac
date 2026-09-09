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
     Windows culture name. `WindowsLocale` maps language+region onto a real Windows locale. When the
     pair isn't one, the fallback keeps the **region** (`en-KR` → `ko-KR`) and only then tries the
     language's default: `InputLocale`/`SystemLocale`/`UserLocale` are regional settings, so
     resolving a Mac in Korea to `en-US` would override the very region the option promises to
     match — and land further from a Korean ISO's own default than setting nothing would.
   - `UILanguage` must name a language the medium actually ships, so `WindowsImageLanguage` reads it
     from the medium's own `sources/lang.ini` — a retail ko-KR ISO lists only `ko-KR`, and asking it
     for `en-US` fails Setup just as hard as an invalid locale. When `lang.ini` is missing we emit no
     `UILanguage` at all and let Setup use the image default.

   So `UILanguage` follows the image while `SystemLocale`/`UserLocale`/`InputLocale` follow the Mac.

Splitting moves ~7 GB and takes minutes, so `WimTool.split` parses wimlib's own meter
(`Splitting WIM: 3126 MiB of 6894 MiB (45%) …`, written to stdout) and forwards the fraction to the
progress callback. `SystemProcessRunner` therefore reads stdout in chunks rather than to EOF, while
stderr keeps draining on its own queue so neither pipe can fill and deadlock. Without this the UI
sits at 0% for the whole split and looks hung.

### Splitting: wimlib or WimSplit

`WindowsUSBWriter` takes any `WimSplitting`. Two implementations exist:

- **`WimTool`** shells out to the bundled `wimlib-imagex` (GPLv3+). Still the default.
- **`NativeWimSplitter`** wraps `Sources/WimSplit`, an MIT-licensed splitter with no external
  binary and no compression codec — see that directory's README for the format and the evidence.

The app exposes the choice as *Split install.wim without wimlib (experimental)*, off by default.
Once a real Windows install from a natively-split USB is confirmed, the native path can become the
default and wimlib can leave the bundle, taking the GPL obligations with it. Note that WimSplit
refuses solid (ESD-style) WIMs, which wimlib can still handle, so that limitation has to be covered
before the switch — an ISO converted from an ESD is the case to watch.

The copy skips one thing: the **El Torito boot catalog** (`boot.catalog`). It is an ISO 9660
structure that firmware reads from fixed sectors of an optical disc — nothing opens it by name, and
a FAT32 USB boots from the MBR boot sector or `\EFI\BOOT\BOOTX64.EFI` instead. macOS exposes it
mode 000, so copying it fails outright; UUP-generated Windows ISOs list one in the directory tree
where Microsoft's retail ISOs do not, which is why only some images hit it. It is excluded in
`fileList` so it stays out of the byte total and of `verifyCopy` as well as the copy itself.

Large files are copied in chunks rather than through `FileManager.copyItem`, which reports nothing
until it returns. A Windows ISO is mostly one enormous file — `install.wim` is often ~90% of the
bytes — so `copyItem` left the progress bar parked (13%, in one report) for minutes and then leapt
it to 96% when that single file landed. Files at or above 16 MB now move 4 MB at a time and report
as they go; smaller ones are not worth the bookkeeping.

`ProgressClock` (in `RufusCore`) turns those callbacks into an elapsed time and a remaining-time
estimate for the UI. The estimate comes from the *current phase's* rate and resets when the phase
changes: the Windows path runs "copying" 0…1 and then "splitting" 0…1 again, at very different
speeds, so one rate carried across them would be wrong rather than merely coarse. It stays hidden
until the phase has run three seconds and moved one percent, since anything sooner is noise.

### Carrying driver installers

A machine whose Wi-Fi driver is missing cannot download one — Samsung's own support pages tell you
to fetch the driver on another PC and bring it over on a USB stick. rufus4mac can put it on the same
stick as the installer.

`DriverStore` copies selected profiles to `Drivers/<model>/` at the USB root and size-checks what
landed, like the image copy. The folder is deliberately **not** `$WinPEDriver$`: Windows Setup loads
drivers from that name during installation, and these are meant to be run by hand afterwards.

A profile is just a directory under `~/Library/Application Support/rufus4mac/Drivers`, so the
library is inspectable and editable in Finder — drop an installer into a folder and it belongs to
that model. Profiles are enumerated recursively, so a whole extracted driver set (INF/SYS/CAT in a
directory) keeps its shape on the USB. Nothing parses the files.

Files are added from disk, fetched from a link, or picked from a small **catalogue** shipped with
the app. The catalogue is chipset-shaped rather than model-shaped, which is what makes it
maintainable: Samsung has no stable per-model URL, but the silicon vendors do, and one Intel package
drives every Intel Wi-Fi adapter from Wireless-AC 9560 through Wi-Fi 7 — every Intel-based Galaxy
Book. The model list is therefore a way to find your machine, not a mapping that decides the file,
so an incomplete list cannot hand out the wrong driver. Snapdragon models (Galaxy Book Go) are
excluded, their Wi-Fi being Qualcomm. Each entry pins a version, size and the vendor's published
SHA-256, and a download that fails the hash is discarded rather than kept — it is an executable
destined for a fresh Windows machine. The app ships **no catalogue of per-model download
URLs**, and that is deliberate: `samsungsvc.co.kr` builds its download links in JavaScript,
`samsung.com`'s model pages carry no direct file links, and the Galaxy Book Download Center — the one
place that does serve per-model drivers — loads its catalogue from an undocumented API and is
self-described as open beta. Any table of URLs would be reverse-engineered guesswork that rots.
`downloadcenter.samsung.com` does serve files without a login once you have a link (verified: HTTP
200, no auth), which is why pasting one works even though generating one does not.

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
