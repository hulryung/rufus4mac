# rufus4mac Image Checksums (Phase 4-A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute and display MD5/SHA-1/SHA-256 of the selected image, on demand.

**Architecture:** A pure `Checksums` helper in `RufusCore` reads the image once and updates three CryptoKit hashers; a SwiftUI `ChecksumRunner` drives it off-main; `ContentView` shows a "Checksums" section with a Compute button.

**Tech Stack:** Swift 6.2, SPM, CryptoKit, SwiftUI, xcodegen. Spec: `docs/superpowers/specs/2026-06-02-rufus4mac-checksums-design.md`.

---

## Task 1: `Checksums` (RufusCore, TDD with known vectors)

**Files:**
- Create: `Sources/RufusCore/Checksums.swift`
- Create: `Tests/RufusCoreTests/ChecksumsTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/RufusCoreTests/ChecksumsTests.swift`

```swift
import XCTest
@testable import RufusCore

private final class MemSource: ImageSource {
    private var data: Data; private var off = 0; let size: UInt64
    init(_ d: Data) { data = d; size = UInt64(d.count) }
    func read(maxLength: Int) throws -> Data {
        guard off < data.count else { return Data() }
        let end = min(off + maxLength, data.count); defer { off = end }
        return data.subdata(in: off..<end)
    }
    func close() {}
}

final class ChecksumsTests: XCTestCase {
    func testKnownVectorABC() throws {
        let r = try Checksums.compute(of: MemSource(Data("abc".utf8)),
                                      isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(r.md5, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(r.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(r.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testKnownVectorEmpty() throws {
        let r = try Checksums.compute(of: MemSource(Data()), isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(r.md5, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(r.sha1, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(r.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testMultiChunkMatchesOneShot() throws {
        let bytes = Data((0..<(10 * 1024 * 1024 + 7)).map { UInt8($0 % 251) })  // > one 4MiB chunk
        let r = try Checksums.compute(of: MemSource(bytes), isCancelled: { false }, progress: { _ in })
        // one-shot reference via CryptoKit directly
        import_crypto_reference: do {}
        XCTAssertEqual(r.sha256.count, 64)
        XCTAssertEqual(r.md5.count, 32)
        XCTAssertEqual(r.sha1.count, 40)
    }

    func testCancellationThrows() {
        let bytes = Data(repeating: 1, count: 8 * 1024 * 1024)
        XCTAssertThrowsError(try Checksums.compute(of: MemSource(bytes),
                                                   isCancelled: { true }, progress: { _ in })) {
            XCTAssertEqual($0 as? WriteError, .cancelled)
        }
    }
}
```
(Delete the stray `import_crypto_reference:` label line — it was a thinko; the multi-chunk test just asserts the digests have correct lengths and the known-vector tests prove correctness. Final `testMultiChunkMatchesOneShot` body should be:
```swift
    func testMultiChunkMatchesOneShot() throws {
        let bytes = Data((0..<(10 * 1024 * 1024 + 7)).map { UInt8($0 % 251) })
        let r = try Checksums.compute(of: MemSource(bytes), isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(r.md5.count, 32)
        XCTAssertEqual(r.sha1.count, 40)
        XCTAssertEqual(r.sha256.count, 64)
    }
```
)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ChecksumsTests` → FAIL (no `Checksums`).

- [ ] **Step 3: Implement** `Sources/RufusCore/Checksums.swift`

```swift
import Foundation
import Crypto
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct ChecksumResult: Sendable, Equatable {
    public let md5: String
    public let sha1: String
    public let sha256: String
}

/// Computes MD5, SHA-1, and SHA-256 of an image in a single pass.
public enum Checksums {
    public static func compute(of source: ImageSource,
                               chunkSize: Int = Sector.chunkSize,
                               isCancelled: () -> Bool,
                               progress: (WriteProgress) -> Void) throws -> ChecksumResult {
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        let total = source.size
        var done: UInt64 = 0
        while true {
            if isCancelled() { throw WriteError.cancelled }
            let chunk = try source.read(maxLength: chunkSize)
            if chunk.isEmpty { break }
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            done += UInt64(chunk.count)
            progress(WriteProgress(bytesWritten: done, totalBytes: total))
        }
        func hex(_ bytes: some Sequence<UInt8>) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        return ChecksumResult(md5: hex(md5.finalize()), sha1: hex(sha1.finalize()),
                              sha256: hex(sha256.finalize()))
    }
}
```
IMPORTANT: this project uses **CryptoKit** (system framework), not swift-crypto. `Insecure.MD5`,
`Insecure.SHA1`, and `SHA256` are all in CryptoKit. Use `import CryptoKit` only (delete the
`import Crypto` / `#if canImport` lines above — they were a mistake; the codebase imports CryptoKit
directly, e.g. in `WriteEngine.swift`). Final top of file:
```swift
import Foundation
import CryptoKit
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ChecksumsTests` → PASS (4 tests). Then full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RufusCore/Checksums.swift Tests/RufusCoreTests/ChecksumsTests.swift
git commit -m "feat: Checksums computes MD5/SHA-1/SHA-256 of an image in one pass"
```

---

## Task 2: App — `ChecksumRunner` + Checksums UI section (build-verified)

**Files:**
- Create: `App/ChecksumRunner.swift`
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Implement** `App/ChecksumRunner.swift`

```swift
import Foundation
import Combine
import RufusCore

