# rufus4mac Phase 3 Implementation Plan (Format Options / Format-only)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Rufus-style format options (partition scheme, file system, volume label) and a format-only action that erases + formats a USB via `diskutil` when no image is selected.

**Architecture:** Extract the generic `ProcessRunner` into a shared `SystemTools` SPM module; add a `DiskFormat` module (`FormatOptions` + `DiskFormatter` driving `diskutil eraseDisk`); add a SwiftUI `FormatRunner` and format-options UI that routes to format-only when no image is chosen (existing raw/DD and Windows write paths are unchanged, with options hidden for them).

**Tech Stack:** Swift 6.2, SPM, `diskutil` (built-in; FAT32/exFAT native — zero new deps), SwiftUI, xcodegen. Spec: `docs/superpowers/specs/2026-06-01-rufus4mac-phase3-format-design.md`.

**Key facts:**
- `diskutil eraseDisk <personality> <label> <scheme> /dev/<bsd>` — exFAT→`ExFAT`, FAT32→`MS-DOS FAT32`; scheme→`GPT`/`MBR`. No `sudo` for removable media (verified in Phase 2).
- Label is normalized (uppercase, `A–Z 0–9` only, length cap FAT32≤11 / exFAT≤15, empty→`RUFUS4MAC`).
- Existing 43 tests must stay green through the `ProcessRunner` extraction.

---

## Milestones
1. **M1 — Shared infra:** extract `SystemTools` (ProcessRunner), keep all tests green. Task 1.
2. **M2 — Format logic:** `FormatOptions` + `DiskFormatter`, TDD + integration spike. Tasks 2–4.
3. **M3 — App:** `FormatRunner` + format-options UI + routing (build-verified). Tasks 5–6.
4. **M4 — Docs.** Task 7.

---

## File Structure
```
Sources/SystemTools/ProcessRunner.swift   # moved from WindowsMedia (ProcessRunner/ProcessResult/SystemProcessRunner)
Sources/DiskFormat/FormatOptions.swift     # PartitionScheme, FileSystem, label normalization
Sources/DiskFormat/DiskFormatter.swift     # format(bsdName:options:) via diskutil
Tests/SystemToolsTests/ProcessRunnerTests.swift   # moved from WindowsMediaTests
Tests/DiskFormatTests/FormatOptionsTests.swift
Tests/DiskFormatTests/DiskFormatterTests.swift
Tests/DiskFormatTests/DiskFormatIntegrationTests.swift
App/FormatRunner.swift                     # @MainActor observable driving DiskFormatter
App/ContentView.swift, project.yml         # format-options UI + dependency (modified)
Package.swift                              # SystemTools + DiskFormat targets/products (modified)
Sources/WindowsMedia/*.swift               # `import SystemTools` (modified)
```

---

## Task 1: Extract `ProcessRunner` into a shared `SystemTools` module

**Files:**
- Create: `Sources/SystemTools/ProcessRunner.swift` (moved content)
- Delete: `Sources/WindowsMedia/ProcessRunner.swift`
- Move: `Tests/WindowsMediaTests/ProcessRunnerTests.swift` → `Tests/SystemToolsTests/ProcessRunnerTests.swift`
- Modify: `Package.swift`, several `Sources/WindowsMedia/*.swift` + `Tests/WindowsMediaTests/*.swift` (add `import SystemTools`)

- [ ] **Step 1: Add `SystemTools` to `Package.swift`**

In `products:` add:
```swift
        .library(name: "SystemTools", targets: ["SystemTools"]),
```
In `targets:` add the target + test target, and make `WindowsMedia` (and its tests) depend on `SystemTools`:
```swift
        .target(name: "SystemTools"),
        .target(name: "WindowsMedia", dependencies: ["SystemTools"]),
        .testTarget(name: "SystemToolsTests", dependencies: ["SystemTools"]),
```
And update the existing `WindowsMediaTests` test target to include `SystemTools`:
```swift
        .testTarget(name: "WindowsMediaTests", dependencies: ["WindowsMedia", "SystemTools"]),
```
(Replace the existing `.target(name: "WindowsMedia")` and `.testTarget(name: "WindowsMediaTests", ...)` lines with the versions above. Keep RufusCore, DiskDiscovery, TestSupport and their tests as-is.)

- [ ] **Step 2: Move the source file**

