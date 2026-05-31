# rufus4mac — Phase 1 Design (Raw/DD Image Writer)

**Date:** 2026-05-31
**Status:** Approved for planning
**Scope:** Phase 1 of the rufus4mac roadmap

---

## Context

rufus4mac is a macOS-native equivalent of [Rufus](https://rufus.ie). Rufus itself
cannot be literally ported: its core depends on Windows-only APIs (Format API, WMI,
SetupAPI, Windows bootloader code). rufus4mac is therefore a native macOS rebuild of
Rufus-equivalent functionality.

**Stack decision:** Swift + SwiftUI native. GUI in SwiftUI; low-level disk work in
Swift via IOKit / DiskArbitration and direct `/dev/rdiskN` access. No external tool
dependencies (no shelling out to `diskutil`/`dd`).

**Roadmap (full project):**

| Phase | Scope |
|-------|-------|
| **1 — MVP (this doc)** | Device selection + image selection + raw/DD write to USB + verify |
| **2 — Windows media** | install.wim split for FAT32, UEFI:NTFS, Win11 TPM/Secure Boot bypass |
| **3 — Full format options** | MBR/GPT partition schemes, FAT32/exFAT/NTFS formatting, cluster size, volume labels, bad-block check |
| **4 — Extras** | ISO downloader, Linux persistence, checksums, localization |

Each phase gets its own spec → plan → implementation cycle.

---

## Phase 1 Scope

### In scope

- List removable/external disks (model, capacity, removable flag) via
  DiskArbitration / IOKit.
- Select an image file: `.iso`, `.img`, `.dmg`.
- Unmount the target disk, then perform a **raw byte-for-byte write** of the image
  to `/dev/rdiskN` (admin authorization required).
- Real-time progress (bytes written, MB/s, estimated time remaining).
- Post-write **verification**: read back exactly the number of bytes written (equal to
  the source image size, ignoring any trailing capacity on a larger disk) and compare a
  hash of that region against the source image's hash.
- Safety: internal/system disks excluded from the list (removable only); final
  confirmation dialog before writing; cancellation support.

### Out of scope (deferred to later phases)

- Formatting / partitioning (FAT32/exFAT/NTFS creation).
- "ISO copy mode" (format + file copy) — requires a filesystem formatter.
- Windows-specific media handling (install.wim split, UEFI:NTFS, Win11 bypass).
- ISO download, Linux persistence, checksums UI, localization.

### Why raw/DD-only for Phase 1

Creating a FAT32 filesystem in pure Swift (without `newfs_msdos`) is a large effort
and conflicts with the "no external dependencies" decision. Raw/DD writing covers the
vast majority of bootable-USB needs: modern Linux ISOs are isohybrid and boot directly
from a raw write, and `.img`/`.dmg` images are written as-is. Formatting moves to
Phase 3.

---

## Architecture

Writing to a raw disk requires **root**. The macOS-idiomatic structure keeps the GUI
unprivileged and isolates privileged work in a separate helper daemon, communicating
over XPC.

```
┌─────────────────────────────┐     XPC      ┌──────────────────────────┐
│  rufus4mac (GUI, no privs)   │ ◄──────────► │ RufusHelper (root daemon)│
│  - SwiftUI views / viewmodels│              │  - unmount disk           │
│  - disk list                 │              │  - /dev/rdiskN raw write  │
│  - image picker / confirm    │              │  - progress reporting     │
│  - progress UI               │              │  - post-write verify      │
└─────────────────────────────┘              └──────────────────────────┘
            │                                            │
            └──────── shared: DiskModel, XPCProtocol ────┘
```

### Modules

| Module | Responsibility | Depends on |
|--------|----------------|------------|
| `DiskDiscovery` | Enumerate removable disks (model, capacity, removable flag). Runs unprivileged. | DiskArbitration, IOKit |
| `XPCProtocol` | App↔helper interface (start write / progress / cancel / complete). | Foundation |
| `RufusApp` | SwiftUI UI + state. Installs helper, sends requests, shows progress. | DiskDiscovery, XPCProtocol |
| `RufusHelper` | Root daemon. Unmount → raw write → verify, pushes progress. | XPCProtocol |
| `WriteEngine` | (inside helper) Block streaming, progress accounting, hash verification. | — |

**Helper installation:** registered via `SMAppService` (macOS 13+); one-time admin
authorization on first use.

### Data flow

1. App starts → `DiskDiscovery` lists removable disks → SwiftUI list.
2. User selects a disk + image → final confirmation dialog (data-loss warning).
3. App ensures the helper is installed (registers + authorizes if missing).
4. App → helper: write request (image path, target BSD disk name).
5. Helper: unmount the whole disk → open `/dev/rdiskN` → stream blocks, pushing
   progress over XPC.
6. Helper: verify (read back, compare hash) → report completion.
7. App: show result / eject disk.

### Key safety mechanisms

- Only removable disks are listed; internal/system disks are never shown.
- Disk identity is re-confirmed immediately before writing.
- Cancellation supported throughout; on cancel the fd is closed cleanly.

---

## Error Handling

### Pre-flight (before any write)

- Image size ≤ target disk capacity (reject immediately if larger).
- Target disk still present and still removable.
- Image file readable.

### During operation

| Situation | Handling |
|-----------|----------|
| Helper not installed / install rejected | Inform + retry. Do not proceed with write. |
| XPC connection lost mid-write | Abort immediately; warn "disk may be corrupt — redo required". |
| Disk removed during write | Detected via DiskArbitration → graceful abort. |
| Unmount failure (volume busy) | Report reason; offer force-unmount option. |
| I/O write error | Abort; report bytes written. |
| Verification mismatch | Fail — "disk not trustworthy". |
| User cancellation | Close fd, clean abort. |

---

## Testing Strategy

Raw disk writing is destructive, so safe test paths matter.

- **WriteEngine unit tests (TDD):** abstract the output target behind a `BlockWriter`
  protocol so tests write to a **temp file** instead of `/dev/rdiskN`. Verify chunking,
  progress accounting, hash verification, and cancellation.
- **Safe integration tests:** use `hdiutil` to attach a blank disk image, producing a
  real `/dev/diskN` node **without a physical USB**. Exercise the helper end-to-end
  (unmount → raw write → verify) with no risk to real disks. This is the core
  automation tool.
- **DiskDiscovery:** unit-test the IOKit-to-model mapping logic with fake inputs;
  verify real enumeration manually.
- **XPCProtocol:** test request/progress serialization and the app-side state machine
  against a mock helper.
- **Final manual checklist:** write a small Linux ISO to a real USB stick and confirm
  it boots, once.

---

## Constraints

- Raw disk access is forbidden in the macOS sandbox → distribution is a **notarized DMG
  (direct), not the Mac App Store**.
- Privileges handled via Authorization Services / `SMAppService`-installed helper.
- Target: macOS 13+ (Ventura), universal binary (arm64 + x86_64).
