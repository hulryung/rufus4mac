# rufus4mac Phase 1 Implementation Plan (Raw/DD Image Writer)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS-native app that writes a disk image (`.iso`/`.img`/`.dmg`) byte-for-byte to a removable USB disk, with progress and post-write verification.

**Architecture:** Pure-logic core (image streaming, sector-aligned block writing, progress, hash verification) lives in a Swift Package (`RufusCore`, `DiskDiscovery`, `XPCProtocol`) that runs under `swift test`. An Xcode project consumes the package to build the unprivileged SwiftUI app plus a root LaunchDaemon helper; the app and helper communicate over XPC. The write path is developed and tested **risk-first**: a walking skeleton proves device I/O against an `hdiutil`-attached image (user-owned, no root) before any privileged-helper or signing work.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Package Manager + Xcode 26, DiskArbitration, IOKit, XPC (`NSXPCConnection`), `SMAppService` (macOS 13+). Verified environment: Apple Silicon, macOS 26.5, Developer ID Application cert present (HUCONN Co.,Ltd. / XGJ87M8ZZR).

**Key verified facts driving this plan:**
- `hdiutil attach -nomount` device nodes are owned by the invoking user → the full write/verify path is testable **without root**. Real USB device nodes are root-owned → only that path needs the helper.
- Raw device (`/dev/rdiskN`) writes **must be sector-aligned** (multiples of 512 bytes). The final partial sector of an image must be zero-padded when written to a device.
- Verification compares a hash of the **original image bytes only** (the first `imageSize` bytes read back), ignoring trailing device capacity and any zero padding.

---

## Implementation Status (updated 2026-06-01)

Phase 1 is **working on real hardware** (a Linux ISO written + verified to a USB stick on
macOS 26, Apple Silicon). Built on branch `phase1-implementation`, merged to `main`, repo public.

### Privilege model — pivoted to `authopen` (supersedes the SMAppService design)

The original plan used an `SMAppService` privileged LaunchDaemon + XPC. On macOS 26 that path
hit a hard wall: a background daemon (and an `osascript`-elevated root process) is denied raw
disk access with **EPERM — even for `open(O_RDONLY)`** — because non-TTY processes need a TCC
grant (Full Disk Access) for raw devices. Diagnosis (helper logged uid=0, disk unmounted,
`open` EPERM on every flag) confirmed it's TCC, not permissions. `sudo dd` from a TTY works only
because interactive TTY-root is TCC-exempt.

**Final design:** the app drives the write directly through Apple's **`/usr/libexec/authopen`**
(setuid-root, entitled `com.apple.private.tcc.check-allow-on-responsible-process` for
`RemovableVolumes`). The app is the responsible process and declares
`NSRemovableVolumesUsageDescription`, so the user gets an inline authorization prompt — **no
persistent daemon, no Full Disk Access.** Flow: app `diskutil unmountDisk` → stream the
(sector-padded) image into `authopen -w /dev/rdiskN` → read back via `authopen` and compare
SHA-256. The app reads the user-picked file itself (it holds powerbox access), so
TCC-protected sources like `~/Downloads` work.

The legacy SMAppService/XPC/daemon code (WriteClient, HelperInstaller, WriteService, the
RufusHelper target, XPCProtocol, the LaunchDaemon plist) has been **removed**; the codebase is
authopen-only. `App/ElevatedWriter.swift` implements the write.

### What shipped
- **SPM core (Tasks 1–11):** RufusCore (sector-aligned WriteEngine, device I/O, SHA-256 verify)
  + DiskDiscovery (removableDisks with boot-disk exclusion, unmountDisk). 23 tests, 0 warnings,
  end-to-end verified against `hdiutil` devices. Real bugs caught in review and fixed (mid-stream
  padding corruption, verify EINVAL on unaligned reads, unmount timeout use-after-free, fsync
  swallow).
- **App:** SwiftUI (`ContentView` + view-models + `ElevatedWriter`), refined UI (header, SF
  Symbols, accent, prominent Write button), app icon (`scripts/make-icon.swift`). Xcode project
  generated via **xcodegen** (`project.yml`), built with `xcodebuild`.
- **Packaging/docs:** `scripts/build-dmg.sh` (sign + notarize; not yet run), README, this plan,
  `docs/manual-test-checklist.md` — all describe the authopen architecture.

### Remaining (manual)
- Run `scripts/build-dmg.sh` for a notarized DMG (needs a `notarytool` credential profile).
- Optional: a "verify after writing" toggle to skip the read-back pass on slow USB.

Everything below (the original task-by-task plan) is retained as the historical record; note the
SMAppService/XPC tasks (12, 14, 16, 22) were superseded by the authopen design above.

### Deviations from the plan as written (what actually shipped)

These were decided/discovered during implementation and review. The RufusCore **public API
signatures are unchanged**, so downstream tasks (12–26) that consume them still apply as written.

- **CryptoKit, not swift-crypto.** Tasks 6/7/11 use the system framework `import CryptoKit`
  (identical `SHA256` API, zero external dependencies). `Package.swift` has **no** swift-crypto
  dependency. Ignore Task 6 Step 2's swift-crypto instructions.
- **WriteEngine.write accumulate-and-flush (Task 5 fix).** Padding is applied ONLY to the genuine
  final remainder; intermediate writes flush whole sectors via an internal buffer. This handles
  partial/short mid-stream `ImageSource.read` returns (the original "pad every chunk" code corrupted
  output on short reads). Covered by `testShortMidStreamReadsStayAligned`.
- **verify() sector-rounds the final read (Task 6/final-review fix).** Raw devices reject
  non-sector-aligned reads with EINVAL; verify now rounds the last read up to a sector and trims
  the hash input back to the image boundary. Covered by `testWriteVerifyNonSectorAlignedImage`.
- **DeviceBlockWriter hardening:** `finish()` throws on `fsync` failure and is idempotent (`closed`
  flag); `write(_:)` guards against empty data; both device I/O classes have `deinit { close(fd) }`.
- **DiskDiscovery.unmountDisk concurrency (Task 10):** uses a `final class UnmountBox` + top-level
  `@convention(c)` callback + `Unmanaged.passRetained`/`takeRetainedValue` (NOT the plan's
  struct+closure form) to satisfy Swift 6 strict concurrency and to avoid a timeout use-after-free.
- **Sendable:** `WriteEngine: Sendable`; the device/file I/O classes are `@unchecked Sendable`
  (single-task ownership) — ready for the XPC helper to own them.
- **Boot-disk safety test:** `DiskDiscoveryTests` asserts the whole disk backing `/` is never
  returned by `removableDisks()` (replaces the Task 1 placeholder). Internal-disk exclusion was
  also empirically verified on this machine (boot disk `disk3` correctly excluded).
- **Still pending (by design):** `WriteError.imageLargerThanTarget` is defined but the capacity
  pre-check lives in the orchestration layer — implement it in Task 14 (helper) and Task 21 (UI),
  as the plan already specifies.

---

## Milestones

1. **M1 — Walking skeleton (risk-first):** `RufusCore` write/verify path proven against a temp file AND an `hdiutil` device, unprivileged. Tasks 1–7.
2. **M2 — Disk discovery:** enumerate removable disks + unmount via DiskArbitration. Tasks 8–11.
3. **M3 — XPC contract + privileged helper:** root helper does unmount→write→verify for real USB, installed manually via `launchctl` in dev. Tasks 12–16.
4. **M4 — SwiftUI app:** device list, image picker, confirm, progress, results. Tasks 17–22.
5. **M5 — SMAppService self-install + packaging:** signed helper registration, notarized DMG. Tasks 23–26.

Each milestone ends with working, runnable software.

---

## File Structure