```bash
git mv Sources/WindowsMedia/ProcessRunner.swift Sources/SystemTools/ProcessRunner.swift
mkdir -p Tests/SystemToolsTests
git mv Tests/WindowsMediaTests/ProcessRunnerTests.swift Tests/SystemToolsTests/ProcessRunnerTests.swift
```
The moved `ProcessRunner.swift` content is unchanged (it already only `import Foundation`). In `Tests/SystemToolsTests/ProcessRunnerTests.swift`, change `@testable import WindowsMedia` to `import SystemTools` (it tests `SystemProcessRunner`, which is `public`).

- [ ] **Step 3: Add `import SystemTools` to every WindowsMedia source/test that uses ProcessRunner symbols**

In each of these files, add `import SystemTools` after the existing `import Foundation`/`import XCTest`:
- `Sources/WindowsMedia/WimTool.swift`
- `Sources/WindowsMedia/ISOInspector.swift`
- `Sources/WindowsMedia/WindowsUSBWriter.swift`
- `Tests/WindowsMediaTests/WimToolTests.swift` (defines `FakeRunner: ProcessRunner`, uses `ProcessResult`)
- `Tests/WindowsMediaTests/WimSplitIntegrationTests.swift` (uses `SystemProcessRunner`)
- `Tests/WindowsMediaTests/ISOMountIntegrationTests.swift` (uses `SystemProcessRunner`)
- `Tests/WindowsMediaTests/WindowsUSBWriterTests.swift` (uses `FakeRunner`/`WimTool`)
- `Tests/WindowsMediaTests/DiskutilFormatSpikeTests.swift` (uses `SystemProcessRunner`)
- `Tests/WindowsMediaTests/FormatCopyIntegrationTests.swift` (uses `SystemProcessRunner`)

To be safe, grep first: `grep -rl -E "ProcessRunner|ProcessResult|SystemProcessRunner" Sources/WindowsMedia Tests/WindowsMediaTests` — add `import SystemTools` to every file that the grep lists AND that does not already define those symbols (only the moved file defined them). `ISOInspectorTests.swift` and `Win11BypassTests.swift` likely don't reference the runner — only add the import where a symbol is actually used (otherwise you get an "unused import" — harmless, but keep it clean by only adding where used).

- [ ] **Step 4: Build + full test (regression gate)**

Run: `swift build` then `swift test`
Expected: **43 tests, 0 failures, 0 warnings** (same total, now split across `SystemToolsTests` + `WindowsMediaTests`). If any file errors with "cannot find type 'ProcessRunner'/'ProcessResult'/'SystemProcessRunner'", add `import SystemTools` to it.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: extract ProcessRunner into shared SystemTools module"
```

---

## Task 2: `FormatOptions` + label normalization (pure, TDD)

**Files:**
- Create: `Sources/DiskFormat/FormatOptions.swift`
- Create: `Tests/DiskFormatTests/FormatOptionsTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add the `DiskFormat` target + product to `Package.swift`**

In `products:` add:
```swift
        .library(name: "DiskFormat", targets: ["DiskFormat"]),
```
In `targets:` add:
```swift
        .target(name: "DiskFormat", dependencies: ["SystemTools"]),
        .testTarget(name: "DiskFormatTests", dependencies: ["DiskFormat"]),
```

- [ ] **Step 2: Write the failing test** in `Tests/DiskFormatTests/FormatOptionsTests.swift`

```swift
import XCTest
@testable import DiskFormat

final class FormatOptionsTests: XCTestCase {
    func testUppercasesAndFiltersLabel() {
        let o = FormatOptions(scheme: .gpt, fileSystem: .exfat, label: "my usb! drive")
        XCTAssertEqual(o.normalizedLabel, "MYUSBDRIVE")   // spaces + '!' dropped, uppercased
    }

    func testFat32CapsLabelTo11() {
        let o = FormatOptions(scheme: .mbr, fileSystem: .fat32, label: "ABCDEFGHIJKLMNOP")
        XCTAssertEqual(o.normalizedLabel.count, 11)
        XCTAssertEqual(o.normalizedLabel, "ABCDEFGHIJK")
    }

    func testExfatCapsLabelTo15() {
        let o = FormatOptions(scheme: .gpt, fileSystem: .exfat, label: "ABCDEFGHIJKLMNOPQRST")
        XCTAssertEqual(o.normalizedLabel.count, 15)
    }

    func testEmptyLabelFallsBackToDefault() {
        let o = FormatOptions(scheme: .gpt, fileSystem: .exfat, label: "  !! ")
        XCTAssertEqual(o.normalizedLabel, "RUFUS4MAC")
    }

    func testPersonalityAndSchemeStrings() {
        XCTAssertEqual(FormatOptions.FileSystem.exfat.personality, "ExFAT")
        XCTAssertEqual(FormatOptions.FileSystem.fat32.personality, "MS-DOS FAT32")
        XCTAssertEqual(FormatOptions.PartitionScheme.gpt.rawValue, "GPT")
        XCTAssertEqual(FormatOptions.PartitionScheme.mbr.rawValue, "MBR")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter FormatOptionsTests` → FAIL (no `FormatOptions`).

