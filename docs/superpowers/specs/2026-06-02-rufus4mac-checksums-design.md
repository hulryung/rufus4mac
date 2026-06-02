# rufus4mac — Image Checksums (Phase 4-A)

**Date:** 2026-06-02
**Status:** Approved for planning
**Scope:** Compute and display MD5 / SHA-1 / SHA-256 of the selected image (Rufus-style).

---

## Context

Rufus shows MD5/SHA-1/SHA-256 of the selected image so users can verify a download against a
published hash. rufus4mac already computes SHA-256 internally (for the raw/DD write verification).
This feature surfaces all three checksums on demand. First, smallest slice of Phase 4.

## Scope

### In scope
- A `Checksums.compute(of:)` that reads the image **once** and returns MD5, SHA-1, and SHA-256 as
  lowercase hex strings.
- A "Checksums" section in the UI (shown when an image is selected) with a **Compute** button
  (on-demand, because hashing multi-GB files is slow) that displays the three hashes, monospaced
  and selectable (so users can copy/compare).
- Progress while computing; clear error if the file can't be read.

### Out of scope
- Auto-computing on selection (kept on-demand). CRC32, SHA-512, etc. Comparing against a
  user-pasted expected hash (could be a later nicety).

## Architecture

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `Checksums` (new, in `RufusCore`) | `static func compute(of: ImageSource, isCancelled:progress:) throws -> ChecksumResult` — single pass over the source updating three CryptoKit hashers; returns `ChecksumResult { md5, sha1, sha256 }` (lowercase hex). | RufusCore (CryptoKit) |
| `App/ChecksumRunner.swift` (new) | `@MainActor ObservableObject` driving `Checksums.compute` off-main; publishes `phase`/`fraction`/`result`/`errorText`/`isRunning`. | RufusCore |
| `App/ContentView.swift` (modified) | "Checksums" section shown when `image.imageURL != nil`: a Compute button + the three hashes (monospaced, `.textSelection(.enabled)`). | — |

```swift
public struct ChecksumResult: Sendable, Equatable {
    public let md5: String
    public let sha1: String
    public let sha256: String
}
```

- `compute` reads in `Sector.chunkSize` blocks via `ImageSource`, updating `Insecure.MD5`,
  `Insecure.SHA1`, and `SHA256` together; finalizes to lowercase hex. `progress` reports
  bytes/total; `isCancelled` is polled between chunks (throws `WriteError.cancelled`).
- The app opens a `FileImageSource` for the selected URL, runs `compute` on a detached task,
  and shows the result. (The app holds powerbox access to the picked file, so `~/Downloads` works.)

## Error handling
- File unreadable / open fails → surfaced via `ChecksumRunner.errorText`.
- Cancellation (e.g. new image picked) → stops cleanly.

## Testing
- `Checksums.compute`: known-vector unit tests — e.g. empty input and the ASCII string `"abc"`:
  - `abc` → MD5 `900150983cd24fb0d6963f7d28e17f72`, SHA-1 `a9993e364706816aba3e25717850c26c9cd0d89d`,
    SHA-256 `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
  - empty → MD5 `d41d8cd98f00b204e9800998ecf8427e`, SHA-1 `da39a3ee5e6b4b0d3255bfef95601890afd80709`,
    SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
  Use an in-memory `ImageSource` (or a temp file) feeding the bytes.
- Single-pass correctness: a multi-chunk input (larger than one chunk) yields the same hashes as a
  one-shot computation.
- App build-verify; existing tests stay green.

## Constraints
macOS 13+. Zero new dependencies (CryptoKit). Independent of the write/format paths.