```
rufus4mac/
├── Package.swift                         # SPM: 3 library targets + tests
├── Sources/
│   ├── RufusCore/
│   │   ├── Sector.swift                  # sector-size constants + alignment helpers
│   │   ├── WriteError.swift              # error enum
│   │   ├── ImageSource.swift             # protocol + FileImageSource
│   │   ├── BlockWriter.swift             # protocol + FileBlockWriter + DeviceBlockWriter
│   │   ├── BlockReader.swift             # protocol + DeviceBlockReader (for verify)
│   │   ├── WriteProgress.swift           # progress value type
│   │   └── WriteEngine.swift             # streaming write + verify orchestration
│   ├── DiskDiscovery/
│   │   ├── DiskInfo.swift                # value type: bsdName, model, size, removable
│   │   └── DiskDiscovery.swift           # DiskArbitration enumerate + unmount
│   └── XPCProtocol/
│       └── WriteServiceProtocol.swift    # @objc XPC protocol + Codable request/reply
├── Tests/
│   ├── RufusCoreTests/
│   │   ├── WriteEngineTests.swift
│   │   ├── ImageSourceTests.swift
│   │   └── DeviceIntegrationTests.swift  # hdiutil-backed, unprivileged
│   └── DiskDiscoveryTests/
│       └── DiskInfoMappingTests.swift
├── TestSupport/
│   └── HdiutilDevice.swift               # test helper: attach/detach a raw disk image
├── app/                                  # Xcode project (created in M4)
│   ├── rufus4mac.xcodeproj
│   ├── RufusApp/                         # SwiftUI app target
│   └── RufusHelper/                      # LaunchDaemon target
└── docs/superpowers/...
```

---

## Task 1: Initialize the Swift Package

**Files:**
- Create: `Package.swift`
- Create: `Sources/RufusCore/Sector.swift`
- Create: `Tests/RufusCoreTests/SectorTests.swift`

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rufus4mac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RufusCore", targets: ["RufusCore"]),
        .library(name: "DiskDiscovery", targets: ["DiskDiscovery"]),
        .library(name: "XPCProtocol", targets: ["XPCProtocol"]),
    ],
    targets: [
        .target(name: "RufusCore"),
        .target(name: "DiskDiscovery"),
        .target(name: "XPCProtocol"),
        .testTarget(name: "RufusCoreTests", dependencies: ["RufusCore"]),
        .testTarget(name: "DiskDiscoveryTests", dependencies: ["DiskDiscovery"]),
    ]
)
```

- [ ] **Step 2: Write the failing test** in `Tests/RufusCoreTests/SectorTests.swift`

```swift
import XCTest
@testable import RufusCore

final class SectorTests: XCTestCase {
    func testRoundUpToSector() {
        XCTAssertEqual(Sector.roundUp(0), 0)
        XCTAssertEqual(Sector.roundUp(1), 512)
        XCTAssertEqual(Sector.roundUp(512), 512)
        XCTAssertEqual(Sector.roundUp(513), 1024)
    }