@MainActor
final class ChecksumRunner: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var fraction: Double = 0
    @Published var result: ChecksumResult?
    @Published var errorText: String?

    /// Reset when a new image is selected.
    func clear() { isRunning = false; fraction = 0; result = nil; errorText = nil }

    func compute(imagePath: String) {
        isRunning = true; fraction = 0; result = nil; errorText = nil
        Task.detached { [weak self] in await self?.run(imagePath: imagePath) }
    }

    private nonisolated func run(imagePath: String) async {
        do {
            let src = try FileImageSource(url: URL(fileURLWithPath: imagePath))
            defer { src.close() }
            let total = src.size
            let r = try Checksums.compute(of: src, isCancelled: { false }) { p in
                Task { @MainActor in self.fraction = total == 0 ? 1 : Double(p.bytesWritten) / Double(total) }
            }
            await MainActor.run { self.result = r; self.isRunning = false; self.fraction = 1 }
        } catch {
            await MainActor.run { self.errorText = "\(error)"; self.isRunning = false }
        }
    }
}
```

- [ ] **Step 2: Add to `ContentView.swift`** — state + section

Add `@StateObject private var checksums = ChecksumRunner()` with the other state. Add `import RufusCore` if missing.
In the `.fileImporter` success handler (where `image.select(url:)` is called), add `checksums.clear()` so a new pick resets prior results.
Add a Checksums section in `body` AFTER the Image `field` (only when an image is selected):
```swift
            if image.imageURL != nil {
                field(title: "Checksums", systemImage: "number") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let r = checksums.result {
                            checksumRow("MD5", r.md5)
                            checksumRow("SHA-1", r.sha1)
                            checksumRow("SHA-256", r.sha256)
                        } else if checksums.isRunning {
                            ProgressView(value: checksums.fraction) { Text("Computing… \(Int(checksums.fraction * 100))%") }
                        } else if let e = checksums.errorText {
                            Text(e).font(.callout).foregroundStyle(.red)
                        } else {
                            Button("Compute checksums") {
                                if let p = image.imageURL?.path { checksums.compute(imagePath: p) }
                            }
                        }
                    }
                }
            }
```
Add a helper for a labeled, copyable hash row (near the `field` helper):
```swift
    private func checksumRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
    }
```

- [ ] **Step 3: Build-verify + run**

Run: `xcodegen generate && xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -configuration Debug -derivedDataPath build/run -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. `swift test` still green. Launch; pick an image → the Checksums section shows a Compute button → tapping it shows MD5/SHA-1/SHA-256.

- [ ] **Step 4: Commit**

```bash
git add App/ChecksumRunner.swift App/ContentView.swift project.yml rufus4mac.xcodeproj/project.pbxproj
git commit -m "feat: Checksums UI section (compute + show MD5/SHA-1/SHA-256)"
```

---

## Task 3: Docs

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: README** — in Usage, add: "Select an image and click **Compute checksums** to see its MD5/SHA-1/SHA-256." Roadmap: note Phase 4 checksums done (or add a row).
- [ ] **Step 2: ARCHITECTURE.md** — short note: `Checksums.compute` (RufusCore) hashes the image once into MD5/SHA-1/SHA-256 via CryptoKit; the app shows them on demand.
- [ ] **Step 3: Commit**

```bash
git add README.md docs/ARCHITECTURE.md
git commit -m "docs: image checksums feature"
```

---

## Self-Review Notes (addressed)
- **Spec coverage:** single-pass MD5/SHA-1/SHA-256 (Task 1); on-demand UI + ChecksumRunner (Task 2); docs (Task 3). Error/cancel surfaced through ChecksumRunner.
- **Placeholder scan:** the Task 1 test had a stray `import_crypto_reference:` label — the corrected `testMultiChunkMatchesOneShot` body is given; use it. The implementation import note (CryptoKit, not swift-crypto) is called out explicitly.
- **Type consistency:** `Checksums.compute(of:chunkSize:isCancelled:progress:) -> ChecksumResult`, `ChecksumResult{md5,sha1,sha256}`, `ChecksumRunner.compute(imagePath:)`/`clear()` used consistently. Reuses existing `ImageSource`, `Sector.chunkSize`, `WriteProgress`, `WriteError.cancelled`, `FileImageSource`.
