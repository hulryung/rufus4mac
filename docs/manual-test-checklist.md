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

## UI workflow refresh

- [x] Build the macOS app after the UI changes (unsigned debug build).
- [x] Run the non-integration regression suite: 190 tests passed.
- [x] Inspect the initial screen and switch to Format USB in the running app; no disk operation started.
- [ ] Choose a Windows ISO and expand setup preferences, Advanced, and driver options; confirm the footer stays visible while scrolling.
- [ ] Choose a general image, compute checksums, and copy each full hash.
- [ ] While checking an image or writing, confirm mode, source, target, and options cannot be changed.
- [ ] Enable a Windows local account with an empty name; confirm the action is disabled with an explanation.
- [ ] Select an oversized or unreadable image and confirm the recovery guidance.
- [ ] Change the format name and filesystem; confirm the normalized name matches the erase confirmation.
- [ ] Complete each write path on a disposable USB; inspect progress, error details, and the final ejection guidance.

## Driver task and catalog UI

- [x] Build the app with the single-window scene; one RufusApp process and one main window after relaunch.
- [x] Run the non-integration suite: 197 tests pass, including preservation, conflicts, symlink rejection, missing selections/destinations, and duplicate catalog model validation.
- [x] Inspect Add drivers with the existing library and no target selected: copying is disabled.
- [x] Open the catalog picker and search NT950: one model and its packages are shown.
- [x] Search for a nonexistent model: empty-state guidance appears and Add to library is disabled.
- [ ] Test a USB disconnect during copying and eject/reconnect after successful driver addition.
- [ ] Create a disposable Windows installer with Include drivers enabled and confirm its selected model folders.

## 0.4.0 release verification (2026-09-10)

- [x] Full `swift test`: 211 tests passed, including synthetic-disk integration tests.
- [x] Release build targets arm64; the bundled wimlib architecture matches.
- [x] Developer ID signatures verified inside-out.
- [x] Apple notarization accepted (`07d3604d-9e03-4a4c-aaf2-52a56f102d65`); DMG ticket stapled and validated.
- [x] Gatekeeper accepts both the DMG and the installed app as Notarized Developer ID.
- [x] The old Applications copy was replaced with 0.4.0; the installed app launches the new single-window UI.
- [x] README screenshots captured from the signed 0.4.0 build: initial setup, add drivers, catalog, format.
- [ ] End-to-end boot and Windows installation on a destination PC; no hardware boot claim is made for this release.

## User-reported hardware validation (2026-09-10)

- [x] User confirmed that the USB boots successfully.
- [x] User confirmed USB connection and automatic ejection behavior.
- [ ] Completing a full Windows installation was not separately reported.

## Multilingual interface

- [x] Full test suite: 218 tests passed, including language fallback and interpolation checks.
- [ ] Inspect Korean, English, Japanese and Spanish screens at minimum window width.
- [ ] Change language without losing selected task or settings; relaunch to check persistence.

- [x] Final app build and all 7 localization tests pass.
- UI verification remains incomplete: macOS reports no accessible window for the running app despite granted permissions. The installed 0.4.0 app was not replaced in this verification pass.

## Completion pass (2026-09-11)

- [x] Full regression suite: 221 tests passed, including report outcomes and reused BSD attachment identity.
- [x] Debug app build passed after preflight, reporting and target revalidation changes.
- [x] Korean, Japanese and Spanish settings screenshots inspected at 620-point main-window width.
- [x] English/Korean/Japanese/Spanish switching changes the live main view and settings text.
- [x] Saved Korean preference restored on launch.
- [ ] Preflight interaction and report export in the app: coordinate input was refused because macOS reported no focused window. Semantic settings actions worked.
- [ ] Signed build, installation and public release of the completion update.

- [x] 0.5.0 signed/notarized DMG accepted: `e62f9ebc-27d7-40bb-b83b-a68624e1ef4a`; ticket stapled and validated.
- [x] Installed 0.5.0 in Applications; Gatekeeper accepts the installed app.
- [x] Only the installed RufusApp process remains; Korean setting restored and version 0.5.0 shown.
- [x] Captured installed Korean UI and language-settings screenshots.

## Installed 0.5.0 interaction verification

- [x] Format review shows selected device, capacity, scheme, filesystem and normalized label; Cancel returns without running a task.
- [x] Created an owned 64 MiB temporary image at `/tmp/rufus-0.5.0-qa.dmg`; formatted it through the installed app. `diskutil` confirmed GPT, exFAT and RUFUS4MAC.
- [x] Saved the success report through NSSavePanel; checked actual JSON against the disk and task settings (`docs/qa/format-success-0.5.0.json`).
- [x] With review open, detached and reattached the temporary image under the same BSD name. Starting was rejected, selection cleared, and localized recovery alert appeared.
- [x] Attempted formatting the owned image attached read-only; operation failed with the expected writable-disk error and readable recovery guidance.
- [x] Exported the failure report and verified `succeeded: false` and original error (`docs/qa/format-failure-0.5.0.json`).
- [x] Detached the temporary image afterward. Existing physical USBs and other disk images were not written.
- [ ] Inspect bootable-media and standalone-driver review variants before public release.

## Final 0.5.0 review

- [x] Inspected Windows preflight with local-account name and on/off states, using a clearly named synthetic fixture; no write was started.
- [x] Inspected raw-image preflight with post-write verification enabled; no write was started.
- [x] Inspected standalone driver preflight: destination path, model name, size and existing-file preservation guidance; cancelled without copying.
- [x] Restarted the installed app after verification to clear temporary image and target selections; removed the owned QA mount.
- [x] README now describes 0.5.0 and links the new screenshots and translation guide.

Historical unchecked entries above describe earlier passes or optional hardware checks, not failed automated tests. Full Windows installation on a target PC has not been independently verified; hardware boot was reported by the user.

- [x] Public `v0.5.0` release and both assets verified; GitHub DMG SHA-256 matches the local notarized artifact.
- [x] Final installed process and UI show 0.5.0, Korean, no image selected and no disk selected.


## 0.6.0 workflow tools verification (2026-09-11)

- [x] Full `swift test`: 231 tests passed. Loopback HTTP integration tests verify byte progress, active cancellation, two transient retries and no retry for HTTP 404.
- [x] Cancellation during driver copying removes staging files and preserves existing USB contents.
- [x] Preset and history JSON round trips, corrupt-file preservation, unfinished/failure outcomes and numeric release comparison are covered by tests.
- [x] Installed app shows 0.6.0 with one main window. Developer ID signature and Gatekeeper checks pass.
- [x] Final DMG notarization accepted: `45b4baf0-ccb6-4ab7-9827-1e12c19ca074`; ticket stapled and validated.
- [x] An owned 64 MiB test image appeared automatically after attachment. Detaching the selected image automatically cleared the selection and disabled starting. Physical USB disks were not written or ejected.
- [x] Saved QA preset, relaunched, applied it, and deleted only that fixture through the UI.
- [x] Formatted the owned image attached read-only to exercise immediate failure. The final failure was saved to history despite finishing in the same second. Relaunched and inspected that history in Tools. See `docs/qa/history-failure-0.6.0.json`.
- [x] Cleared only the QA history through the confirmation UI; detached the owned image.
- [x] Live GitHub update check returned the expected up-to-date result.
- [x] Captured and visually inspected English main, Tools and history screens; README uses English images.
- [ ] Repeat raw writing / Windows creation cancellation on disposable physical USB hardware, especially while authentication, formatting or WIM splitting is in progress. These waits intentionally finish their current step.
- [ ] End-to-end Windows installation with the new build has not been repeated.
