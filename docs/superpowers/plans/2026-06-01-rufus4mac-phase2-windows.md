# rufus4mac Phase 2 Implementation Plan (Windows Install USB)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a UEFI-bootable Windows 10/11 install USB on macOS from a Windows ISO — FAT32 + split `install.wim` — with an optional Windows 11 hardware-check bypass.

**Architecture:** A new SPM library `WindowsMedia` orchestrates the build by driving system tools (`diskutil`, `hdiutil`, bundled `wimlib-imagex`) through an injectable `ProcessRunner`. Pure-logic units (Windows detection, Win11 bypass file edits, wimlib argument building) are TDD'd against fakes; system-tool steps are proven with spikes against `hdiutil`-attached devices. The SwiftUI app detects a Windows ISO and routes it to a Windows flow; Linux/general images keep Phase 1's raw/DD `ElevatedWriter`.

**Tech Stack:** Swift 6.2, SPM, `diskutil`/`hdiutil` (built-in), `wimlib-imagex` (bundled, LGPLv3), SwiftUI, xcodegen. Spec: `docs/superpowers/specs/2026-06-01-rufus4mac-phase2-windows-design.md`.

**Key facts / decisions:**
- UEFI Win10/11 only. Approach **B** (FAT32 + split). `install.wim` > 4000 MB is split into `install.swm`.
- `wimlib-imagex split <wim> <out.swm> <MB>` produces `out.swm`, `out2.swm`, … — Windows Setup reads these natively.
- Win11 bypass = zero `sources/appraiserres.dll` + add `autounattend.xml` (LabConfig). No registry/boot.wim editing.
- Privilege: `diskutil eraseDisk` on external/removable USB is expected to work for the console user **without sudo** (Disk Utility's right). **Validated by a spike (Task 8).** File copy to the mounted FAT32 volume is unprivileged. No `/dev/rdiskN` raw writes → none of Phase 1's TCC raw-write problem.

---

## Milestones
1. **M1 — Process plumbing + wimlib spike (risk-first):** `ProcessRunner` + `WimTool`, prove a real wimlib split. Tasks 1–3.
2. **M2 — Windows detection:** `ISOInspector` detection logic + real-ISO mount. Tasks 4–5.
3. **M3 — Win11 bypass:** pure file edits, TDD. Task 6.
4. **M4 — Orchestrator + format spike:** `WindowsUSBWriter` (unit via fake runner) + diskutil-format spike + hdiutil end-to-end. Tasks 7–9.
5. **M5 — App integration:** detect Windows ISO, Windows UI section, `WindowsWriter`. Tasks 10–12. (build-verified)
6. **M6 — Packaging + docs:** bundle `wimlib-imagex`, manual checklist, README/roadmap. Tasks 13–14.

---

## File Structure
```
Sources/WindowsMedia/
  ProcessRunner.swift     # protocol + ProcessResult + SystemProcessRunner
  WimTool.swift           # locate wimlib-imagex; build+run `split`
  ISOInspector.swift      # mount ISO, detect Windows, install-image size; detach
  Win11Bypass.swift       # zero appraiserres.dll + write autounattend.xml
  WindowsUSBWriter.swift  # orchestrate format → copy → split → bypass → eject
Tests/WindowsMediaTests/
  ProcessRunnerTests.swift
  WimToolTests.swift
  ISOInspectorTests.swift
  Win11BypassTests.swift
  WindowsUSBWriterTests.swift
  WimSplitIntegrationTests.swift     # real wimlib
  FormatCopyIntegrationTests.swift   # real diskutil + hdiutil device
App/
  WindowsWriter.swift     # @MainActor ObservableObject driving WindowsUSBWriter off-main
  (ImageSelection.swift, ContentView.swift modified)
Package.swift             # add WindowsMedia target/product + test target
project.yml               # RufusApp depends on WindowsMedia; bundle wimlib resources
```

---

## Task 1: ProcessRunner (protocol + result + system impl)

**Files:**
- Create: `Sources/WindowsMedia/ProcessRunner.swift`
- Create: `Tests/WindowsMediaTests/ProcessRunnerTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add the `WindowsMedia` target + product + test target to `Package.swift`**

In `products:` add:
```swift
        .library(name: "WindowsMedia", targets: ["WindowsMedia"]),
```
In `targets:` add:
```swift
        .target(name: "WindowsMedia"),
        .testTarget(name: "WindowsMediaTests", dependencies: ["WindowsMedia"]),
```

- [ ] **Step 2: Write the failing test** in `Tests/WindowsMediaTests/ProcessRunnerTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class ProcessRunnerTests: XCTestCase {
    func testRunsAndCapturesStdoutAndStatus() throws {
        let r = SystemProcessRunner()
        let result = try r.run("/bin/echo", ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testNonZeroStatusCaptured() throws {
        let r = SystemProcessRunner()
        let result = try r.run("/bin/sh", ["-c", "echo oops 1>&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.stderr.contains("oops"))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter ProcessRunnerTests`
Expected: FAIL — no `SystemProcessRunner`.

- [ ] **Step 4: Implement** `Sources/WindowsMedia/ProcessRunner.swift`

```swift
import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

/// Runs an external process to completion. Injectable so orchestration can be unit-tested.
public protocol ProcessRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}
    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(data: oData, encoding: .utf8) ?? "",
                             stderr: String(data: eData, encoding: .utf8) ?? "")
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter ProcessRunnerTests` → PASS. Then full `swift test` (expect prior 23 + 2 = 25, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/WindowsMedia/ProcessRunner.swift Tests/WindowsMediaTests/ProcessRunnerTests.swift
git commit -m "feat: WindowsMedia ProcessRunner (injectable process execution)"
```

---

## Task 2: WimTool — locate binary + build split arguments

**Files:**
- Create: `Sources/WindowsMedia/WimTool.swift`
- Create: `Tests/WindowsMediaTests/WimToolTests.swift`

A fake `ProcessRunner` records the command so we can assert exact arguments without running wimlib.

- [ ] **Step 1: Write the failing test** in `Tests/WindowsMediaTests/WimToolTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class FakeRunner: ProcessRunner, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = ProcessResult(status: 0, stdout: "", stderr: "")
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append((executable, arguments)); return result
    }
}

final class WimToolTests: XCTestCase {
    func testSplitInvokesImagexWithChunkSize() throws {
        let fake = FakeRunner()
        let tool = WimTool(runner: fake, imagexPath: "/usr/local/bin/wimlib-imagex")
        try tool.split(wim: "/m/sources/install.wim", outFirstSWM: "/u/sources/install.swm", chunkMB: 4000)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].0, "/usr/local/bin/wimlib-imagex")
        XCTAssertEqual(fake.calls[0].1, ["split", "/m/sources/install.wim", "/u/sources/install.swm", "4000"])
    }

    func testSplitThrowsOnNonZeroStatus() {
        let fake = FakeRunner(); fake.result = ProcessResult(status: 1, stdout: "", stderr: "boom")
        let tool = WimTool(runner: fake, imagexPath: "/x/wimlib-imagex")
        XCTAssertThrowsError(try tool.split(wim: "a", outFirstSWM: "b", chunkMB: 4000))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WimToolTests` → FAIL (no `WimTool`).

- [ ] **Step 3: Implement** `Sources/WindowsMedia/WimTool.swift`

```swift
import Foundation

public struct WimToolError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public struct WimTool: Sendable {
    let runner: ProcessRunner
    let imagexPath: String

    public init(runner: ProcessRunner, imagexPath: String) {
        self.runner = runner; self.imagexPath = imagexPath
    }

    /// Locate `wimlib-imagex`: bundled in the app first, then a dev Homebrew path.
    /// Returns nil if not found.
    public static func locateImagex(bundledDir: String?) -> String? {
        var candidates: [String] = []
        if let d = bundledDir { candidates.append("\(d)/wimlib-imagex") }
        candidates += ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `wimlib-imagex split <wim> <out.swm> <chunkMB>`. Throws on non-zero exit.
    public func split(wim: String, outFirstSWM: String, chunkMB: Int) throws {
        let r = try runner.run(imagexPath, ["split", wim, outFirstSWM, String(chunkMB)])
        if r.status != 0 {
            throw WimToolError(message: "wimlib-imagex split failed (\(r.status)): \(r.stderr)")
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WimToolTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowsMedia/WimTool.swift Tests/WindowsMediaTests/WimToolTests.swift
git commit -m "feat: WimTool wraps wimlib-imagex split (+ binary locator)"
```

---

## Task 3: wimlib split SPIKE (real binary, risk-first)

**Files:**
- Create: `Tests/WindowsMediaTests/WimSplitIntegrationTests.swift`

Prove a real split produces multiple `.swm` parts. Requires wimlib. If absent, the implementer installs it: `brew install wimlib` (provides `/opt/homebrew/bin/wimlib-imagex`).

- [ ] **Step 1: Ensure wimlib present**

Run: `which wimlib-imagex || brew install wimlib`
Confirm `wimlib-imagex --version` prints a version.

- [ ] **Step 2: Write the integration test** in `Tests/WindowsMediaTests/WimSplitIntegrationTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class WimSplitIntegrationTests: XCTestCase {
    func testRealSplitProducesMultipleParts() throws {
        guard let imagex = WimTool.locateImagex(bundledDir: nil) else {
            throw XCTSkip("wimlib-imagex not installed")
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("wim-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Build a ~6 MB capture dir, then capture into a .wim.
        let cap = tmp.appendingPathComponent("cap")
        try fm.createDirectory(at: cap, withIntermediateDirectories: true)
        let big = Data((0..<(6 * 1024 * 1024)).map { UInt8($0 % 251) })
        try big.write(to: cap.appendingPathComponent("payload.bin"))
        let wim = tmp.appendingPathComponent("test.wim")
        let runner = SystemProcessRunner()
        let cap1 = try runner.run(imagex, ["capture", cap.path, wim.path, "--compress=none"])
        XCTAssertEqual(cap1.status, 0, cap1.stderr)

        // Split into ~2 MB parts.
        let tool = WimTool(runner: runner, imagexPath: imagex)
        let outFirst = tmp.appendingPathComponent("test.swm")
        try tool.split(wim: wim.path, outFirstSWM: outFirst.path, chunkMB: 2)

        let parts = try fm.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".swm") }
        XCTAssertGreaterThanOrEqual(parts.count, 2, "expected multiple .swm parts, got \(parts)")
    }
}
```

- [ ] **Step 3: Run**

Run: `swift test --filter WimSplitIntegrationTests`
Expected: PASS (or SKIP if wimlib genuinely unavailable — but install it). Report the part count.

- [ ] **Step 4: Commit**

```bash
git add Tests/WindowsMediaTests/WimSplitIntegrationTests.swift
git commit -m "test: real wimlib split produces multiple SWM parts (spike)"
```

**✅ Milestone 1 complete:** wimlib splitting proven end-to-end.

---

## Task 4: ISOInspector — Windows detection logic (pure, TDD)

**Files:**
- Create: `Sources/WindowsMedia/ISOInspector.swift`
- Create: `Tests/WindowsMediaTests/ISOInspectorTests.swift`

The detection rule operates on an already-mounted root directory (pure, testable).

- [ ] **Step 1: Write the failing test** in `Tests/WindowsMediaTests/ISOInspectorTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class ISOInspectorTests: XCTestCase {
    private func makeTree(_ files: [String: Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString)")
        for (rel, size) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return root
    }

    func testDetectsWindowsByInstallWimAndEfiBoot() throws {
        let root = try makeTree(["sources/install.wim": 1000, "efi/boot/bootx64.efi": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertTrue(d.isWindows)
        XCTAssertEqual(d.installImageRelPath, "sources/install.wim")
        XCTAssertEqual(d.installImageSizeBytes, 1000)
    }

    func testDetectsInstallEsd() throws {
        let root = try makeTree(["sources/install.esd": 500, "efi/boot/bootx64.efi": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertTrue(d.isWindows)
        XCTAssertEqual(d.installImageRelPath, "sources/install.esd")
    }

    func testNonWindowsTreeIsNotDetected() throws {
        let root = try makeTree(["casper/vmlinuz": 10, "boot/grub/grub.cfg": 10])
        defer { try? FileManager.default.removeItem(at: root) }
        let d = ISOInspector.detectWindows(atMountedRoot: root.path)
        XCTAssertFalse(d.isWindows)
        XCTAssertNil(d.installImageRelPath)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ISOInspectorTests` → FAIL.

- [ ] **Step 3: Implement** `Sources/WindowsMedia/ISOInspector.swift`

```swift
import Foundation

public struct ISOInfo: Sendable {
    public let isWindows: Bool
    public let installImageRelPath: String?   // e.g. "sources/install.wim"
    public let installImageSizeBytes: UInt64
    public let mountPoint: String
}

public enum ISOInspectorError: Error, CustomStringConvertible {
    case mountFailed(String)
    public var description: String {
        switch self { case .mountFailed(let s): return "Failed to mount ISO: \(s)" }
    }
}

public struct ISOInspector {
    let runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }

    public struct Detection { public let isWindows: Bool
        public let installImageRelPath: String?; public let installImageSizeBytes: UInt64 }

    /// Pure detection over a mounted root. Windows = an install image under sources/ AND a
    /// UEFI boot file. Case-insensitive on the well-known names.
    public static func detectWindows(atMountedRoot root: String) -> Detection {
        let fm = FileManager.default
        func size(_ rel: String) -> UInt64? {
            let p = (root as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: p) else { return nil }
            return ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.uint64Value
        }
        let hasEfiBoot = fm.fileExists(atPath: (root as NSString).appendingPathComponent("efi/boot/bootx64.efi"))
            || fm.fileExists(atPath: (root as NSString).appendingPathComponent("efi/microsoft/boot/bootmgfw.efi"))
            || fm.fileExists(atPath: (root as NSString).appendingPathComponent("bootmgr.efi"))
        for rel in ["sources/install.wim", "sources/install.esd"] {
            if let s = size(rel), hasEfiBoot {
                return Detection(isWindows: true, installImageRelPath: rel, installImageSizeBytes: s)
            }
        }
        return Detection(isWindows: false, installImageRelPath: nil, installImageSizeBytes: 0)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ISOInspectorTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowsMedia/ISOInspector.swift Tests/WindowsMediaTests/ISOInspectorTests.swift
git commit -m "feat: ISOInspector Windows-detection logic (install.wim/esd + UEFI boot)"
```

---

## Task 5: ISOInspector — mount/detach via hdiutil (+ synthesized-ISO spike)

**Files:**
- Modify: `Sources/WindowsMedia/ISOInspector.swift` (add `mountAndInspect` / `detach`)
- Create: `Tests/WindowsMediaTests/ISOMountIntegrationTests.swift`

- [ ] **Step 1: Add mount/detach** to `ISOInspector`

```swift
extension ISOInspector {
    /// Attach the ISO read-only and run detection at its mount point.
    public func mountAndInspect(isoPath: String) throws -> ISOInfo {
        // `hdiutil attach -nobrowse -readonly -plist` → parse mount-point from plist.
        let r = try runner.run("/usr/bin/hdiutil",
                               ["attach", "-nobrowse", "-readonly", "-plist", isoPath])
        guard r.status == 0 else { throw ISOInspectorError.mountFailed(r.stderr) }
        guard let mp = Self.firstMountPoint(fromPlist: r.stdout) else {
            throw ISOInspectorError.mountFailed("no mount-point in hdiutil output")
        }
        let d = Self.detectWindows(atMountedRoot: mp)
        return ISOInfo(isWindows: d.isWindows, installImageRelPath: d.installImageRelPath,
                       installImageSizeBytes: d.installImageSizeBytes, mountPoint: mp)
    }

    public func detach(mountPoint: String) {
        _ = try? runner.run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
    }

    /// Parse the first `mount-point` value from `hdiutil attach -plist` output.
    static func firstMountPoint(fromPlist plist: String) -> String? {
        guard let data = plist.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        for e in entities { if let mp = e["mount-point"] as? String, !mp.isEmpty { return mp } }
        return nil
    }
}
```

- [ ] **Step 2: Write the integration test** in `Tests/WindowsMediaTests/ISOMountIntegrationTests.swift`

Synthesize a tiny "Windows-like" ISO with `hdiutil makehybrid` from a dir, then inspect it.

```swift
import XCTest
@testable import WindowsMedia

final class ISOMountIntegrationTests: XCTestCase {
    func testMountAndDetectSynthesizedWindowsISO() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("winiso-\(UUID().uuidString)")
        let root = work.appendingPathComponent("root")
        try fm.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("sources/install.wim"))
        try Data(count: 16).write(to: root.appendingPathComponent("efi/boot/bootx64.efi"))
        defer { try? fm.removeItem(at: work) }

        let iso = work.appendingPathComponent("win.iso")
        let runner = SystemProcessRunner()
        let mk = try runner.run("/usr/bin/hdiutil",
            ["makehybrid", "-iso", "-udf", "-o", iso.path, root.path])
        XCTAssertEqual(mk.status, 0, mk.stderr)
        // hdiutil may append .iso/.cdr; resolve actual path.
        let isoPath = fm.fileExists(atPath: iso.path) ? iso.path : iso.path + ".cdr"

        let inspector = ISOInspector(runner: runner)
        let info = try inspector.mountAndInspect(isoPath: isoPath)
        defer { inspector.detach(mountPoint: info.mountPoint) }
        XCTAssertTrue(info.isWindows)
        XCTAssertEqual(info.installImageRelPath, "sources/install.wim")
    }
}
```

- [ ] **Step 3: Run**

Run: `swift test --filter ISOMountIntegrationTests`
Expected: PASS. If `makehybrid` path handling differs, adjust `isoPath` resolution and report. Ensure no leftover `/Volumes` mounts (the `defer` detaches).

- [ ] **Step 4: Commit**

```bash
git add Sources/WindowsMedia/ISOInspector.swift Tests/WindowsMediaTests/ISOMountIntegrationTests.swift
git commit -m "feat: ISOInspector mount/detach via hdiutil; detect synthesized Windows ISO"
```

**✅ Milestone 2 complete:** Windows ISO detection works on a real mounted image.

---

## Task 6: Win11Bypass — appraiserres + autounattend (pure, TDD)

**Files:**
- Create: `Sources/WindowsMedia/Win11Bypass.swift`
- Create: `Tests/WindowsMediaTests/Win11BypassTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/WindowsMediaTests/Win11BypassTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class Win11BypassTests: XCTestCase {
    func testZeroesAppraiserAndWritesAutounattend() throws {
        let fm = FileManager.default
        let usb = fm.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString)")
        try fm.createDirectory(at: usb.appendingPathComponent("sources"), withIntermediateDirectories: true)
        // pre-existing non-empty appraiserres.dll
        try Data(count: 5000).write(to: usb.appendingPathComponent("sources/appraiserres.dll"))
        defer { try? fm.removeItem(at: usb) }

        try Win11Bypass.apply(usbRoot: usb.path)

        let appraiser = usb.appendingPathComponent("sources/appraiserres.dll").path
        XCTAssertEqual(((try? fm.attributesOfItem(atPath: appraiser))?[.size] as? NSNumber)?.intValue, 0)
        let autoun = usb.appendingPathComponent("autounattend.xml").path
        let xml = try String(contentsOfFile: autoun, encoding: .utf8)
        XCTAssertTrue(xml.contains("BypassTPMCheck"))
        XCTAssertTrue(xml.contains("BypassSecureBootCheck"))
    }

    func testNoAppraiserStillWritesAutounattend() throws {
        let fm = FileManager.default
        let usb = fm.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: usb) }
        XCTAssertNoThrow(try Win11Bypass.apply(usbRoot: usb.path))
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("autounattend.xml").path))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Win11BypassTests` → FAIL.

- [ ] **Step 3: Implement** `Sources/WindowsMedia/Win11Bypass.swift`

```swift
import Foundation

/// Applies the Windows 11 hardware-check bypass to an already-populated USB volume:
/// 1) zero `sources/appraiserres.dll` (disables the compatibility appraiser), and
/// 2) drop an `autounattend.xml` with LabConfig bypass keys for the Setup checks.
public enum Win11Bypass {
    public static func apply(usbRoot: String) throws {
        let fm = FileManager.default
        let appraiser = (usbRoot as NSString).appendingPathComponent("sources/appraiserres.dll")
        if fm.fileExists(atPath: appraiser) {
            try Data().write(to: URL(fileURLWithPath: appraiser))   // truncate to 0 bytes
        }
        let autoun = (usbRoot as NSString).appendingPathComponent("autounattend.xml")
        try autounattendXML.write(toFile: autoun, atomically: true, encoding: .utf8)
    }

    static let autounattendXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add"><Order>1</Order>
              <Path>reg add HKLM\\\\SYSTEM\\\\Setup\\\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>2</Order>
              <Path>reg add HKLM\\\\SYSTEM\\\\Setup\\\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>3</Order>
              <Path>reg add HKLM\\\\SYSTEM\\\\Setup\\\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>4</Order>
              <Path>reg add HKLM\\\\SYSTEM\\\\Setup\\\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>
    """
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter Win11BypassTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowsMedia/Win11Bypass.swift Tests/WindowsMediaTests/Win11BypassTests.swift
git commit -m "feat: Win11 bypass (zero appraiserres.dll + autounattend LabConfig)"
```

**✅ Milestone 3 complete.**

---

## Task 7: WindowsUSBWriter — orchestration (unit via fake runner)

**Files:**
- Create: `Sources/WindowsMedia/WindowsUSBWriter.swift`
- Create: `Tests/WindowsMediaTests/WindowsUSBWriterTests.swift`

This task builds the orchestration and asserts the **command sequence** with a fake runner and a fake filesystem layout. Real device I/O is Task 9.

- [ ] **Step 1: Write the failing test** in `Tests/WindowsMediaTests/WindowsUSBWriterTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class WindowsUSBWriterTests: XCTestCase {
    func testFormatsThenInvokesSplitForLargeWim() throws {
        // Arrange a fake mounted ISO with a >4000MB install.wim (sparse: report size via attrs).
        let fm = FileManager.default
        let iso = fm.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        // create a sparse 4.1 GB file (no real bytes)
        let wim = iso.appendingPathComponent("sources/install.wim")
        fm.createFile(atPath: wim.path, contents: nil)
        let fh = try FileHandle(forWritingTo: wim); try fh.truncate(atOffset: 4_100 * 1024 * 1024); try fh.close()
        try Data(count: 10).write(to: iso.appendingPathComponent("setup.exe"))
        let usb = fm.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iso); try? fm.removeItem(at: usb) }

        let fake = FakeRunner()
        let writer = WindowsUSBWriter(runner: fake,
                                      wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        var phases: [String] = []
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: 4_100 * 1024 * 1024,
                                progress: { phase, _ in if phases.last != phase { phases.append(phase) } })

        // setup.exe copied; install.wim NOT copied; split invoked into usb/sources/install.swm
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("setup.exe").path))
        XCTAssertFalse(fm.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
        XCTAssertTrue(fake.calls.contains { $0.0 == "/x/wimlib-imagex" && $0.1.first == "split"
            && $0.1[2].hasSuffix("sources/install.swm") })
        XCTAssertEqual(phases, ["copying", "splitting"])
    }

    func testCopiesWimDirectlyWhenSmall() throws {
        let fm = FileManager.default
        let iso = fm.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(count: 2048).write(to: iso.appendingPathComponent("sources/install.wim"))
        let usb = fm.temporaryDirectory.appendingPathComponent("u-\(UUID().uuidString)")
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iso); try? fm.removeItem(at: usb) }

        let fake = FakeRunner()
        let writer = WindowsUSBWriter(runner: fake, wim: WimTool(runner: fake, imagexPath: "/x/wimlib-imagex"))
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: usb.path,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: 2048, progress: { _, _ in })
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
        XCTAssertFalse(fake.calls.contains { $0.1.first == "split" })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WindowsUSBWriterTests` → FAIL.

- [ ] **Step 3: Implement** `Sources/WindowsMedia/WindowsUSBWriter.swift`

```swift
import Foundation

public final class WindowsUSBWriter {
    public enum Phase: String { case formatting, copying, splitting, bypassing }
    let runner: ProcessRunner
    let wim: WimTool
    /// install.wim larger than this (bytes) is split for FAT32. 4000 MB.
    let splitThreshold: UInt64 = 4000 * 1024 * 1024

    public init(runner: ProcessRunner, wim: WimTool) { self.runner = runner; self.wim = wim }

    /// Format the whole disk as GPT + a single FAT32 volume named `volumeName`.
    public func format(bsdName: String, volumeName: String) throws {
        let r = try runner.run("/usr/sbin/diskutil",
                               ["eraseDisk", "MS-DOS", volumeName, "GPT", "/dev/\(bsdName)"])
        if r.status != 0 {
            throw WimToolError(message: "diskutil eraseDisk failed (\(r.status)): \(r.stderr)")
        }
    }

    /// Copy ISO contents to the mounted USB, splitting install.wim when oversized.
    /// `progress(phase, fraction)`; phases: "copying" then (if split) "splitting".
    public func copyAndSplit(mountedISORoot: String, usbMountPoint: String,
                             installImageRelPath: String, installImageSizeBytes: UInt64,
                             progress: (String, Double) -> Void) throws {
        let fm = FileManager.default
        let willSplit = installImageSizeBytes > splitThreshold
            && installImageRelPath.hasSuffix("install.wim")

        // Total bytes to copy (skip the wim if it will be split).
        let entries = try Self.fileList(root: mountedISORoot)
        var total: UInt64 = 0
        for e in entries where !(willSplit && e.rel == installImageRelPath) { total += e.size }
        var done: UInt64 = 0

        progress("copying", 0)
        for e in entries {
            if willSplit && e.rel == installImageRelPath { continue } // split later
            let dst = (usbMountPoint as NSString).appendingPathComponent(e.rel)
            try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.copyItem(atPath: (mountedISORoot as NSString).appendingPathComponent(e.rel), toPath: dst)
            done += e.size
            progress("copying", total == 0 ? 1 : Double(done) / Double(total))
        }

        if willSplit {
            progress("splitting", 0)
            let srcWim = (mountedISORoot as NSString).appendingPathComponent(installImageRelPath)
            let outDir = (usbMountPoint as NSString).appendingPathComponent("sources")
            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let outSWM = (outDir as NSString).appendingPathComponent("install.swm")
            try wim.split(wim: srcWim, outFirstSWM: outSWM, chunkMB: 4000)
            progress("splitting", 1)
        }
    }

    struct Entry { let rel: String; let size: UInt64 }
    /// Recursively list files (relative paths) and sizes under `root`.
    static func fileList(root: String) throws -> [Entry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [Entry] = []
        for case let rel as String in en {
            let full = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.uint64Value ?? 0
            out.append(Entry(rel: rel, size: size))
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WindowsUSBWriterTests` → PASS (both tests). Then full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowsMedia/WindowsUSBWriter.swift Tests/WindowsMediaTests/WindowsUSBWriterTests.swift
git commit -m "feat: WindowsUSBWriter copy+split orchestration (format, copy, split)"
```

---

## Task 8: diskutil format SPIKE (no-sudo on external media)

**Files:**
- Create: `Tests/WindowsMediaTests/DiskutilFormatSpikeTests.swift`

Validate the privilege assumption: `diskutil eraseDisk MS-DOS … GPT` on an external-like device works **without sudo**, using an `hdiutil`-attached image (which is owned by the user).

- [ ] **Step 1: Write the spike test** in `Tests/WindowsMediaTests/DiskutilFormatSpikeTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class DiskutilFormatSpikeTests: XCTestCase {
    func testFormatFat32OnAttachedImageWithoutSudo() throws {
        let fm = FileManager.default
        let img = fm.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).img")
        fm.createFile(atPath: img.path, contents: nil)
        let fh = try FileHandle(forWritingTo: img); try fh.truncate(atOffset: 256 * 1024 * 1024); try fh.close()
        defer { try? fm.removeItem(at: img) }
        let runner = SystemProcessRunner()

        // Attach without mounting; parse /dev/diskN.
        let att = try runner.run("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", img.path])
        let dev = att.stdout.split(separator: "\n").first?.split(separator: " ").first.map(String.init)
        let bsd = dev.map { String($0.dropFirst("/dev/".count)) }
        guard let bsd else { throw XCTSkip("could not attach image") }
        defer { _ = try? runner.run("/usr/bin/hdiutil", ["detach", "/dev/\(bsd)", "-force"]) }

        let writer = WindowsUSBWriter(runner: runner, wim: WimTool(runner: runner, imagexPath: "/x"))
        // The key question: does this succeed without sudo?
        XCTAssertNoThrow(try writer.format(bsdName: bsd, volumeName: "WIN"))
        // Confirm a FAT volume now exists on the disk.
        let list = try runner.run("/usr/sbin/diskutil", ["list", "/dev/\(bsd)"])
        XCTAssertTrue(list.stdout.contains("Microsoft Basic Data") || list.stdout.uppercased().contains("FAT"),
                      list.stdout)
    }
}
```

- [ ] **Step 2: Run**

Run: `swift test --filter DiskutilFormatSpikeTests`
Expected: PASS → confirms no-sudo format works; the design's privilege assumption holds.
If it FAILS with a permission error, STOP and report: the orchestrator's `format` must then go through an elevation path (reuse `authopen`-style elevation / `osascript` admin running `diskutil`). Document the actual error.

- [ ] **Step 3: Commit**

```bash
git add Tests/WindowsMediaTests/DiskutilFormatSpikeTests.swift
git commit -m "test: spike — diskutil FAT32 format on attached device without sudo"
```

---

## Task 9: End-to-end format+copy integration (hdiutil device)

**Files:**
- Create: `Tests/WindowsMediaTests/FormatCopyIntegrationTests.swift`

- [ ] **Step 1: Write the test** in `Tests/WindowsMediaTests/FormatCopyIntegrationTests.swift`

```swift
import XCTest
@testable import WindowsMedia

final class FormatCopyIntegrationTests: XCTestCase {
    func testFormatThenCopySmallTreeToMountedVolume() throws {
        let fm = FileManager.default
        // Fake "ISO" source tree (small install.wim so no split).
        let iso = fm.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString)")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: iso.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: iso.appendingPathComponent("sources/install.wim"))
        try Data(count: 64).write(to: iso.appendingPathComponent("efi/boot/bootx64.efi"))
        defer { try? fm.removeItem(at: iso) }

        // Attach a 256MB image as the "USB".
        let img = fm.temporaryDirectory.appendingPathComponent("usb-\(UUID().uuidString).img")
        fm.createFile(atPath: img.path, contents: nil)
        let fh = try FileHandle(forWritingTo: img); try fh.truncate(atOffset: 256 * 1024 * 1024); try fh.close()
        defer { try? fm.removeItem(at: img) }
        let runner = SystemProcessRunner()
        let att = try runner.run("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", img.path])
        guard let dev = att.stdout.split(separator: "\n").first?.split(separator: " ").first.map(String.init)
        else { throw XCTSkip("attach failed") }
        let bsd = String(dev.dropFirst("/dev/".count))
        defer { _ = try? runner.run("/usr/bin/hdiutil", ["detach", "/dev/\(bsd)", "-force"]) }

        let writer = WindowsUSBWriter(runner: runner, wim: WimTool(runner: runner, imagexPath: "/x"))
        try writer.format(bsdName: bsd, volumeName: "WIN")
        // diskutil mounts the new FAT volume; find its mount point.
        let info = try runner.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsd)s1"])
        let mp = ISOInspector.firstMountPoint(fromPlist: info.stdout)
            ?? "/Volumes/WIN"
        try writer.copyAndSplit(mountedISORoot: iso.path, usbMountPoint: mp,
                                installImageRelPath: "sources/install.wim",
                                installImageSizeBytes: 4096, progress: { _, _ in })
        XCTAssertTrue(fm.fileExists(atPath: (mp as NSString).appendingPathComponent("sources/install.wim")))
        XCTAssertTrue(fm.fileExists(atPath: (mp as NSString).appendingPathComponent("efi/boot/bootx64.efi")))
    }
}
```

- [ ] **Step 2: Run**

Run: `swift test --filter FormatCopyIntegrationTests`
Expected: PASS. If the `diskutil info -plist /dev/<bsd>s1` mount-point parse differs, adjust to read `MountPoint` from the plist and report. Clean up: the `defer` detaches; verify no leftover `/Volumes/WIN`.

- [ ] **Step 3: Commit**

```bash
git add Tests/WindowsMediaTests/FormatCopyIntegrationTests.swift
git commit -m "test: end-to-end format+copy to a mounted FAT32 volume (hdiutil device)"
```

**✅ Milestone 4 complete:** format + copy + split proven end-to-end, unprivileged.

---

## Task 10: App — WindowsWriter (drives WindowsUSBWriter off-main)

**Files:**
- Create: `App/WindowsWriter.swift`

- [ ] **Step 1: Implement** `App/WindowsWriter.swift`

```swift
import Foundation
import Combine
import WindowsMedia
import DiskDiscovery

@MainActor
final class WindowsWriter: NSObject, ObservableObject {
    @Published var phase: String = ""
    @Published var fraction: Double = 0
    @Published var finished: Bool = false
    @Published var isRunning: Bool = false
    @Published var errorText: String?

    func start(isoPath: String, bsdName: String, bypassWin11: Bool) {
        phase = "preparing"; fraction = 0; finished = false; isRunning = true; errorText = nil
        Task.detached { [weak self] in await self?.run(isoPath: isoPath, bsdName: bsdName, bypassWin11: bypassWin11) }
    }

    private nonisolated func set(_ phase: String, _ fraction: Double) async {
        await MainActor.run { self.phase = phase; self.fraction = fraction }
    }
    private nonisolated func fail(_ m: String) async {
        await MainActor.run { self.errorText = m; self.finished = true; self.isRunning = false }
    }

    private nonisolated func run(isoPath: String, bsdName: String, bypassWin11: Bool) async {
        let runner = SystemProcessRunner()
        let inspector = ISOInspector(runner: runner)
        let bundledDir = Bundle.main.resourceURL?.appendingPathComponent("wimlib").path
        guard let imagex = WimTool.locateImagex(bundledDir: bundledDir) else {
            await fail("Bundled wimlib-imagex not found."); return
        }
        let writer = WindowsUSBWriter(runner: runner, wim: WimTool(runner: runner, imagexPath: imagex))
        do {
            let info = try inspector.mountAndInspect(isoPath: isoPath)
            defer { inspector.detach(mountPoint: info.mountPoint) }
            guard info.isWindows, let rel = info.installImageRelPath else {
                await fail("Not a Windows ISO."); return
            }
            await set("formatting", 0)
            try writer.format(bsdName: bsdName, volumeName: "WIN")
            // diskutil mounts /dev/<bsd>s1 as the new volume.
            let pinfo = try runner.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsdName)s1"])
            guard let mp = ISOInspector.firstMountPoint(fromPlist: pinfo.stdout) else {
                await fail("Could not locate the formatted volume."); return
            }
            try writer.copyAndSplit(mountedISORoot: info.mountPoint, usbMountPoint: mp,
                                    installImageRelPath: rel,
                                    installImageSizeBytes: info.installImageSizeBytes,
                                    progress: { ph, fr in Task { await self.set(ph, fr) } })
            if bypassWin11 {
                await set("bypassing", 1)
                try Win11Bypass.apply(usbRoot: mp)
            }
            _ = try? runner.run("/usr/sbin/diskutil", ["eject", "/dev/\(bsdName)"])
            await MainActor.run { self.fraction = 1; self.finished = true; self.isRunning = false }
        } catch {
            await fail("\(error)")
        }
    }
}
```

- [ ] **Step 2: Commit** (builds with the app in Task 11)

```bash
git add App/WindowsWriter.swift
git commit -m "feat: app WindowsWriter drives the Windows USB build off-main"
```

---

## Task 11: App — detect Windows ISO in ImageSelection

**Files:**
- Modify: `App/ImageSelection.swift`

- [ ] **Step 1: Add Windows detection** to `ImageSelection`

Add `import WindowsMedia` and a published flag; detect during `computeHash()` (already async/off-main):

```swift
    @Published var isWindows = false
```
At the end of `computeHash()` (after the hash is computed), add:
```swift
        let detected: Bool = await Task.detached {
            guard let url = await self.imageURL else { return false }
            let inspector = ISOInspector(runner: SystemProcessRunner())
            guard let info = try? inspector.mountAndInspect(isoPath: url.path) else { return false }
            defer { inspector.detach(mountPoint: info.mountPoint) }
            return info.isWindows
        }.value
        isWindows = detected
```
(If accessing `self.imageURL` from the detached task triggers Swift 6 isolation issues, capture `imageURL` into a local `let url = imageURL` on the main actor before the `Task.detached` and use that.)

- [ ] **Step 2: Build-verify**

Run: `xcodegen generate && xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **` (after Task 12 wires the project dep; if RufusApp doesn't yet depend on WindowsMedia, do Task 12 Step 1 first).

- [ ] **Step 3: Commit**

```bash
git add App/ImageSelection.swift
git commit -m "feat: detect Windows ISO on image selection"
```

---

## Task 12: App — Windows UI section + project dependency

**Files:**
- Modify: `project.yml` (RufusApp depends on `WindowsMedia`)
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Add the dependency** in `project.yml` under `RufusApp` `dependencies:`

```yaml
      - package: RufusPkg
        product: WindowsMedia
```
Then `xcodegen generate`.

- [ ] **Step 2: Add Windows UI** to `ContentView.swift`

Add state + writer:
```swift
    @StateObject private var winWriter = WindowsWriter()
    @AppStorage("bypassWin11") private var bypassWin11 = true
```
After the "Target disk" field, add a Windows-only section:
```swift
            if image.isWindows {
                field(title: "Windows install media", systemImage: "window.shade.closed") {
                    Toggle("Bypass Windows 11 compatibility checks", isOn: $bypassWin11)
                        .toggleStyle(.checkbox).font(.callout)
                }
            }
```
Make the status row observe whichever writer is active. Add a computed `active` writer state. Simplest: route `startWrite()`:
```swift
    private func startWrite() {
        guard let url = image.imageURL, let disk = diskVM.selected else { return }
        if image.isWindows {
            winWriter.start(isoPath: url.path, bsdName: disk.bsdName, bypassWin11: bypassWin11)
        } else if let hash = image.sha256Base64 {
            writer.startWrite(imagePath: url.path, bsdName: disk.bsdName, sha256Base64: hash, verify: verifyAfterWrite)
        }
    }
```
Update the status block + Write `disabled` to consider `image.isWindows` (Windows path doesn't require `sha256Base64`). Replace the `statusRow` source and `canWrite`:
```swift
    private var activePhase: String { image.isWindows ? winWriter.phase : writer.phase }
    private var activeFraction: Double { image.isWindows ? winWriter.fraction : writer.fraction }
    private var activeFinished: Bool { image.isWindows ? winWriter.finished : writer.finished }
    private var activeError: String? { image.isWindows ? winWriter.errorText : writer.errorText }
    private var activeRunning: Bool { image.isWindows ? winWriter.isRunning : writer.isRunning }
```
and update `canWrite`:
```swift
    private var canWrite: Bool {
        guard image.imageURL != nil, let disk = diskVM.selected, !activeRunning else { return false }
        if image.imageSize > 0 && !image.fits(disk: disk) { return false }
        return image.isWindows ? true : (image.sha256Base64 != nil)
    }
```
and change `statusRow`/the progress `if` to use the `active*` accessors instead of `writer.*`. Also hide the "Verify after writing" toggle when `image.isWindows` (verification there is wim-split, not applicable):
```swift
            if !image.isWindows {
                Toggle("Verify after writing", isOn: $verifyAfterWrite)
                    .toggleStyle(.checkbox).font(.callout).disabled(activeRunning)
            }
```

- [ ] **Step 3: Build-verify + run**

Run: `xcodegen generate && xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. Launch; confirm a Linux ISO still shows the raw/DD flow and (with a Windows ISO) the Windows section appears.

- [ ] **Step 4: Commit**

```bash
git add project.yml rufus4mac.xcodeproj/project.pbxproj App/ContentView.swift
git commit -m "feat: Windows UI section + route Windows ISOs to WindowsWriter"
```

**✅ Milestone 5 complete.**

---

## Task 13: Bundle wimlib-imagex + packaging

**Files:**
- Modify: `scripts/build-dmg.sh` (collect + bundle wimlib)
- Create: `scripts/bundle-wimlib.sh`

- [ ] **Step 1: Write** `scripts/bundle-wimlib.sh` — copies the Homebrew `wimlib-imagex` and its `libwim` dylib into a target `Resources/wimlib/` and rewrites the dylib path with `install_name_tool` so the bundled binary is self-contained.

```bash
#!/usr/bin/env bash
# Copy wimlib-imagex + its libwim dylib into <app>/Contents/Resources/wimlib and
# rewrite the link path so the bundled binary needs no Homebrew.
set -euo pipefail
DEST="${1:?usage: bundle-wimlib.sh <RufusApp.app/Contents/Resources/wimlib>}"
SRC="$(command -v wimlib-imagex || echo /opt/homebrew/bin/wimlib-imagex)"
[ -x "$SRC" ] || { echo "wimlib-imagex not found; brew install wimlib"; exit 1; }
mkdir -p "$DEST"
cp "$SRC" "$DEST/wimlib-imagex"
# find the libwim dylib it links to
LIB=$(otool -L "$DEST/wimlib-imagex" | awk '/libwim/{print $1; exit}')
if [ -n "${LIB:-}" ] && [ -f "$LIB" ]; then
  cp "$LIB" "$DEST/"
  BASE=$(basename "$LIB")
  install_name_tool -change "$LIB" "@executable_path/$BASE" "$DEST/wimlib-imagex"
fi
echo "bundled wimlib into $DEST"
```

- [ ] **Step 2: Hook into `scripts/build-dmg.sh`** — after the app is built and before signing, call:
```bash
bash scripts/bundle-wimlib.sh "$APP/Contents/Resources/wimlib"
```
(The deep `codesign` of `$APP` then covers the bundled binary + dylib.)

- [ ] **Step 3: Manual verify** — run `bash scripts/bundle-wimlib.sh /tmp/wlt && /tmp/wlt/wimlib-imagex --version` to confirm the relocated binary runs without Homebrew on PATH. Report the version.

- [ ] **Step 4: Commit**

```bash
git add scripts/bundle-wimlib.sh scripts/build-dmg.sh
git commit -m "chore: bundle relocatable wimlib-imagex into the app for distribution"
```

---

## Task 14: Docs — manual checklist + README/roadmap

**Files:**
- Modify: `docs/manual-test-checklist.md`
- Modify: `README.md`

- [ ] **Step 1: Add a Phase 2 section** to `docs/manual-test-checklist.md`:

```markdown
## Phase 2 — Windows install USB (manual)
Prereqs: a Windows 10/11 ISO, an expendable ≥8 GB USB, `wimlib` available.
1. [ ] Select the Windows ISO → the "Windows install media" section appears.
2. [ ] Leave "Bypass Windows 11 compatibility checks" on (for Win11 hardware).
3. [ ] Pick the USB → Write → confirm. Watch Formatting → Copying → Splitting (if wim>4GB) → (Bypassing) → Done.
4. [ ] The USB has a FAT32 volume with /sources/install.swm (or install.wim) + /efi/boot/bootx64.efi.
5. [ ] Boot a UEFI PC from it; Windows Setup starts. On Win11-incompatible hardware, setup proceeds past the compatibility check.
```

- [ ] **Step 2: Update `README.md`** — mark Phase 2 in the roadmap as in progress / done, and add a one-line note that Windows ISOs are auto-detected and written as FAT32 + split install.wim via bundled wimlib, with an optional Win11 bypass.

- [ ] **Step 3: Commit**

```bash
git add docs/manual-test-checklist.md README.md
git commit -m "docs: Phase 2 manual checklist + README roadmap update"
```

**✅ Milestone 6 complete.**

---

## Self-Review Notes (addressed)
- **Spec coverage:** detection (Tasks 4–5, 11), GPT/FAT32 format (Tasks 7–8), copy + install.wim split (Tasks 2–3, 7, 9), Win11 bypass (Task 6, 12), wimlib bundle + LGPL note (Tasks 13–14), privilege spike (Task 8), UI routing/Windows section (Tasks 10–12), error handling (throws surfaced through `WindowsWriter.fail`), testing (every logic unit has unit tests; wimlib/diskutil/hdiutil have integration spikes).
- **Privilege assumption** is explicitly spiked (Task 8) with a documented fallback (elevation) if it fails — not assumed silently.
- **Type consistency:** `ProcessResult{status,stdout,stderr}`, `ProcessRunner.run(_:_:)`, `WimTool(runner:imagexPath:)`/`split(wim:outFirstSWM:chunkMB:)`/`locateImagex(bundledDir:)`, `ISOInspector(runner:)`/`detectWindows(atMountedRoot:)`/`mountAndInspect(isoPath:)`/`detach(mountPoint:)`/`firstMountPoint(fromPlist:)`, `Win11Bypass.apply(usbRoot:)`, `WindowsUSBWriter(runner:wim:)`/`format(bsdName:volumeName:)`/`copyAndSplit(...)`, `WindowsWriter.start(isoPath:bsdName:bypassWin11:)` used consistently across tasks.
- **Known deferral:** Windows-mode write has no read-back verification (the source is split, not byte-identical); the "Verify after writing" toggle is hidden for Windows ISOs. Bootability is covered by the manual checklist.
