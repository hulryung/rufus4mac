# Phase 1 Manual Test Checklist

These steps require a real, **expendable** USB stick and are destructive — they can't be
automated. The privileged write uses Apple's `authopen` (no daemon, no Full Disk Access),
so the only prompt you should see is a standard authorization (password) dialog.

**Prereqs**
- An expendable USB stick (its contents WILL be erased).
- A small Linux ISO (e.g. Alpine `*-standard-*.iso`) or any `.img`.
- A build of RufusApp (run from Xcode, or a signed/notarized build from `scripts/build-dmg.sh`).

## Happy path
1. [ ] Launch rufus4mac. Insert the USB stick. It appears in the **Target disk** picker.
2. [ ] Internal/system disks do **NOT** appear (only removable/ejectable).
3. [ ] Click **Choose…**, select the ISO. **Write** stays disabled until the SHA-256 finishes
       (a small spinner shows next to the filename while hashing).
4. [ ] Oversize guard: pick a disk smaller than the image → the orange
       "Image is larger than the selected disk." warning shows and **Write** is disabled.
5. [ ] Click **Write** → the confirm dialog names the **correct disk + size** → **Erase and Write**.
6. [ ] macOS shows an authorization (password) prompt; enter it. (No System Settings trip.)
7. [ ] Status shows **Preparing… → Writing… → Verifying…**, the bar advancing to 100%.
8. [ ] Result shows **Done** with a green check.
9. [ ] Boot a target machine from the USB and confirm it boots.

## Safety / failure paths
10. [ ] The internal/boot disk is never listed as a target (DiskDiscovery excludes it).
11. [ ] Cancel the authorization prompt → the app reports a clear error, no hang/crash.
12. [ ] Yank the USB mid-write → the app reports an error rather than succeeding silently.
13. [ ] Feed a truncated/tampered image or device → verification fails ("data mismatch")
        rather than reporting success.

## Notes
- The image is read by the **app** (which holds access to the user-picked file) and streamed
  into `authopen -w /dev/rdiskN`; the device is read back through `authopen` for verification.
- `~/Downloads` and other TCC-protected locations work because the app — not a detached
  helper — opens the source file.

---

## Phase 2 — Windows install USB (manual)

Prereqs: a Windows 10/11 ISO, an expendable ≥ 8 GB USB, `wimlib` available (bundled in a release
build, or `brew install wimlib` for a dev run).

1. [ ] Select the Windows ISO → after hashing, the **"Windows install media"** section appears
       (auto-detected). The "Verify after writing" toggle is hidden for Windows.
2. [ ] Leave **"Bypass Windows 11 compatibility checks"** on for Win11-incompatible hardware.
3. [ ] Pick the USB → **Write** → confirm. Watch **Formatting → Copying → Splitting** (only if
       `install.wim` > 4 GB) → **(Bypassing)** → **Done**. (Formatting via `diskutil` needs no password.)
4. [ ] Inspect the USB: a FAT32 volume containing `efi/boot/bootx64.efi` and either
       `sources/install.wim` (≤ 4 GB) or `sources/install.swm` (+ `install2.swm`, … when split).
       With bypass on: `sources/appraiserres.dll` is 0 bytes and `autounattend.xml` exists at the root.
5. [ ] Boot a UEFI PC from it → Windows Setup starts. On Win11-incompatible hardware, Setup proceeds
       past the "This PC can't run Windows 11" check.

Failure paths:
6. [ ] A non-Windows ISO still shows the Phase 1 raw/DD flow (no Windows section).
7. [ ] An oversized non-`.wim` install image (e.g. a > 4 GB `install.esd`) fails fast with a clear
       "not supported" error rather than a cryptic FAT32 copy failure.

### Windows User Experience options (autounattend.xml)
- [ ] Enable **Create local account** + a username → after install, OOBE skips the Microsoft-account
      screen and the named local admin exists (blank password).
- [ ] Enable **Skip privacy questions** → OOBE privacy screens are skipped.
- [ ] Enable **Use this Mac's region & language** → installed Windows uses the matching locale
      (and time zone if the IANA zone is mapped).
- [ ] Enable **Disable BitLocker auto-encryption** → the system drive is not auto-encrypted.
- [ ] With all options off (and no bypass), **no** `autounattend.xml` is written to the USB.
- [ ] A username containing `&` produces a valid `autounattend.xml` (escaped), not a broken one.

---

## Phase 3 — Format-only (manual)

1. [ ] Launch with **no image** selected → the **Format options** section appears (partition scheme,
       file system, volume label) and the primary button reads **Format**. ("Verify after writing" is hidden.)
2. [ ] Pick a USB, choose **exFAT + GPT**, set a label → **Format** → confirm ("Erase and Format") →
       status reaches **Done** (no password prompt for removable media).
3. [ ] Verify in Disk Utility / `diskutil list`: GPT scheme, an exFAT volume with the label.
4. [ ] Repeat with **FAT32 + MBR**; confirm `FDisk_partition_scheme` + a FAT volume with the label.
5. [ ] Selecting an image hides the Format options and restores the Write flow.
6. [ ] A label with spaces/symbols/lowercase is normalized (uppercased, filtered, length-capped);
       an empty label becomes `RUFUS4MAC`.
