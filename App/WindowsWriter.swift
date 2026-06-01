import Foundation
import Combine
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

    /// Parse the top-level `MountPoint` from `diskutil info -plist` output.
    private nonisolated static func mountPoint(fromDiskutilInfoPlist plist: String) -> String? {
        guard let data = plist.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let mp = dict["MountPoint"] as? String, !mp.isEmpty else { return nil }
        return mp
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
            // diskutil mounts /dev/<bsd>s1 as the new FAT volume; read its MountPoint.
            let pinfo = try runner.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsdName)s1"])
            guard let mp = Self.mountPoint(fromDiskutilInfoPlist: pinfo.stdout) else {
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
