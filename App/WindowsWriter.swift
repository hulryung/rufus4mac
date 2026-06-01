import Foundation
import Combine
import SystemTools
import WindowsMedia

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

    /// Find the mount point of the slice whose VolumeName matches `volumeName`, scanning
    /// /dev/<bsd>s1..s6. (diskutil GPT format may place the FAT volume on s1 OR s2 — after
    /// an EFI System Partition — so we can't assume a fixed slice index.)
    private nonisolated static func findVolumeMountPoint(runner: ProcessRunner, bsdName: String,
                                                         volumeName: String) -> String? {
        for i in 1...6 {
            guard let r = try? runner.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsdName)s\(i)"]),
                  r.status == 0,
                  let data = r.stdout.data(using: .utf8),
                  let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { continue }
            if (dict["VolumeName"] as? String) == volumeName,
               let mp = dict["MountPoint"] as? String, !mp.isEmpty {
                return mp
            }
        }
        return nil
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
            guard let mp = Self.findVolumeMountPoint(runner: runner, bsdName: bsdName, volumeName: "WIN") else {
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
