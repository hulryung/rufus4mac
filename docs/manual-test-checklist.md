# Phase 1 Manual Test Checklist

These steps require a real, **expendable** USB stick and a signed build of the app —
they cannot be automated and are destructive. Run them on real hardware before
considering Phase 1 shippable.

**Prereqs**
- An expendable USB stick (its contents WILL be erased).
- A small Linux ISO (e.g. Alpine `*-standard-*.iso`) or any `.img`.
- A Developer ID–signed, notarized build (see `scripts/build-dmg.sh`), OR a locally
  signed build with the helper registered (SMAppService needs a valid signature).

## Happy path
1. [ ] Launch rufus4mac. Insert the USB stick. It appears in the **Target disk** picker.
2. [ ] Internal/system disks do **NOT** appear in the picker (only removable/ejectable).
3. [ ] Click **Choose…**, select the ISO. The filename shows; **Write** stays disabled
       until the SHA-256 finishes computing (hashing gate).
4. [ ] Oversize guard: pick a disk smaller than the image → the orange
       "Image is larger than the selected disk." warning shows and **Write** is disabled.
5. [ ] Click **Write** → the confirm dialog names the **correct disk + size** → **Erase and Write**.
6. [ ] First run only: macOS prompts to approve the helper. Approve it in
       **System Settings → General → Login Items & Extensions** (the app opens this for you),
       then click Write again.
7. [ ] Progress shows **Writing…** then **Verifying…**, advancing to 100%.
8. [ ] Result shows **Done ✅**.
9. [ ] Boot a target machine from the USB and confirm it boots.

## Safety / failure paths
10. [ ] Try to select the internal disk as a target — it must be impossible (not listed).
        The helper also fails closed (`targetNotRemovable`) if asked to write a non-removable disk.
11. [ ] Yank the USB mid-write → the app reports a clear error (no silent hang, no crash).
12. [ ] Feed a corrupted/truncated image or a tampered device → verification fails with
        a "verification mismatch" error rather than a false success.

## Notes
- The privileged write runs in the `RufusHelper` LaunchDaemon (root), reached over XPC.
- The helper only accepts XPC connections signed by the HUCONN team
  (`certificate leaf[subject.OU] = "XGJ87M8ZZR"`).