- [ ] **Step 4: Implement** `Sources/DiskFormat/FormatOptions.swift`

```swift
import Foundation

/// User-chosen formatting parameters for a quick `diskutil` format.
public struct FormatOptions: Sendable, Equatable {
    public enum PartitionScheme: String, Sendable, CaseIterable {
        case mbr = "MBR"
        case gpt = "GPT"
    }
    public enum FileSystem: String, Sendable, CaseIterable {
        case exfat = "exFAT"
        case fat32 = "FAT32"
        /// `diskutil` personality name.
        public var personality: String { self == .exfat ? "ExFAT" : "MS-DOS FAT32" }
        /// Max volume-label length the filesystem allows.
        public var maxLabel: Int { self == .exfat ? 15 : 11 }
    }

    public var scheme: PartitionScheme
    public var fileSystem: FileSystem
    public var label: String

    public init(scheme: PartitionScheme, fileSystem: FileSystem, label: String) {
        self.scheme = scheme; self.fileSystem = fileSystem; self.label = label
    }

    /// Uppercased, `A–Z0–9`-only, length-capped label; falls back to `RUFUS4MAC` when empty.
    public var normalizedLabel: String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var s = String(label.uppercased().unicodeScalars.map { Character($0) }
                        .filter { allowed.contains($0) })
        if s.isEmpty { s = "RUFUS4MAC" }
        return String(s.prefix(fileSystem.maxLabel))
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter FormatOptionsTests` → PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/DiskFormat/FormatOptions.swift Tests/DiskFormatTests/FormatOptionsTests.swift
git commit -m "feat: FormatOptions with diskutil personality mapping + label normalization"
```

---

## Task 3: `DiskFormatter` — build + run the diskutil command (unit via FakeRunner)

**Files:**
- Create: `Sources/DiskFormat/DiskFormatter.swift`
- Create: `Tests/DiskFormatTests/DiskFormatterTests.swift`

- [ ] **Step 1: Write the failing test** in `Tests/DiskFormatTests/DiskFormatterTests.swift`

```swift
import XCTest
import SystemTools
@testable import DiskFormat

private final class FakeRunner: ProcessRunner, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = ProcessResult(status: 0, stdout: "", stderr: "")
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append((executable, arguments)); return result
    }
}

