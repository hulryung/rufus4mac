# rufus4mac 0.5.0

This update makes the existing bootable USB, format and driver workflows easier to review and diagnose.

- English, Korean, Japanese and Spanish interfaces, selected from macOS preferences by default.
- A language settings sheet with immediate switching and a remembered per-app override.
- A scrollable review of the target, image, format, Windows options and selected driver models before starting.
- USB attachment revalidation before launching an erase/write operation, including BSD-name reuse detection.
- A last-task JSON report containing the original configuration, outcome and diagnostic details.
- Recovery guidance for failed tasks, alongside the original technical error.

Language changes affect the app interface only. Windows installation language and regional settings
remain separate. Driver catalog descriptions and external-tool diagnostics retain their original text.

Reports are saved only at the user's request and are not uploaded. They can contain filenames and
paths from diagnostic output. Review a report before sharing it.

Validation: 221 automated tests passed; macOS debug and release builds passed. Signed/notarized installation, live format review, successful formatting, stale-device rejection,
read-only failure handling and report export were verified using an owned temporary disk image.
Windows, raw-image and standalone-driver preflight variants were also inspected without starting writes.
Hardware boot was reported by the user; a complete Windows installation remains a separate hardware check.
