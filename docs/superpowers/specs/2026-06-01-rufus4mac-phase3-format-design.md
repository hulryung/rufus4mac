# rufus4mac — Phase 3 Design (Format Options / Format-only)

**Date:** 2026-06-01
**Status:** Approved for planning
**Scope:** Phase 3 of the rufus4mac roadmap — partition scheme + file system + label, and a
format-only action.

---

## Context

Phase 1 ships raw/DD image writing; Phase 2 ships Windows install-USB creation. Phase 3 adds
Rufus-style **format options** and a **format-only** capability: erase a USB and format it with a
chosen partition scheme, file system, and volume label — no image required.

**Decisions made during brainstorming:**
- **Rufus-style unified UI** (no separate mode): partition scheme + file system + volume label are
  shown on the one screen. When **no image is selected**, the action is **Format**; when an image is
  selected, the existing write path runs and the format options are driven by the image type
  (raw/DD overwrites; Windows forces FAT32) — so they are hidden/disabled then.
- **File systems: FAT32 + exFAT** only (both `diskutil`-native, zero external deps). NTFS (needs
  external tooling), Mac filesystems (APFS/HFS+, Mac-only), full/zero erase, bad-block scan, and
  custom cluster size are **deferred**.
- **Partition scheme: MBR or GPT** (default GPT).
- **Quick format** via `diskutil eraseDisk` (no `sudo` for removable media — verified in Phase 2).

## Scope

### In scope
- Format options on the main screen: partition scheme (MBR/GPT, default GPT), file system
  (exFAT default / FAT32), volume label (text).
- **Format-only**: when no image is selected, the primary button formats the selected USB with the
  chosen options via `diskutil eraseDisk`.
- Volume-label normalization (uppercase, allowed characters, length limits, sensible default).
- A confirmation dialog before the destructive format; internal disks remain excluded (existing safety).

### Out of scope (deferred)
- NTFS and Mac-only filesystems (APFS/HFS+).
- Full format (zeroing the whole device) and bad-block surface scan.
- Custom cluster/allocation size (the formatter default is used).
- Changing the behavior of the existing image-write paths (raw/DD, Windows) beyond
  hiding/disabling format options when an image is selected.

## Architecture

`ProcessRunner` (currently in `WindowsMedia`) is generic system-process infrastructure and is
needed here too, so it is extracted into a small shared module.

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `SystemTools` (new) | `ProcessRunner`/`ProcessResult`/`SystemProcessRunner` — moved out of `WindowsMedia`. | Foundation |
| `DiskFormat` (new) | `FormatOptions` (`PartitionScheme` {mbr, gpt}, `FileSystem` {exfat, fat32}, `label`, with label normalization) and `DiskFormatter.format(bsdName:options:) throws`. | SystemTools |
| `WindowsMedia` (modified) | `import SystemTools` instead of defining `ProcessRunner` (WimTool, ISOInspector, WindowsUSBWriter, and the test `FakeRunner` update their imports). | SystemTools |
| `App` | `FormatRunner` (`@MainActor ObservableObject`, drives `DiskFormatter` off-main; same `phase`/`finished`/`isRunning`/`errorText` shape as the other writers) + `ContentView` format-options UI and routing. | DiskFormat |

### `diskutil` mapping
`DiskFormatter.format` runs: `diskutil eraseDisk <personality> <label> <scheme> /dev/<bsdName>`
- exFAT → personality `ExFAT`; FAT32 → personality `MS-DOS FAT32`.
- scheme → `GPT` or `MBR`.
- Example argv: `["eraseDisk", "ExFAT", "MYUSB", "GPT", "/dev/disk8"]`.

### Label normalization (`FormatOptions`)
- Uppercase; keep only `A–Z 0–9` and a small safe set (drop others); trim.
- Length cap: FAT32 ≤ 11, exFAT ≤ 15 characters.
- Empty after normalization → default `RUFUS4MAC` (capped per filesystem).

### UI states (Rufus-style branching)
| Selection | Format options | Primary button | Action |
|-----------|----------------|----------------|--------|
| No image | enabled | **Format** (enabled once a disk is selected) | `DiskFormatter` quick format |
| Linux / general image | hidden/disabled | Write | existing raw/DD path (unchanged) |
| Windows ISO | hidden/disabled | Write | existing Windows path (unchanged) |

A confirmation dialog precedes the format: "Erase and format `<disk>` as `<fs>`? All data will be
permanently destroyed."

## Privilege model
`diskutil eraseDisk` on external/removable media runs as the console user without `sudo` (verified
in Phase 2). A one-time removable-volume TCC prompt may appear (`NSRemovableVolumesUsageDescription`
already declared). No raw `/dev/rdiskN` write and no `authopen` are involved.

## Error handling

| Situation | Handling |
|-----------|----------|
| `diskutil eraseDisk` fails (busy / permission / bad device) | surface stderr in the status row |
| Empty / invalid label | normalized (uppercase, filtered, length-capped); empty → `RUFUS4MAC` |
| Disk removed mid-format | `diskutil` errors → reported |
| Destructive action | confirmation dialog required; internal/system disks never listed |

## Testing
- `DiskFormatter` (unit, `FakeRunner`): asserts the exact `diskutil eraseDisk` argv for each
  scheme × file-system combination.
- `FormatOptions` label normalization: unit tests (uppercasing, illegal-char filtering, FAT32 vs
  exFAT length caps, empty → default).
- Integration: format an `hdiutil`-attached device as exFAT/GPT and FAT32/MBR; assert via
  `diskutil list`/`info` that the file system and scheme match.
- **SystemTools extraction regression**: the existing 43 tests must still pass after the move.
- App: build-verify; `FormatRunner` lifecycle (isRunning/finished).
- Final manual: format a real USB, mount it on macOS (and ideally Windows) to confirm.

## Constraints
- macOS 13+. Zero new external dependencies (FAT32/exFAT are `diskutil`-native).
- The extraction of `ProcessRunner` into `SystemTools` is an internal refactor; the public
  behavior of `WindowsMedia` is unchanged.
