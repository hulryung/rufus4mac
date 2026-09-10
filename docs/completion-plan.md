# Product completion audit — 0.5.0

- Four-language UI: system language resolution, saved override, complete translation/placeholder tests, and live switching verified. Korean/Japanese/Spanish settings inspected at minimum width; English text verified live.
- Three task workflows: format, Windows/raw bootable media, and standalone-driver preflight inspected in the installed app. Driver checksums and persistent settings already existed and were retained.
- Failure handling: owned read-only disk image produces a readable failure; report export preserves its original diagnostic text.
- Target safety: detach/reattach under the same BSD name during review is rejected before a writer starts.
- Reports: successful format and failed format exported through the native save panel; JSON evidence is in `docs/qa/`.
- Regression: all 221 tests passed. No source changes after the verified build.
- Distribution: 0.5.0 Developer ID app and DMG accepted by Gatekeeper; Apple notarization accepted and stapled. Installed app version and single main window verified.
- Documentation: README, screenshots, translation extension guide and release notes updated.
- Publication: `v0.5.0` is public and latest; DMG and SHA-256 file uploaded. GitHub asset digest matches the notarized local DMG: `273d2ba6889707b3c1d010c5cd6766583bc9128322f026534cecc8e3a9b5bda9`. Release tag points to `6b959c4`; application sources match the validated build.

Full Windows installation is a separate hardware check, not claimed here. The user confirmed boot, USB connection and automatic ejection. Named presets and automatic update checks remain optional future features; this release has no placeholder controls for them.
