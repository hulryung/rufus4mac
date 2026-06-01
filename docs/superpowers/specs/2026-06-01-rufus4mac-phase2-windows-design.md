# rufus4mac — Phase 2 Design (Windows Install USB)

**Date:** 2026-06-01
**Status:** Approved for planning
**Scope:** Phase 2 of the rufus4mac roadmap — UEFI Windows 10/11 install media

---

## Context

Phase 1 ships a raw/DD image writer (great for isohybrid Linux ISOs and `.img`). Windows
install ISOs cannot be written that way: UEFI firmware boots only from FAT, but a modern
Windows ISO's `sources/install.wim` is usually larger than FAT32's 4 GB per-file limit.

Phase 2 adds a **Windows mode**: given a Windows 10/11 ISO and a target USB, produce a
**UEFI-bootable Windows install USB**, with an optional **Windows 11 hardware-check bypass**.

**Decisions made during brainstorming:**
- Target: modern **UEFI** Windows 10/11 install media only (no legacy BIOS, no Windows To Go).
- Approach **B — FAT32 + split `install.wim`**: format the USB as a single GPT/FAT32 volume
  (maximum UEFI compatibility), copy the ISO contents, and split `install.wim` into
  `install.swm` chunks when it exceeds 4 GB. Windows Setup natively reads split SWM files.
- Splitting uses the bundled open-source CLI **`wimlib-imagex`** (LGPLv3).
- Win11 bypass is included.

Approaches **C (UEFI:NTFS)** and **D (built-in only, ≤4 GB wim)** were rejected: C needs heavy
macOS NTFS write tooling; D can't handle the >4 GB `install.wim` typical of Win11.

## Scope

### In scope
- Detect a Windows ISO and route it to Windows mode (Linux/general images keep the Phase 1
  raw/DD path).
- Format the target USB as **GPT + a single FAT32 partition** via `diskutil`.
- Mount the ISO (`hdiutil`, read-only) and copy all contents to the USB, except:
  - `sources/install.wim` ≤ 4 GB → copied as-is.
  - `sources/install.wim` > 4 GB → split into `sources/install.swm` (4000 MB chunks) with
    `wimlib-imagex`; the original `install.wim` is not copied.
- Optional **Windows 11 compatibility bypass**: replace `sources/appraiserres.dll` with a
  0-byte file, plus add an `autounattend.xml` with `LabConfig` bypass keys.
- Progress reporting (copying, splitting) and eject on completion.

### Out of scope (later phases / not now)
- Legacy BIOS / MBR boot, Windows To Go.
- UEFI:NTFS / exFAT paths.
- Offline registry editing of `boot.wim` (the appraiserres + autounattend method is used instead).
- ISO download.

## Architecture

A new SPM library target **`WindowsMedia`** orchestrates the build, driving system tools
(`diskutil`, `hdiutil`, `wimlib-imagex`) via `Process`. Disk enumeration/selection reuses the
existing `DiskDiscovery`.

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `ProcessRunner` (protocol + real impl) | Run a process to completion or stream stdout lines; capture stderr. Injectable for tests. | Foundation |
| `ISOInspector` | Mount an ISO read-only (`hdiutil attach`), detect Windows (`sources/install.wim`/`install.esd` + `efi/boot/bootx64.efi` or `bootmgr.efi`), report the install image path and size, then detach. | hdiutil, ProcessRunner |
| `WimTool` | Wrap `wimlib-imagex split <wim> <out.swm> 4000`; locate the bundled binary; parse progress. | wimlib-imagex, ProcessRunner |
| `WindowsUSBWriter` | Orchestrate: format (diskutil) → copy files (handling install.wim) → split via WimTool → apply Win11 bypass → eject. Emits progress. | diskutil, ISOInspector, WimTool, FileManager |

### Bundled dependency: `wimlib-imagex`
- Open-source (LGPLv3) single CLI used for WIM splitting.
- Bundled in the app at `Contents/Resources/wimlib/` (binary + required dylibs, `@rpath`
  adjusted by the packaging script). Lookup order: bundled → `/opt/homebrew/bin/wimlib-imagex`
  (dev fallback) → clear error if absent.
- LGPL compliance: dynamic linking + attribution in README and the app's About box.

### App integration
- `ImageSelection` detects ISO type after selection and sets an `isWindows` flag (via
  `ISOInspector`).
- `ContentView`: when the image is a Windows ISO, show a "Windows install media" section with a
  **"Bypass Windows 11 compatibility checks"** checkbox; the Write button runs the Windows flow
  (a `WindowsWriter` observable mirroring Phase 1's `phase/fraction/finished/errorText`). For
  Linux/general images, the existing `ElevatedWriter` (raw/DD) path is unchanged.

## Privilege model

- **Format** (`diskutil eraseDisk MS-DOS "WIN" GPT /dev/diskN`): external/removable disks are
  erasable by the console user without `sudo` (the same right Disk Utility uses). **This is a
  design assumption to validate with a spike** (test against an `hdiutil`-attached device). If it
  proves to require elevation, fall back to the Phase 1 `authopen`-style elevation.
- **Copy / split / bypass**: writes go to the mounted FAT32 volume (`/Volumes/WIN`) as the user —
  no root. A removable-volume TCC prompt may appear once (`NSRemovableVolumesUsageDescription`
  already declared).

This avoids Phase 1's raw-device-write TCC problem entirely (no `/dev/rdiskN` writes here).

## Error handling

| Situation | Handling |
|-----------|----------|
| Not actually a Windows ISO | Detection routes it to the Linux/general (Phase 1) path |
| `diskutil eraseDisk` fails (busy/permission) | Report reason; force-unmount + retry, or elevation fallback |
| `wimlib-imagex` missing or split fails | Clear error ("WIM split tool unavailable"); abort |
| `install.wim` > 4 GB | Auto-switch to the split path (threshold 4000 MB) |
| USB removed mid-copy | Detect, abort, warn about partial media |
| ISO mount fails | Report, abort |
| ISO larger than USB capacity | Pre-flight check rejects |

## Testing

- `ISOInspector` detection: unit-test the file-presence logic against fake directory trees
  (with/without `sources/install.wim`).
- `WimTool`/split: integration test — create a small test WIM with wimlib, split it, assert the
  resulting `.swm` count/sizes (runs where wimlib is available).
- `WindowsUSBWriter`: inject a fake `ProcessRunner` to assert the command sequence and arguments;
  verify file copy, `appraiserres.dll` zeroing, and `autounattend.xml` generation against a temp
  directory.
- Format + copy end-to-end: against an `hdiutil`-attached device (safe), exercise
  `diskutil` format → mount → copy.
- Final: manual checklist — write a real Windows 10/11 ISO to a USB and boot a UEFI PC.

## Constraints
- macOS 13+ (built/tested on macOS 26, Apple Silicon).
- Adds one bundled tool (`wimlib-imagex`); otherwise system tools + Swift.
- FAT32 path → broad UEFI compatibility; split SWM is read natively by Windows Setup.