final class DiskFormatterTests: XCTestCase {
    func testExfatGptArgs() throws {
        let fake = FakeRunner()
        let f = DiskFormatter(runner: fake)
        try f.format(bsdName: "disk8", options: .init(scheme: .gpt, fileSystem: .exfat, label: "My USB"))
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].0, "/usr/sbin/diskutil")
        XCTAssertEqual(fake.calls[0].1, ["eraseDisk", "ExFAT", "MYUSB", "GPT", "/dev/disk8"])
    }

    func testFat32MbrArgs() throws {
        let fake = FakeRunner()
        let f = DiskFormatter(runner: fake)
        try f.format(bsdName: "disk5", options: .init(scheme: .mbr, fileSystem: .fat32, label: ""))
        XCTAssertEqual(fake.calls[0].1, ["eraseDisk", "MS-DOS FAT32", "RUFUS4MAC", "MBR", "/dev/disk5"])
    }

    func testThrowsOnNonZeroStatus() {
        let fake = FakeRunner(); fake.result = ProcessResult(status: 1, stdout: "", stderr: "busy")
        let f = DiskFormatter(runner: fake)
        XCTAssertThrowsError(try f.format(bsdName: "disk8",
                                          options: .init(scheme: .gpt, fileSystem: .exfat, label: "X")))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DiskFormatterTests` → FAIL (no `DiskFormatter`).

- [ ] **Step 3: Implement** `Sources/DiskFormat/DiskFormatter.swift`

```swift
import Foundation
import SystemTools

public struct DiskFormatError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Quick-formats a whole disk via `diskutil eraseDisk`. No `sudo` needed for removable media.
public struct DiskFormatter: Sendable {
    let runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }

    public func format(bsdName: String, options: FormatOptions) throws {
        let r = try runner.run("/usr/sbin/diskutil",
                               ["eraseDisk", options.fileSystem.personality,
                                options.normalizedLabel, options.scheme.rawValue, "/dev/\(bsdName)"])
        if r.status != 0 {
            throw DiskFormatError(message: "diskutil eraseDisk failed (\(r.status)): \(r.stderr)")
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter DiskFormatterTests` → PASS. Then full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DiskFormat/DiskFormatter.swift Tests/DiskFormatTests/DiskFormatterTests.swift
git commit -m "feat: DiskFormatter runs diskutil eraseDisk with mapped personality/scheme/label"
```

---

## Task 4: DiskFormatter integration (hdiutil device, real diskutil)

**Files:**
- Create: `Tests/DiskFormatTests/DiskFormatIntegrationTests.swift`

- [ ] **Step 1: Write the test** in `Tests/DiskFormatTests/DiskFormatIntegrationTests.swift`

```swift
import XCTest
import SystemTools
@testable import DiskFormat

final class DiskFormatIntegrationTests: XCTestCase {
    /// Attach a raw image, format it, and confirm diskutil reports the chosen filesystem.
    private func runFormat(_ options: FormatOptions, expectContains: [String]) throws {
        let fm = FileManager.default
        let img = fm.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).img")
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

        try DiskFormatter(runner: runner).format(bsdName: bsd, options: options)

        let list = try runner.run("/usr/sbin/diskutil", ["list", "/dev/\(bsd)"]).stdout
        for needle in expectContains {
            XCTAssertTrue(list.contains(needle), "expected '\(needle)' in:\n\(list)")
        }
    }

    func testFormatExfatGpt() throws {
        try runFormat(.init(scheme: .gpt, fileSystem: .exfat, label: "EXFATVOL"),
                      expectContains: ["GUID_partition_scheme", "EXFATVOL"])
    }

    func testFormatFat32Mbr() throws {
        try runFormat(.init(scheme: .mbr, fileSystem: .fat32, label: "FATVOL"),
                      expectContains: ["FDisk_partition_scheme", "FATVOL"])
    }
}
```

- [ ] **Step 2: Run**

Run: `swift test --filter DiskFormatIntegrationTests`
Expected: PASS (formats a real attached device, no sudo). NOTE: on a 256 MB image, FAT32 may be reported as FAT16 by `diskutil list` — the test asserts the **scheme** (`FDisk_partition_scheme` for MBR, `GUID_partition_scheme` for GPT) and the **volume label**, not the FAT bit-width, so it's robust to that. `MS-DOS FAT32` on a tiny disk still succeeds; if `diskutil` refuses FAT32 below its minimum size and the test fails, raise the image size to 512 MB and document. Verify cleanup: `defer` detaches; check `hdiutil info` shows no leftover `fmt-*`.

- [ ] **Step 3: Commit**

```bash
git add Tests/DiskFormatTests/DiskFormatIntegrationTests.swift
git commit -m "test: DiskFormatter formats a real hdiutil device (exFAT/GPT, FAT32/MBR)"
```

**✅ Milestone 2 complete.**

---

## Task 5: App — `FormatRunner`

**Files:**
- Create: `App/FormatRunner.swift`

- [ ] **Step 1: Implement** `App/FormatRunner.swift`

```swift
import Foundation
import Combine
import SystemTools
import DiskFormat

@MainActor
final class FormatRunner: NSObject, ObservableObject {
    @Published var phase: String = ""
    @Published var fraction: Double = 0
    @Published var finished: Bool = false
    @Published var isRunning: Bool = false
    @Published var errorText: String?

    func start(bsdName: String, options: FormatOptions) {
        phase = "formatting"; fraction = 0; finished = false; isRunning = true; errorText = nil
        Task.detached { [weak self] in await self?.run(bsdName: bsdName, options: options) }
    }

    private nonisolated func run(bsdName: String, options: FormatOptions) async {
        do {
            try DiskFormatter(runner: SystemProcessRunner()).format(bsdName: bsdName, options: options)
            await MainActor.run { self.fraction = 1; self.finished = true; self.isRunning = false }
        } catch {
            await MainActor.run { self.errorText = "\(error)"; self.finished = true; self.isRunning = false }
        }
    }
}
```

- [ ] **Step 2: Commit** (builds with the app in Task 6)

```bash
git add App/FormatRunner.swift
git commit -m "feat: app FormatRunner drives DiskFormatter off-main"
```

---

## Task 6: App — format-options UI + format-only routing (build-verified)

**Files:**
- Modify: `project.yml` (RufusApp depends on `DiskFormat`)
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Add the dependency** in `project.yml` under `RufusApp` `dependencies:`

```yaml
      - package: RufusPkg
        product: DiskFormat
```
Then `xcodegen generate`.

- [ ] **Step 2: Add state + the format runner** to `ContentView.swift` (near the other `@StateObject`s)

```swift
    @StateObject private var formatRunner = FormatRunner()
    @AppStorage("fmtScheme") private var fmtSchemeRaw = FormatOptions.PartitionScheme.gpt.rawValue
    @AppStorage("fmtFileSystem") private var fmtFSRaw = FormatOptions.FileSystem.exfat.rawValue
    @AppStorage("fmtLabel") private var fmtLabel = "RUFUS4MAC"
```
Add `import DiskFormat` at the top.

- [ ] **Step 3: Add a "format mode" computed flag + a Format-options section**

Add near the other computed props:
```swift
    /// Format-only mode: no image selected → the primary action formats the disk.
    private var formatMode: Bool { image.imageURL == nil }
```
Add this section in the `body` VStack, AFTER the "Target disk" field and BEFORE the Windows section:
```swift
            if formatMode {
                field(title: "Format options", systemImage: "gearshape") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Partition scheme", selection: $fmtSchemeRaw) {
                            ForEach(FormatOptions.PartitionScheme.allCases, id: \.rawValue) {
                                Text($0.rawValue).tag($0.rawValue)
                            }
                        }
                        Picker("File system", selection: $fmtFSRaw) {
                            ForEach(FormatOptions.FileSystem.allCases, id: \.rawValue) {
                                Text($0.rawValue).tag($0.rawValue)
                            }
                        }
                        TextField("Volume label", text: $fmtLabel)
                    }
                }
            }
```

- [ ] **Step 4: Route the primary button** — update the `active*` accessors, `canWrite`, button label, status, and `startWrite()`

Update the active-writer accessors to include the format runner:
```swift
    private var activePhase: String { formatMode ? formatRunner.phase : (image.isWindows ? winWriter.phase : writer.phase) }
    private var activeFraction: Double { formatMode ? formatRunner.fraction : (image.isWindows ? winWriter.fraction : writer.fraction) }
    private var activeFinished: Bool { formatMode ? formatRunner.finished : (image.isWindows ? winWriter.finished : writer.finished) }
    private var activeError: String? { formatMode ? formatRunner.errorText : (image.isWindows ? winWriter.errorText : writer.errorText) }
    private var activeRunning: Bool { formatMode ? formatRunner.isRunning : (image.isWindows ? winWriter.isRunning : writer.isRunning) }
```
Update `canWrite`:
```swift
    private var canWrite: Bool {
        guard let _ = diskVM.selected, !activeRunning, !image.hashing else { return false }
        if formatMode { return true }   // format-only needs only a selected disk
        guard image.imageURL != nil, let disk = diskVM.selected else { return false }
        if image.imageSize > 0 && !image.fits(disk: disk) { return false }
        return image.isWindows ? true : (image.sha256Base64 != nil)
    }
```
Change the primary button label to switch between Format/Write:
```swift
            Button { showConfirm = true } label: {
                Label(formatMode ? "Format" : "Write",
                      systemImage: formatMode ? "eraser" : "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            .disabled(!canWrite)
            .keyboardShortcut(.defaultAction)
```
Update the confirm `.alert` message to cover both cases (keep the title but vary the body):
```swift
        } message: {
            if formatMode {
                Text("Erase and format /dev/\(diskVM.selected?.bsdName ?? "") as \(fmtFSRaw)? All data will be permanently destroyed.")
            } else {
                Text("All data on /dev/\(diskVM.selected?.bsdName ?? "") (\(diskVM.selected?.displaySize ?? "")) will be permanently destroyed.")
            }
        }
```
Route `startWrite()`:
```swift
    private func startWrite() {
        guard let disk = diskVM.selected else { return }
        if formatMode {
            let scheme = FormatOptions.PartitionScheme(rawValue: fmtSchemeRaw) ?? .gpt
            let fs = FormatOptions.FileSystem(rawValue: fmtFSRaw) ?? .exfat
            formatRunner.start(bsdName: disk.bsdName,
                               options: .init(scheme: scheme, fileSystem: fs, label: fmtLabel))
            return
        }
        guard let url = image.imageURL else { return }
        if image.isWindows {
            winWriter.start(isoPath: url.path, bsdName: disk.bsdName, bypassWin11: bypassWin11)
        } else if let hash = image.sha256Base64 {
            writer.startWrite(imagePath: url.path, bsdName: disk.bsdName, sha256Base64: hash, verify: verifyAfterWrite)
        }
    }
```
Also keep the "Verify after writing" toggle hidden in format mode — change its condition from `if !image.isWindows` to `if !image.isWindows && !formatMode`. (The Windows section's `if image.isWindows` already implies not format mode, so it needs no change.)

- [ ] **Step 5: Build-verify + run**

Run: `xcodegen generate && xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -configuration Debug -derivedDataPath build/run -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. Fix any Swift 6 concurrency errors minimally. `swift test` still green. Launch the app: with no image, the Format options section + a "Format" button appear; selecting an image hides them and restores Write.

- [ ] **Step 6: Commit**

```bash
git add project.yml rufus4mac.xcodeproj/project.pbxproj App/ContentView.swift
git commit -m "feat: format-options UI + format-only action when no image selected"
```

**✅ Milestone 3 complete.**

---

## Task 7: Docs

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/manual-test-checklist.md`

- [ ] **Step 1: README roadmap** — mark Phase 3 done and add a one-liner: "Select no image to use **Format mode** — erase a USB as exFAT or FAT32 (MBR/GPT) with a volume label."

- [ ] **Step 2: ARCHITECTURE.md** — under a short "Format mode" note, document: `DiskFormat` module (`FormatOptions`, `DiskFormatter`) runs `diskutil eraseDisk <personality> <label> <scheme>`; `ProcessRunner` now lives in the shared `SystemTools` module; FAT32/exFAT only, no sudo for removable.

- [ ] **Step 3: manual-test-checklist.md** — add a Phase 3 section:
```markdown
## Phase 3 — Format-only (manual)
1. [ ] Launch with NO image selected → the **Format options** section appears (scheme, file system, label) and the button reads **Format**.
2. [ ] Pick a USB, choose exFAT + GPT, set a label → Format → confirm. Status reaches **Done**.
3. [ ] Verify in Disk Utility / `diskutil list`: GPT scheme, exFAT volume with the label.
4. [ ] Repeat with FAT32 + MBR.
5. [ ] Selecting an image hides the Format options and restores the Write flow.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ARCHITECTURE.md docs/manual-test-checklist.md
git commit -m "docs: Phase 3 format mode (README/ARCHITECTURE/checklist)"
```

**✅ Milestone 4 complete.**

---

## Self-Review Notes (addressed)
- **Spec coverage:** SystemTools extraction (Task 1), FormatOptions + label normalization (Task 2), DiskFormatter diskutil mapping (Task 3), integration/no-sudo (Task 4), FormatRunner (Task 5), unified UI + format-only routing + options hidden for image writes (Task 6), docs (Task 7). Error handling surfaced through `DiskFormatError` → `FormatRunner.errorText`. Privilege (no sudo) exercised by Task 4.
- **Placeholder scan:** none — every code step is complete.
- **Type consistency:** `FormatOptions(scheme:fileSystem:label:)`, `.normalizedLabel`, `FileSystem.personality`/`.maxLabel`, `PartitionScheme.rawValue`, `DiskFormatter(runner:)`/`format(bsdName:options:)`, `FormatRunner.start(bsdName:options:)`, `ProcessRunner`/`ProcessResult`/`SystemProcessRunner` (now in SystemTools) used consistently across tasks.
- **Known deferral:** full/zero format, bad-block scan, custom cluster size, NTFS, Mac filesystems — all explicitly out of scope per the spec. Format mode requires only a selected disk (no image).
