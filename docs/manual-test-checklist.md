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