    func testDefaultSizes() {
        XCTAssertEqual(Sector.size, 512)
        XCTAssertEqual(Sector.chunkSize % Sector.size, 0)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter SectorTests`
Expected: FAIL — `RufusCore` has no `Sector` type / does not compile.

- [ ] **Step 4: Write minimal implementation** in `Sources/RufusCore/Sector.swift`

```swift
import Foundation

/// Sector-size constants and alignment helpers for raw device writes.
/// Raw devices (`/dev/rdiskN`) require writes in whole-sector multiples.
public enum Sector {
    /// Logical sector size in bytes. 512 is the universal lowest common denominator.
    public static let size = 512

    /// Streaming chunk size: 4 MiB, a multiple of `size`.
    public static let chunkSize = 4 * 1024 * 1024

    /// Round `bytes` up to the next whole-sector boundary.
    public static func roundUp(_ bytes: Int) -> Int {
        let r = bytes % size
        return r == 0 ? bytes : bytes + (size - r)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter SectorTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/RufusCore/Sector.swift Tests/RufusCoreTests/SectorTests.swift
git commit -m "feat: scaffold SPM package with sector alignment helpers"
```

---

## Task 2: WriteError and WriteProgress types

**Files:**
- Create: `Sources/RufusCore/WriteError.swift`
- Create: `Sources/RufusCore/WriteProgress.swift`
- Create: `Tests/RufusCoreTests/WriteProgressTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/RufusCoreTests/WriteProgressTests.swift`

```swift
import XCTest
@testable import RufusCore

final class WriteProgressTests: XCTestCase {
    func testFraction() {
        let p = WriteProgress(bytesWritten: 50, totalBytes: 200)
        XCTAssertEqual(p.fraction, 0.25, accuracy: 0.0001)
    }

    func testFractionZeroTotalIsZero() {
        let p = WriteProgress(bytesWritten: 0, totalBytes: 0)
        XCTAssertEqual(p.fraction, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WriteProgressTests`
Expected: FAIL — no `WriteProgress` type.

- [ ] **Step 3: Write implementation**

`Sources/RufusCore/WriteProgress.swift`:

```swift
import Foundation

/// Snapshot of write progress, suitable to send over XPC.
public struct WriteProgress: Sendable, Codable, Equatable {
    public let bytesWritten: UInt64
    public let totalBytes: UInt64

    public init(bytesWritten: UInt64, totalBytes: UInt64) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes == 0 ? 0 : Double(bytesWritten) / Double(totalBytes)
    }
}
```

`Sources/RufusCore/WriteError.swift`:

```swift
import Foundation

public enum WriteError: Error, Equatable {
    case imageLargerThanTarget(imageSize: UInt64, targetSize: UInt64)
    case deviceOpenFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case shortWrite(expected: Int, actual: Int)
    case verificationMismatch
    case cancelled
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WriteProgressTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RufusCore/WriteError.swift Sources/RufusCore/WriteProgress.swift Tests/RufusCoreTests/WriteProgressTests.swift
git commit -m "feat: add WriteError and WriteProgress types"
```

---

## Task 3: ImageSource protocol and FileImageSource

**Files:**
- Create: `Sources/RufusCore/ImageSource.swift`
- Create: `Tests/RufusCoreTests/ImageSourceTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/RufusCoreTests/ImageSourceTests.swift`

```swift
import XCTest
@testable import RufusCore

final class ImageSourceTests: XCTestCase {
    private func makeTempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("img-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    func testSizeReportsByteCount() throws {
        let url = try makeTempFile(Array(repeating: 0xAB, count: 1000))
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try FileImageSource(url: url)
        defer { src.close() }
        XCTAssertEqual(src.size, 1000)
    }

    func testReadReturnsChunksThenEmptyAtEOF() throws {
        let url = try makeTempFile(Array(0..<10).map { UInt8($0) })
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try FileImageSource(url: url)
        defer { src.close() }

        let first = try src.read(maxLength: 4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try src.read(maxLength: 100)
        XCTAssertEqual(Array(second), [4, 5, 6, 7, 8, 9])
        let third = try src.read(maxLength: 100)
        XCTAssertTrue(third.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ImageSourceTests`
Expected: FAIL — no `FileImageSource`.

- [ ] **Step 3: Write implementation** in `Sources/RufusCore/ImageSource.swift`

```swift
import Foundation

/// A readable source of image bytes, read sequentially in chunks.
public protocol ImageSource: AnyObject {
    /// Total number of bytes in the image.
    var size: UInt64 { get }
    /// Read up to `maxLength` bytes from the current position.
    /// Returns an empty `Data` at end of file.
    func read(maxLength: Int) throws -> Data
    func close()
}

/// An `ImageSource` backed by a regular file.
public final class FileImageSource: ImageSource {
    private let handle: FileHandle
    public let size: UInt64

    public init(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        self.handle = try FileHandle(forReadingFrom: url)
    }

    public func read(maxLength: Int) throws -> Data {
        try handle.read(upToCount: maxLength) ?? Data()
    }

    public func close() {
        try? handle.close()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ImageSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RufusCore/ImageSource.swift Tests/RufusCoreTests/ImageSourceTests.swift
git commit -m "feat: add ImageSource protocol and FileImageSource"
```

---

## Task 4: BlockWriter protocol and FileBlockWriter

**Files:**
- Create: `Sources/RufusCore/BlockWriter.swift`
- Create: `Tests/RufusCoreTests/BlockWriterTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/RufusCoreTests/BlockWriterTests.swift`

```swift
import XCTest
@testable import RufusCore

final class BlockWriterTests: XCTestCase {
    func testFileBlockWriterWritesAllBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try FileBlockWriter(url: url)
        try writer.write(Data([1, 2, 3]))
        try writer.write(Data([4, 5]))
        try writer.finish()

        let written = try Data(contentsOf: url)
        XCTAssertEqual(Array(written), [1, 2, 3, 4, 5])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BlockWriterTests`
Expected: FAIL — no `FileBlockWriter`.

- [ ] **Step 3: Write implementation** in `Sources/RufusCore/BlockWriter.swift`

```swift
import Foundation

/// A destination that accepts sequential writes of (caller-aligned) buffers.
public protocol BlockWriter: AnyObject {
    /// Write the entire buffer. Throws `WriteError.shortWrite` on a partial write.
    func write(_ data: Data) throws
    /// Flush and release the underlying resource.
    func finish() throws
}

/// A `BlockWriter` backed by a regular file (used in unit tests and for
/// developing the streaming logic without a device).
public final class FileBlockWriter: BlockWriter {
    private let handle: FileHandle

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    public func finish() throws {
        try handle.synchronize()
        try handle.close()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BlockWriterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RufusCore/BlockWriter.swift Tests/RufusCoreTests/BlockWriterTests.swift
git commit -m "feat: add BlockWriter protocol and FileBlockWriter"
```

---

## Task 5: WriteEngine — sector-aligned streaming write with progress

**Files:**
- Create: `Sources/RufusCore/WriteEngine.swift`
- Create: `Tests/RufusCoreTests/WriteEngineTests.swift`

This is the core of Phase 1. The engine streams from an `ImageSource` to a `BlockWriter`, padding the final partial sector with zeros (required for raw devices), reporting progress, and honoring cancellation.

- [ ] **Step 1: Write the failing tests** in `Tests/RufusCoreTests/WriteEngineTests.swift`

```swift
import XCTest
@testable import RufusCore

/// In-memory ImageSource for deterministic tests.
private final class MemoryImageSource: ImageSource {
    private var data: Data
    private var offset = 0
    let size: UInt64
    init(_ data: Data) { self.data = data; self.size = UInt64(data.count) }
    func read(maxLength: Int) throws -> Data {
        guard offset < data.count else { return Data() }
        let end = min(offset + maxLength, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
    func close() {}
}

/// In-memory BlockWriter that records everything written.
private final class MemoryBlockWriter: BlockWriter {
    private(set) var written = Data()
    var failOnWrite = false
    func write(_ data: Data) throws {
        if failOnWrite { throw WriteError.writeFailed(errno: 5) }
        written.append(data)
    }
    func finish() throws {}
}

final class WriteEngineTests: XCTestCase {
    func testWritesExactBytesWhenSectorAligned() throws {
        let src = MemoryImageSource(Data(repeating: 0x42, count: 1024)) // 2 sectors
        let dst = MemoryBlockWriter()
        let engine = WriteEngine()
        try engine.write(source: src, to: dst, isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(dst.written.count, 1024)
        XCTAssertEqual(dst.written, Data(repeating: 0x42, count: 1024))
    }

    func testPadsFinalPartialSectorWithZeros() throws {
        // 600 bytes -> rounds up to 1024 (2 sectors); tail padded with zeros.
        let src = MemoryImageSource(Data(repeating: 0x55, count: 600))
        let dst = MemoryBlockWriter()
        let engine = WriteEngine()
        try engine.write(source: src, to: dst, isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(dst.written.count, 1024)
        XCTAssertEqual(Array(dst.written[0..<600]), Array(repeating: 0x55, count: 600))
        XCTAssertEqual(Array(dst.written[600..<1024]), Array(repeating: 0x00, count: 424))
    }

    func testProgressReachesTotal() throws {
        let src = MemoryImageSource(Data(repeating: 1, count: 300))
        let dst = MemoryBlockWriter()
        var last: WriteProgress?
        let engine = WriteEngine()
        try engine.write(source: src, to: dst, isCancelled: { false }, progress: { last = $0 })
        XCTAssertEqual(last?.bytesWritten, 300)
        XCTAssertEqual(last?.totalBytes, 300)
    }

    func testCancellationThrows() {
        let src = MemoryImageSource(Data(repeating: 1, count: 10_000_000))
        let dst = MemoryBlockWriter()
        let engine = WriteEngine()
        XCTAssertThrowsError(
            try engine.write(source: src, to: dst, isCancelled: { true }, progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? WriteError, .cancelled)
        }
    }

    func testWriteFailurePropagates() {
        let src = MemoryImageSource(Data(repeating: 1, count: 1024))
        let dst = MemoryBlockWriter()
        dst.failOnWrite = true
        let engine = WriteEngine()
        XCTAssertThrowsError(
            try engine.write(source: src, to: dst, isCancelled: { false }, progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? WriteError, .writeFailed(errno: 5))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WriteEngineTests`
Expected: FAIL — no `WriteEngine`.

- [ ] **Step 3: Write implementation** in `Sources/RufusCore/WriteEngine.swift`

```swift
import Foundation

/// Streams an image to a block destination in sector-aligned chunks,
/// padding the final partial sector with zeros (required by raw devices),
/// reporting progress, and honoring cancellation.
public final class WriteEngine {
    private let chunkSize: Int
    private let sectorSize: Int

    public init(chunkSize: Int = Sector.chunkSize, sectorSize: Int = Sector.size) {
        precondition(chunkSize % sectorSize == 0, "chunkSize must be a multiple of sectorSize")
        self.chunkSize = chunkSize
        self.sectorSize = sectorSize
    }

    /// Write the entire `source` to `writer`.
    /// - `isCancelled`: polled between chunks; if true, throws `.cancelled`.
    /// - `progress`: called after each chunk with cumulative bytes written
    ///   (counted against the *image* size, not the padded size).
    public func write(
        source: ImageSource,
        to writer: BlockWriter,
        isCancelled: () -> Bool,
        progress: (WriteProgress) -> Void
    ) throws {
        let total = source.size
        var imageBytesWritten: UInt64 = 0

        while true {
            if isCancelled() { throw WriteError.cancelled }

            let chunk = try source.read(maxLength: chunkSize)
            if chunk.isEmpty { break }

            let padded = padToSector(chunk)
            try writer.write(padded)

            imageBytesWritten += UInt64(chunk.count)
            progress(WriteProgress(bytesWritten: imageBytesWritten, totalBytes: total))
        }

        try writer.finish()
    }

    /// Pad `data` up to the next sector boundary with zeros. No-op if aligned.
    private func padToSector(_ data: Data) -> Data {
        let target = Sector.roundUp(data.count)
        guard target != data.count else { return data }
        var out = data
        out.append(Data(count: target - data.count))
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WriteEngineTests`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/RufusCore/WriteEngine.swift Tests/RufusCoreTests/WriteEngineTests.swift
git commit -m "feat: add WriteEngine with sector-aligned streaming, padding, progress, cancellation"
```

---

## Task 6: DeviceBlockWriter, DeviceBlockReader, and verification

**Files:**
- Modify: `Sources/RufusCore/BlockWriter.swift` (add `DeviceBlockWriter`)
- Create: `Sources/RufusCore/BlockReader.swift`
- Modify: `Sources/RufusCore/WriteEngine.swift` (add `verify`)
- Create: `Tests/RufusCoreTests/VerifyTests.swift`

`DeviceBlockWriter`/`DeviceBlockReader` wrap a POSIX file descriptor (`/dev/rdiskN`). Verification reads back the first `imageSize` bytes and compares a SHA-256 hash to the source's.

- [ ] **Step 1: Write the failing test** in `Tests/RufusCoreTests/VerifyTests.swift`

```swift
import XCTest
import Crypto
@testable import RufusCore

final class VerifyTests: XCTestCase {
    func testVerifySucceedsWhenBytesMatch() throws {
        let bytes = Data((0..<2000).map { UInt8($0 % 256) })
        let reader = MemoryBlockReader(bytes)
        let expected = SHA256.hash(data: bytes)
        let engine = WriteEngine()
        XCTAssertNoThrow(
            try engine.verify(reader: reader, imageSize: UInt64(bytes.count),
                              expectedHash: Data(expected), isCancelled: { false },
                              progress: { _ in })
        )
    }

    func testVerifyFailsOnMismatch() throws {
        let bytes = Data(repeating: 0xAA, count: 1024)
        let corrupted = Data(repeating: 0xBB, count: 1024)
        let reader = MemoryBlockReader(corrupted)
        let expected = SHA256.hash(data: bytes)
        let engine = WriteEngine()
        XCTAssertThrowsError(
            try engine.verify(reader: reader, imageSize: 1024,
                              expectedHash: Data(expected), isCancelled: { false },
                              progress: { _ in })
        ) { XCTAssertEqual($0 as? WriteError, .verificationMismatch) }
    }
}

/// Reads from an in-memory buffer; ignores reads past the buffer (returns empty).
private final class MemoryBlockReader: BlockReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    func read(maxLength: Int) throws -> Data {
        guard offset < data.count else { return Data() }
        let end = min(offset + maxLength, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
    func close() {}
}
```

- [ ] **Step 2: Add `swift-crypto` dependency** to `Package.swift` (provides `Crypto.SHA256`, avoids CryptoKit availability quirks under `swift test`)

In `Package.swift`, add to `dependencies:` at the package level and to `RufusCore`/test target deps:

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
```
and in the `RufusCore` target:
```swift
        .target(name: "RufusCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
```
and in the `RufusCoreTests` target dependencies add `.product(name: "Crypto", package: "swift-crypto")`.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter VerifyTests`
Expected: FAIL — no `BlockReader` / no `verify`.

- [ ] **Step 4: Write implementation**

`Sources/RufusCore/BlockReader.swift`:

```swift
import Foundation

/// A readable block source (used for read-back verification).
public protocol BlockReader: AnyObject {
    func read(maxLength: Int) throws -> Data
    func close()
}
```

Add to `Sources/RufusCore/BlockWriter.swift`:

```swift
/// A `BlockWriter` backed by a POSIX file descriptor opened on a device
/// (`/dev/rdiskN`). Writes must be sector-aligned by the caller (WriteEngine).
public final class DeviceBlockWriter: BlockWriter {
    private let fd: Int32

    /// Open the device for writing. `O_SYNC` ensures data hits the medium.
    public init(devicePath: String) throws {
        let fd = open(devicePath, O_WRONLY | O_SYNC)
        guard fd >= 0 else { throw WriteError.deviceOpenFailed(errno: errno) }
        self.fd = fd
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while written < data.count {
                let n = Foundation.write(fd, base + written, data.count - written)
                if n < 0 { throw WriteError.writeFailed(errno: errno) }
                if n == 0 { throw WriteError.shortWrite(expected: data.count, actual: written) }
                written += n
            }
        }
    }

    public func finish() throws {
        fsync(fd)
        close(fd)
    }
}
```

Add `DeviceBlockReader` to `Sources/RufusCore/BlockReader.swift`:

```swift
public final class DeviceBlockReader: BlockReader {
    private let fd: Int32

    public init(devicePath: String) throws {
        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else { throw WriteError.deviceOpenFailed(errno: errno) }
        self.fd = fd
    }

    public func read(maxLength: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: maxLength)
        let n = buf.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, maxLength) }
        if n < 0 { throw WriteError.readFailed(errno: errno) }
        return Data(buf.prefix(n))
    }

    public func close() { Foundation.close(fd) }
}
```

Add `verify` to `WriteEngine` (and `import Crypto` at top of `WriteEngine.swift`):

```swift
    /// Read back exactly `imageSize` bytes from `reader`, hash them (SHA-256),
    /// and compare against `expectedHash`. Throws `.verificationMismatch` on mismatch.
    public func verify(
        reader: BlockReader,
        imageSize: UInt64,
        expectedHash: Data,
        isCancelled: () -> Bool,
        progress: (WriteProgress) -> Void
    ) throws {
        var hasher = SHA256()
        var remaining = imageSize

        while remaining > 0 {
            if isCancelled() { throw WriteError.cancelled }
            let want = Int(min(UInt64(chunkSize), remaining))
            let chunk = try reader.read(maxLength: want)
            if chunk.isEmpty { break }
            // Only hash up to the image boundary (device reads are sector-rounded).
            let useful = chunk.prefix(Int(min(UInt64(chunk.count), remaining)))
            hasher.update(data: useful)
            remaining -= UInt64(useful.count)
            progress(WriteProgress(bytesWritten: imageSize - remaining, totalBytes: imageSize))
        }

        if Data(hasher.finalize()) != expectedHash { throw WriteError.verificationMismatch }
    }
```

Also add a SHA-256 helper used during writing in Task 7 (`computeHash(of:)`). Add to `WriteEngine`:

```swift
    /// SHA-256 of an entire ImageSource (re-reads from the start; caller resets).
    public static func sha256(of source: ImageSource, chunkSize: Int = Sector.chunkSize) throws -> Data {
        var hasher = SHA256()
        while true {
            let chunk = try source.read(maxLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter VerifyTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/RufusCore/BlockReader.swift Sources/RufusCore/BlockWriter.swift Sources/RufusCore/WriteEngine.swift Tests/RufusCoreTests/VerifyTests.swift
git commit -m "feat: add device block writer/reader and SHA-256 verification"
```

---

## Task 7: Walking skeleton — end-to-end write+verify against an hdiutil device (unprivileged)

This proves the spine on real device nodes without root, using an `hdiutil`-attached raw image owned by the current user (verified: such nodes are user-owned).

**Files:**
- Create: `TestSupport/HdiutilDevice.swift` (add a `TestSupport` target to `Package.swift`)
- Create: `Tests/RufusCoreTests/DeviceIntegrationTests.swift`

- [ ] **Step 1: Add a `TestSupport` target** to `Package.swift`

Add target and wire it into `RufusCoreTests` deps:

```swift
        .target(name: "TestSupport"),
        .testTarget(name: "RufusCoreTests",
                    dependencies: ["RufusCore", "TestSupport",
                                   .product(name: "Crypto", package: "swift-crypto")]),
```

- [ ] **Step 2: Write the test-support helper** in `Sources/TestSupport/HdiutilDevice.swift`

```swift
import Foundation

/// Attaches a blank raw disk image via `hdiutil` for integration tests.
/// The resulting `/dev/diskN` is owned by the current user, so the write
/// path can be exercised without root. `hdiutil` is a test-only dependency.
public final class HdiutilDevice {
    public let bsdDiskPath: String      // /dev/diskN
    public var bsdRawPath: String {     // /dev/rdiskN
        bsdDiskPath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
    }
    private let imageURL: URL

    public init(sizeMB: Int) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdi-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        try fh.truncate(atOffset: UInt64(sizeMB) * 1024 * 1024)
        try fh.close()
        self.imageURL = url

        let out = try HdiutilDevice.run(
            "/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", url.path]
        )
        guard let dev = out.split(separator: "\n").first?
            .split(separator: " ").first.map(String.init) else {
            throw NSError(domain: "HdiutilDevice", code: 1)
        }
        self.bsdDiskPath = dev
    }

    public func detach() {
        _ = try? HdiutilDevice.run("/usr/bin/hdiutil", ["detach", bsdDiskPath])
        try? FileManager.default.removeItem(at: imageURL)
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 3: Write the integration test** in `Tests/RufusCoreTests/DeviceIntegrationTests.swift`

```swift
import XCTest
import Crypto
import TestSupport
@testable import RufusCore

final class DeviceIntegrationTests: XCTestCase {
    func testWriteThenVerifyAgainstHdiutilDevice() throws {
        // 8 MiB image written into a 16 MB device.
        let payload = Data((0..<(8 * 1024 * 1024)).map { UInt8($0 % 251) })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-\(UUID().uuidString).img")
        try payload.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let device = try HdiutilDevice(sizeMB: 16)
        defer { device.detach() }

        let engine = WriteEngine()

        // Compute source hash, then write.
        let hashSource = try FileImageSource(url: imageURL)
        let expectedHash = try WriteEngine.sha256(of: hashSource)
        hashSource.close()

        let source = try FileImageSource(url: imageURL)
        defer { source.close() }
        let writer = try DeviceBlockWriter(devicePath: device.bsdRawPath)
        try engine.write(source: source, to: writer, isCancelled: { false }, progress: { _ in })

        // Verify by reading back from the raw device.
        let reader = try DeviceBlockReader(devicePath: device.bsdRawPath)
        defer { reader.close() }
        XCTAssertNoThrow(
            try engine.verify(reader: reader, imageSize: UInt64(payload.count),
                              expectedHash: expectedHash, isCancelled: { false },
                              progress: { _ in })
        )
    }
}
```

- [ ] **Step 4: Run the integration test**

Run: `swift test --filter DeviceIntegrationTests`
Expected: PASS. (If it fails because no `/dev/diskN` was returned, ensure no VPN/security tool blocks `hdiutil`; run `swift test --filter DeviceIntegrationTests -v` to inspect.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/TestSupport/HdiutilDevice.swift Tests/RufusCoreTests/DeviceIntegrationTests.swift
git commit -m "test: end-to-end write+verify against hdiutil device (walking skeleton)"
```

**✅ Milestone 1 complete:** the write/verify spine is proven on real device nodes, unprivileged.

---

## Task 8: DiskInfo value type

**Files:**
- Create: `Sources/DiskDiscovery/DiskInfo.swift`
- Create: `Tests/DiskDiscoveryTests/DiskInfoTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/DiskDiscoveryTests/DiskInfoTests.swift`

```swift
import XCTest
@testable import DiskDiscovery

final class DiskInfoTests: XCTestCase {
    func testHumanReadableSize() {
        let d = DiskInfo(bsdName: "disk4", model: "SanDisk USB", sizeBytes: 16_000_000_000,
                         isRemovable: true)
        XCTAssertEqual(d.displaySize, "16.0 GB")
        XCTAssertEqual(d.devicePath, "/dev/disk4")
        XCTAssertEqual(d.rawDevicePath, "/dev/rdisk4")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiskInfoTests`
Expected: FAIL — no `DiskInfo`.

- [ ] **Step 3: Write implementation** in `Sources/DiskDiscovery/DiskInfo.swift`

```swift
import Foundation

/// Identifying information for a candidate target disk.
public struct DiskInfo: Identifiable, Hashable, Sendable {
    public let bsdName: String          // e.g. "disk4"
    public let model: String            // e.g. "SanDisk Ultra"
    public let sizeBytes: UInt64
    public let isRemovable: Bool

    public var id: String { bsdName }
    public var devicePath: String { "/dev/\(bsdName)" }
    public var rawDevicePath: String { "/dev/r\(bsdName)" }

    public init(bsdName: String, model: String, sizeBytes: UInt64, isRemovable: Bool) {
        self.bsdName = bsdName
        self.model = model
        self.sizeBytes = sizeBytes
        self.isRemovable = isRemovable
    }

    public var displaySize: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .decimal
        fmt.allowedUnits = [.useGB, .useMB]
        return fmt.string(fromByteCount: Int64(sizeBytes))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiskInfoTests`
Expected: PASS. (If `ByteCountFormatter` yields "16 GB" without the trailing ".0", adjust the assertion to the actual string — formatter output is locale/OS-version dependent; lock the test to the observed value.)

- [ ] **Step 5: Commit**

```bash
git add Sources/DiskDiscovery/DiskInfo.swift Tests/DiskDiscoveryTests/DiskInfoTests.swift
git commit -m "feat: add DiskInfo value type"
```

---

## Task 9: DiskDiscovery — enumerate removable disks (spike + codify)

**Files:**
- Create: `Sources/DiskDiscovery/DiskDiscovery.swift`

DiskArbitration is system-API-heavy. **Spike first:** in a scratch executable or test, get `DiskDiscovery.removableDisks()` returning real disks on this machine, then codify the working calls here. The shape below is the target; lock exact key names (`DADiskDescription` keys) against what compiles and returns data on macOS 26.

- [ ] **Step 1: Implement** `Sources/DiskDiscovery/DiskDiscovery.swift`

```swift
import Foundation
import DiskArbitration
import IOKit

public enum DiskDiscovery {
    /// Enumerate whole disks that are removable/ejectable (USB sticks, SD cards),
    /// excluding internal/system disks. Returns whole-disk entries only (no slices).
    public static func removableDisks() -> [DiskInfo] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }

        var results: [DiskInfo] = []
        // Iterate IOKit media that are whole + removable.
        let matching = IOServiceMatching("IOMedia")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            guard boolProperty(service, "Whole") == true else { continue }

            guard let bsdName = stringProperty(service, "BSD Name"),
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
                  let desc = DADiskCopyDescription(disk) as? [String: Any]
            else { continue }

            let removable = (desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false
            let ejectable = (desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false
            let isInternal = (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
            guard (removable || ejectable) && !isInternal else { continue }

            let size = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0
            let vendor = (desc[kDADiskDescriptionDeviceVendorKey as String] as? String) ?? ""
            let modelName = (desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? "Disk"
            let model = [vendor, modelName].filter { !$0.isEmpty }.joined(separator: " ")

            results.append(DiskInfo(bsdName: bsdName, model: model.isEmpty ? "Disk" : model,
                                    sizeBytes: size, isRemovable: true))
        }
        return results
    }

    private static func stringProperty(_ service: io_object_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        if let s = cf as? String { return s }
        if let d = cf as? Data { return String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) }
        return nil
    }

    private static func boolProperty(_ service: io_object_t, _ key: String) -> Bool? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()) as? Bool
    }
}
```

- [ ] **Step 2: Verify manually with a scratch run**

Create a throwaway test that prints results and confirm against your machine. Run:
`swift test --filter DiskInfoTests` keeps passing; then plug a USB stick and run a temporary print test to confirm it appears and internal disks do not. Remove the throwaway test before committing.

- [ ] **Step 3: Commit**

```bash
git add Sources/DiskDiscovery/DiskDiscovery.swift
git commit -m "feat: enumerate removable disks via DiskArbitration/IOKit"
```

---

## Task 10: DiskDiscovery — unmount a whole disk

**Files:**
- Modify: `Sources/DiskDiscovery/DiskDiscovery.swift` (add `unmountDisk`)

Before a raw write, every mounted volume on the target disk must be unmounted. `DADiskUnmount` with the whole-disk option unmounts all slices.

- [ ] **Step 1: Add `unmountDisk`**

```swift
public enum UnmountError: Error { case sessionFailed, diskFailed, unmountFailed(String) }

extension DiskDiscovery {
    /// Unmount all volumes on the whole disk identified by `bsdName`.
    /// Blocks until the operation completes (or fails). Safe to call when nothing
    /// is mounted (returns immediately).
    public static func unmountDisk(bsdName: String, timeout: TimeInterval = 30) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw UnmountError.sessionFailed }
        let queue = DispatchQueue(label: "rufus4mac.unmount")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw UnmountError.diskFailed
        }

        let sema = DispatchSemaphore(value: 0)
        var failure: String?

        let ctx = UnsafeMutablePointer<UnmountBox>.allocate(capacity: 1)
        ctx.initialize(to: UnmountBox(sema: sema, setFailure: { failure = $0 }))
        defer { ctx.deinitialize(count: 1); ctx.deallocate() }

        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
            let box = context!.assumingMemoryBound(to: UnmountBox.self).pointee
            if let dissenter {
                let status = DADissenterGetStatus(dissenter)
                box.setFailure("unmount dissented (status \(status))")
            }
            box.sema.signal()
        }, ctx)

        if sema.wait(timeout: .now() + timeout) == .timedOut {
            throw UnmountError.unmountFailed("timed out")
        }
        if let failure { throw UnmountError.unmountFailed(failure) }
    }
}

private struct UnmountBox { let sema: DispatchSemaphore; let setFailure: (String) -> Void }
```

- [ ] **Step 2: Manual verification**

With a mounted USB stick present, add a temporary test calling `unmountDisk` and confirm the volume disappears from Finder, then remove the throwaway test.

- [ ] **Step 3: Commit**

```bash
git add Sources/DiskDiscovery/DiskDiscovery.swift
git commit -m "feat: unmount whole disk via DiskArbitration before write"
```

---

## Task 11: Integration — discover, unmount, write, verify against hdiutil device

**Files:**
- Create: `Tests/RufusCoreTests/FullFlowIntegrationTests.swift` (depends on DiskDiscovery)
- Modify: `Package.swift` (add `DiskDiscovery` to `RufusCoreTests` deps)

- [ ] **Step 1: Add `DiskDiscovery`** to the `RufusCoreTests` target dependencies in `Package.swift`.

- [ ] **Step 2: Write the test**

```swift
import XCTest
import TestSupport
import DiskDiscovery
@testable import RufusCore

final class FullFlowIntegrationTests: XCTestCase {
    func testUnmountWriteVerify() throws {
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 211) })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("p-\(UUID().uuidString).img")
        try payload.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let device = try HdiutilDevice(sizeMB: 16)
        defer { device.detach() }
        let bsd = String(device.bsdDiskPath.dropFirst("/dev/".count))

        // -nomount image has nothing mounted; unmount should be a safe no-op.
        XCTAssertNoThrow(try DiskDiscovery.unmountDisk(bsdName: bsd))

        let engine = WriteEngine()
        let hs = try FileImageSource(url: imageURL)
        let expected = try WriteEngine.sha256(of: hs); hs.close()
        let src = try FileImageSource(url: imageURL); defer { src.close() }
        let writer = try DeviceBlockWriter(devicePath: device.bsdRawPath)
        try engine.write(source: src, to: writer, isCancelled: { false }, progress: { _ in })
        let reader = try DeviceBlockReader(devicePath: device.bsdRawPath); defer { reader.close() }
        XCTAssertNoThrow(try engine.verify(reader: reader, imageSize: UInt64(payload.count),
                                           expectedHash: expected, isCancelled: { false },
                                           progress: { _ in }))
    }
}
```

- [ ] **Step 3: Run**

Run: `swift test --filter FullFlowIntegrationTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/RufusCoreTests/FullFlowIntegrationTests.swift
git commit -m "test: discover+unmount+write+verify integration against hdiutil device"
```

**✅ Milestone 2 complete:** discovery + unmount + write + verify proven together, unprivileged.

---

## Task 12: XPC protocol contract

**Files:**
- Create: `Sources/XPCProtocol/WriteServiceProtocol.swift`

Defines the app↔helper interface. The helper exposes a write operation; progress flows back via a callback protocol. Uses `NSXPCConnection` (Objective-C runtime), so protocols are `@objc`.

- [ ] **Step 1: Implement** `Sources/XPCProtocol/WriteServiceProtocol.swift`

```swift
import Foundation

/// Implemented by the privileged helper; called by the app.
@objc public protocol WriteServiceProtocol {
    /// Unmount `bsdName`, raw-write the file at `imagePath` to `/dev/r<bsdName>`,
    /// then verify. Progress is reported via the connection's exported
    /// `WriteProgressObserver`. `reply` is called once at completion.
    func write(imagePath: String,
               bsdName: String,
               expectedSHA256 base64: String,
               reply: @escaping (_ errorDescription: String?) -> Void)

    /// Liveness check used during helper install.
    func ping(reply: @escaping (String) -> Void)
}

/// Implemented by the app; called by the helper to stream progress.
@objc public protocol WriteProgressObserver {
    /// `phase` is "writing" or "verifying".
    func progress(phase: String, bytesDone: UInt64, total: UInt64)
}

/// Shared constant: the Mach service name the helper registers.
public enum XPCConstants {
    public static let machServiceName = "com.huconn.rufus4mac.helper"
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/XPCProtocol/WriteServiceProtocol.swift
git commit -m "feat: define XPC write-service protocol contract"
```

---

## Task 13: Create the Xcode project (app + helper targets)

**Files:**
- Create: `app/rufus4mac.xcodeproj` with two targets: `RufusApp` (SwiftUI app) and `RufusHelper` (command-line tool / LaunchDaemon).

This is an Xcode/GUI operation; do it in Xcode, then commit the generated project. Configure:

- [ ] **Step 1: New Xcode project** → macOS App, name `RufusApp`, SwiftUI, Swift, organization identifier `com.huconn`, location `app/`. Set deployment target macOS 13.
- [ ] **Step 2: Add a second target** → macOS Command Line Tool named `RufusHelper`.
- [ ] **Step 3: Add the local SPM package** (repo root) to the project: File → Add Package Dependencies → Add Local → select repo root. Link `RufusCore`, `DiskDiscovery`, `XPCProtocol` to **RufusHelper**; link `DiskDiscovery`, `XPCProtocol` to **RufusApp**.
- [ ] **Step 4: Signing** → for both targets, Team = HUCONN Co.,Ltd. (XGJ87M8ZZR), Signing Certificate = Development for now.
- [ ] **Step 5: Build both targets** in Xcode (⌘B). Expected: both compile.
- [ ] **Step 6: Commit**

```bash
git add app/
git commit -m "chore: add Xcode project with RufusApp and RufusHelper targets"
```

---

## Task 14: Implement the helper's write service

**Files:**
- Create: `app/RufusHelper/main.swift`
- Create: `app/RufusHelper/WriteService.swift`

- [ ] **Step 1: Implement `WriteService`** in `app/RufusHelper/WriteService.swift`

```swift
import Foundation
import RufusCore
import DiskDiscovery
import XPCProtocol

final class WriteService: NSObject, WriteServiceProtocol {
    private let connection: NSXPCConnection
    init(connection: NSXPCConnection) { self.connection = connection }

    func ping(reply: @escaping (String) -> Void) { reply("pong") }

    func write(imagePath: String, bsdName: String, expectedSHA256 base64: String,
               reply: @escaping (String?) -> Void) {
        let observer = connection.remoteObjectProxy as? WriteProgressObserver
        do {
            try DiskDiscovery.unmountDisk(bsdName: bsdName)

            let engine = WriteEngine()
            let source = try FileImageSource(url: URL(fileURLWithPath: imagePath))
            defer { source.close() }
            let rawPath = "/dev/r\(bsdName)"

            // Pre-flight: image must fit.
            let disks = DiskDiscovery.removableDisks()
            if let target = disks.first(where: { $0.bsdName == bsdName }),
               source.size > target.sizeBytes {
                throw WriteError.imageLargerThanTarget(imageSize: source.size,
                                                       targetSize: target.sizeBytes)
            }

            let writer = try DeviceBlockWriter(devicePath: rawPath)
            try engine.write(source: source, to: writer, isCancelled: { false }) { p in
                observer?.progress(phase: "writing", bytesDone: p.bytesWritten, total: p.totalBytes)
            }

            guard let expected = Data(base64Encoded: base64) else { throw WriteError.verificationMismatch }
            let reader = try DeviceBlockReader(devicePath: rawPath)
            defer { reader.close() }
            try engine.verify(reader: reader, imageSize: source.size, expectedHash: expected,
                              isCancelled: { false }) { p in
                observer?.progress(phase: "verifying", bytesDone: p.bytesWritten, total: p.totalBytes)
            }
            reply(nil)
        } catch {
            reply("\(error)")
        }
    }
}
```

- [ ] **Step 2: Implement the daemon entry point** in `app/RufusHelper/main.swift`

```swift
import Foundation
import XPCProtocol

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WriteServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WriteProgressObserver.self)
        let service = WriteService(connection: connection)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: XPCConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
```

- [ ] **Step 3: Build the helper** in Xcode (⌘B, RufusHelper scheme). Expected: compiles.

- [ ] **Step 4: Commit**

```bash
git add app/RufusHelper/
git commit -m "feat: helper XPC write service (unmount, write, verify)"
```

---

## Task 15: Install the helper manually (dev) and prove privileged write on a real USB

This validates the privileged path **before** SMAppService automation. Use a dedicated, expendable USB stick.

**Files:**
- Create: `app/RufusHelper/com.huconn.rufus4mac.helper.plist` (LaunchDaemon plist)
- Create: `scripts/dev-install-helper.sh`

- [ ] **Step 1: Write the LaunchDaemon plist** `app/RufusHelper/com.huconn.rufus4mac.helper.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.huconn.rufus4mac.helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.huconn.rufus4mac.helper</key>
        <true/>
    </dict>
    <key>BundleProgram</key>
    <string>RufusHelper</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the dev install script** `scripts/dev-install-helper.sh`

```bash
#!/usr/bin/env bash
# Dev-only: install the built RufusHelper as a LaunchDaemon. Requires sudo.
# Usage: sudo ./scripts/dev-install-helper.sh /path/to/RufusHelper
set -euo pipefail
HELPER_BIN="${1:?path to built RufusHelper binary required}"
LABEL="com.huconn.rufus4mac.helper"
sudo cp "$HELPER_BIN" "/Library/PrivilegedHelperTools/$LABEL"
sudo cp "app/RufusHelper/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"
# Point BundleProgram at the installed absolute path for dev:
sudo /usr/libexec/PlistBuddy -c "Set :BundleProgram /Library/PrivilegedHelperTools/$LABEL" \
    "/Library/LaunchDaemons/$LABEL.plist"
sudo launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" || true
echo "Helper installed. Uninstall: sudo launchctl bootout system/$LABEL; sudo rm /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL"
```

- [ ] **Step 3: Manual end-to-end check (documented, not automated — destructive)**

1. Build RufusHelper (Release) in Xcode; note the product path.
2. `sudo ./scripts/dev-install-helper.sh <product-path>`
3. Insert an **expendable** USB stick; find its `diskN` via the app's discovery (or `diskutil list`).
4. Use a tiny test client (Task 16 covers the app; for now a scratch XPC client) to write a small `.iso`.
5. Confirm `reply(nil)` (success) and that the stick boots / mounts as expected.

- [ ] **Step 4: Commit**

```bash
git add app/RufusHelper/com.huconn.rufus4mac.helper.plist scripts/dev-install-helper.sh
git commit -m "chore: LaunchDaemon plist + dev helper install script"
```

**✅ Milestone 3 complete:** privileged write works on real hardware via the manually-installed helper.

---

## Task 16: App-side XPC client

**Files:**
- Create: `app/RufusApp/WriteClient.swift`

- [ ] **Step 1: Implement `WriteClient`** in `app/RufusApp/WriteClient.swift`

```swift
import Foundation
import XPCProtocol

@MainActor
final class WriteClient: NSObject, ObservableObject, WriteProgressObserver {
    @Published var phase: String = ""
    @Published var fraction: Double = 0
    @Published var finished: Bool = false
    @Published var errorText: String?

    private var connection: NSXPCConnection?

    private func connect() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: XPCConstants.machServiceName,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: WriteServiceProtocol.self)
        c.exportedInterface = NSXPCInterface(with: WriteProgressObserver.self)
        c.exportedObject = self
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.errorText = self?.errorText ?? "helper connection lost" }
        }
        c.resume()
        connection = c
        return c
    }

    func startWrite(imagePath: String, bsdName: String, expectedSHA256Base64: String) {
        let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] err in
            Task { @MainActor in self?.errorText = "\(err)" }
        } as? WriteServiceProtocol
        proxy?.write(imagePath: imagePath, bsdName: bsdName,
                     expectedSHA256: expectedSHA256Base64) { [weak self] errorDescription in
            Task { @MainActor in
                self?.errorText = errorDescription
                self?.finished = true
            }
        }
    }

    // WriteProgressObserver — called by the helper (non-main thread).
    nonisolated func progress(phase: String, bytesDone: UInt64, total: UInt64) {
        Task { @MainActor in
            self.phase = phase
            self.fraction = total == 0 ? 0 : Double(bytesDone) / Double(total)
        }
    }
}
```

- [ ] **Step 2: Build** (⌘B, RufusApp). Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add app/RufusApp/WriteClient.swift
git commit -m "feat: app-side XPC client with progress observation"
```

---

## Task 17: App — disk list view model

**Files:**
- Create: `app/RufusApp/DiskListViewModel.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import DiskDiscovery

@MainActor
final class DiskListViewModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var selected: DiskInfo?

    func refresh() {
        let found = DiskDiscovery.removableDisks()
        disks = found
        if let sel = selected, !found.contains(where: { $0.id == sel.id }) {
            selected = nil
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/RufusApp/DiskListViewModel.swift
git commit -m "feat: disk list view model"
```

---

## Task 18: App — image selection model

**Files:**
- Create: `app/RufusApp/ImageSelection.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import RufusCore

@MainActor
final class ImageSelection: ObservableObject {
    @Published var imageURL: URL?
    @Published var imageSize: UInt64 = 0
    @Published var sha256Base64: String?
    @Published var hashing = false

    func select(url: URL) {
        imageURL = url
        sha256Base64 = nil
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        imageSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Compute the source hash off the main actor (used for verification).
    func computeHash() async {
        guard let url = imageURL else { return }
        hashing = true
        defer { hashing = false }
        let base64: String? = await Task.detached {
            guard let src = try? FileImageSource(url: url) else { return nil }
            defer { src.close() }
            let data = try? WriteEngine.sha256(of: src)
            return data?.base64EncodedString()
        }.value
        sha256Base64 = base64
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/RufusApp/ImageSelection.swift
git commit -m "feat: image selection model with async hashing"
```

---

## Task 19: App — main SwiftUI view

**Files:**
- Modify: `app/RufusApp/RufusAppApp.swift` (or the generated `*App.swift`)
- Create: `app/RufusApp/ContentView.swift`

- [ ] **Step 1: Implement `ContentView`** in `app/RufusApp/ContentView.swift`

```swift
import SwiftUI
import UniformTypeIdentifiers
import DiskDiscovery

struct ContentView: View {
    @StateObject private var diskVM = DiskListViewModel()
    @StateObject private var image = ImageSelection()
    @StateObject private var writer = WriteClient()
    @State private var showConfirm = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("rufus4mac").font(.largeTitle.bold())

            GroupBox("Image") {
                HStack {
                    Text(image.imageURL?.lastPathComponent ?? "No image selected")
                        .foregroundStyle(image.imageURL == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { importing = true }
                }
            }

            GroupBox("Target disk") {
                HStack {
                    Picker("Disk", selection: $diskVM.selected) {
                        Text("Select a disk").tag(DiskInfo?.none)
                        ForEach(diskVM.disks) { d in
                            Text("\(d.model) — \(d.displaySize) (/dev/\(d.bsdName))")
                                .tag(DiskInfo?.some(d))
                        }
                    }
                    Button("Refresh") { diskVM.refresh() }
                }
            }

            if writer.phase.isEmpty == false || writer.finished {
                ProgressView(value: writer.fraction) {
                    Text(writer.finished
                         ? (writer.errorText.map { "Failed: \($0)" } ?? "Done ✅")
                         : "\(writer.phase.capitalized)… \(Int(writer.fraction * 100))%")
                }
            }

            Button("Write") { showConfirm = true }
                .disabled(image.imageURL == nil || diskVM.selected == nil)
                .keyboardShortcut(.defaultAction)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { diskVM.refresh() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: imageTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                image.select(url: url)
                Task { await image.computeHash() }
            }
        }
        .alert("Erase \(diskVM.selected?.model ?? "")?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Erase and Write", role: .destructive) { startWrite() }
        } message: {
            Text("All data on /dev/\(diskVM.selected?.bsdName ?? "") (\(diskVM.selected?.displaySize ?? "")) will be destroyed.")
        }
    }

    private var imageTypes: [UTType] {
        [UTType(filenameExtension: "iso"), UTType(filenameExtension: "img"),
         UTType(filenameExtension: "dmg")].compactMap { $0 }
    }

    private func startWrite() {
        guard let url = image.imageURL, let disk = diskVM.selected,
              let hash = image.sha256Base64 else { return }
        writer.startWrite(imagePath: url.path, bsdName: disk.bsdName,
                          expectedSHA256Base64: hash)
    }
}
```

- [ ] **Step 2: Point the app entry at `ContentView`** (the generated `*App.swift` should already show `ContentView()` in its `WindowGroup`; if not, set it).

- [ ] **Step 3: Run the app** (⌘R). With no helper installed, the disk list should populate; Write will fail at the XPC step (expected until helper is installed). Confirm UI behavior (selection, confirm dialog, progress bar layout).

- [ ] **Step 4: Commit**

```bash
git add app/RufusApp/ContentView.swift app/RufusApp/*App.swift
git commit -m "feat: main SwiftUI view (image picker, disk picker, confirm, progress)"
```

---

## Task 20: App entitlements and hardened runtime

**Files:**
- Modify: `app/RufusApp/RufusApp.entitlements`

- [ ] **Step 1: Configure entitlements**

The app reads user-selected images and talks to a privileged helper, so it is **not** sandboxed (sandbox blocks raw disk + privileged helper install of this kind). Ensure:
- App sandbox: **OFF** (remove `com.apple.security.app-sandbox` or set false).
- Hardened Runtime: **ON** (required for notarization).

There is no special entitlement needed for `NSXPCConnection(machServiceName:options:.privileged)` on the client; the privilege comes from the daemon running as root.

- [ ] **Step 2: Build with Hardened Runtime** in Xcode (Signing & Capabilities → Hardened Runtime added). Expected: builds and runs.

- [ ] **Step 3: Commit**

```bash
git add app/RufusApp/RufusApp.entitlements app/rufus4mac.xcodeproj
git commit -m "chore: disable sandbox, enable hardened runtime for app"
```

**✅ Milestone 4 complete:** full GUI works end-to-end with the dev-installed helper.

---

## Task 21: Pre-flight guard rails in the UI

**Files:**
- Modify: `app/RufusApp/ImageSelection.swift`
- Modify: `app/RufusApp/ContentView.swift`

- [ ] **Step 1: Add a fit check** to `ImageSelection`:

```swift
    func fits(disk: DiskInfo) -> Bool { imageSize > 0 && imageSize <= disk.sizeBytes }
```

- [ ] **Step 2: Disable Write and show a warning** when the image does not fit. In `ContentView`, change the Write button's `.disabled` to also require fit, and add an inline message:

```swift
            if let disk = diskVM.selected, image.imageSize > 0, !image.fits(disk: disk) {
                Label("Image is larger than the selected disk.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
```
and
```swift
            Button("Write") { showConfirm = true }
                .disabled(image.imageURL == nil || diskVM.selected == nil || image.sha256Base64 == nil
                          || (diskVM.selected.map { !image.fits(disk: $0) } ?? true))
```

- [ ] **Step 3: Run** and confirm the Write button disables for an oversized image and while hashing (`sha256Base64 == nil`).

- [ ] **Step 4: Commit**

```bash
git add app/RufusApp/ImageSelection.swift app/RufusApp/ContentView.swift
git commit -m "feat: pre-flight fit check and write-button guards"
```

---

## Task 22: Helper install via SMAppService (spike + codify)

**Files:**
- Create: `app/RufusApp/HelperInstaller.swift`
- Modify: `app/RufusApp/ContentView.swift` (install on demand before first write)
- Modify: Xcode project — embed the daemon plist at `Contents/Library/LaunchDaemons/` and the helper binary in the app bundle.

SMAppService is signing-sensitive; **spike** the registration on this machine with the Developer ID cert, then codify. Target shape:

- [ ] **Step 1: Implement `HelperInstaller`** in `app/RufusApp/HelperInstaller.swift`

```swift
import Foundation
import ServiceManagement

enum HelperInstaller {
    /// The daemon plist must be embedded at Contents/Library/LaunchDaemons/<plist>.
    static let plistName = "com.huconn.rufus4mac.helper.plist"

    static var service: SMAppService { .daemon(plistName: plistName) }

    /// Register the daemon if not already enabled. Prompts the user to approve
    /// in System Settings > Login Items if required. Returns true if registered.
    @discardableResult
    static func ensureInstalled() throws -> Bool {
        switch service.status {
        case .enabled: return true
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return false
        default:
            try service.register()
            return service.status == .enabled
        }
    }
}
```

- [ ] **Step 2: Embed the daemon** — in Xcode, add a Copy Files build phase on RufusApp that copies the built `RufusHelper` into the app and the plist into `Contents/Library/LaunchDaemons/`. The plist's `BundleProgram` must point at the embedded helper path (relative to the bundle). Lock exact paths during the spike.

- [ ] **Step 3: Call `ensureInstalled()`** before the first write in `ContentView.startWrite()`:

```swift
    private func startWrite() {
        guard let url = image.imageURL, let disk = diskVM.selected,
              let hash = image.sha256Base64 else { return }
        do {
            guard try HelperInstaller.ensureInstalled() else {
                writer.errorText = "Approve the helper in System Settings, then try again."
                writer.finished = true
                return
            }
        } catch {
            writer.errorText = "Helper install failed: \(error)"
            writer.finished = true
            return
        }
        writer.startWrite(imagePath: url.path, bsdName: disk.bsdName,
                          expectedSHA256Base64: hash)
    }
```

- [ ] **Step 4: Spike-verify** — remove the dev-installed helper (`sudo launchctl bootout system/com.huconn.rufus4mac.helper`), run the app, trigger a write, approve in System Settings if prompted, confirm the write completes via the auto-registered daemon.

- [ ] **Step 5: Commit**

```bash
git add app/RufusApp/HelperInstaller.swift app/RufusApp/ContentView.swift app/rufus4mac.xcodeproj
git commit -m "feat: SMAppService helper registration with approval flow"
```

---

## Task 23: Real-USB manual verification checklist

**Files:**
- Create: `docs/manual-test-checklist.md`

- [ ] **Step 1: Write the checklist** documenting the destructive end-to-end test:

```markdown
# Phase 1 Manual Test Checklist

Prereqs: expendable USB stick, a small Linux ISO (e.g. Alpine), app built & signed.

1. [ ] Launch rufus4mac. Insert USB. It appears in the disk picker; internal disks do NOT.
2. [ ] Choose the ISO. Hash computes (Write enables once hashing finishes).
3. [ ] Oversized check: pick a disk smaller than the image → Write stays disabled with warning.
4. [ ] Click Write → confirm dialog names the correct disk + size → Erase and Write.
5. [ ] First run: approve helper in System Settings if prompted; retry.
6. [ ] Progress shows "Writing…" then "Verifying…" reaching 100%.
7. [ ] Result shows "Done ✅".
8. [ ] Boot a target machine from the USB; confirm it boots.
9. [ ] Failure path: yank the USB mid-write → app reports a clear error, no crash.
```

- [ ] **Step 2: Execute the checklist** on real hardware and record results.

- [ ] **Step 3: Commit**

```bash
git add docs/manual-test-checklist.md
git commit -m "docs: Phase 1 manual test checklist"
```

---

## Task 24: Notarized DMG packaging

**Files:**
- Create: `scripts/build-dmg.sh`

- [ ] **Step 1: Write the packaging script** `scripts/build-dmg.sh`

```bash
#!/usr/bin/env bash
# Build, sign (Developer ID), notarize, and staple a DMG.
# Requires: notarytool keychain profile "rufus4mac-notary" set up via
#   xcrun notarytool store-credentials.
set -euo pipefail
APP="build/Release/RufusApp.app"
DMG="build/rufus4mac.dmg"
IDENTITY="Developer ID Application: HUCONN Co.,Ltd. (XGJ87M8ZZR)"

xcodebuild -project app/rufus4mac.xcodeproj -scheme RufusApp \
    -configuration Release -derivedDataPath build/dd build
cp -R "build/dd/Build/Products/Release/RufusApp.app" "build/Release/"

# Deep-sign (helper inside the bundle is signed too) with hardened runtime.
codesign --force --options runtime --deep --sign "$IDENTITY" "$APP"

hdiutil create -volname rufus4mac -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --sign "$IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "rufus4mac-notary" --wait
xcrun stapler staple "$DMG"
echo "Notarized DMG: $DMG"
```

- [ ] **Step 2: Run** `bash scripts/build-dmg.sh` and confirm `notarytool` returns `Accepted` and `stapler` succeeds.

- [ ] **Step 3: Verify** `spctl -a -vvv -t install build/Release/RufusApp.app` reports `accepted` / `source=Notarized Developer ID`.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-dmg.sh
git commit -m "chore: notarized DMG packaging script"
```

**✅ Milestone 5 complete:** distributable, notarized rufus4mac.

---

## Task 25: README + roadmap update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README** — mark Phase 1 done, add build/run instructions (`swift test` for core; Xcode for app; `scripts/build-dmg.sh` for release), link the spec and this plan, and the manual test checklist.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for Phase 1 (build, run, package)"
```

---

## Self-Review Notes (addressed)

- **Spec coverage:** device list (Tasks 9, 17, 19), image selection iso/img/dmg (Tasks 18–19), unmount + raw write (Tasks 6, 10, 14), progress (Tasks 5, 16, 19), verify (Task 6, 14), removable-only + confirm dialog + cancellation surface (Tasks 9, 19; cancellation plumbed through `isCancelled` in engine — note: UI cancel button is a Phase-1.1 follow-up, engine supports it), pre-flight size check (Tasks 14, 21), notarized DMG / non-sandbox / SMAppService (Tasks 20, 22, 24). Error-handling table mapped across Tasks 6 (errno), 14 (reply errors), 16 (connection lost), 21 (oversize).
- **Known deferral:** a user-facing **Cancel button** is not wired in Task 19 (engine supports cancellation via `isCancelled`). Add as a small follow-up if desired; not required for the Phase 1 spec's core flow.
- **Type consistency:** `WriteEngine.write/verify/sha256`, `WriteProgress(bytesWritten:totalBytes:)`, `DiskInfo(bsdName:model:sizeBytes:isRemovable:)`, `WriteServiceProtocol.write(imagePath:bsdName:expectedSHA256:reply:)`, `XPCConstants.machServiceName` used consistently across tasks.
- **Spike-flagged tasks** (system-API/signing sensitive, codify after spike): Task 9 (DiskArbitration keys), Task 22 (SMAppService embed paths). These intentionally avoid baking unverified API incantations into blind-execution steps.
