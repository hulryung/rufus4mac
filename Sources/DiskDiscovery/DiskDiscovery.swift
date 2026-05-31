import Foundation
import DiskArbitration
import IOKit

public enum DiskDiscovery {
    /// Enumerate whole disks that are removable/ejectable (USB sticks, SD cards),
    /// excluding internal/system disks. Returns whole-disk entries only (no slices).
    public static func removableDisks() -> [DiskInfo] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }

        var results: [DiskInfo] = []
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

// MARK: - Unmount

public enum UnmountError: Error { case sessionFailed, diskFailed, unmountFailed(String) }

extension DiskDiscovery {
    /// Unmount all volumes on the whole disk identified by `bsdName`.
    /// Blocks until the operation completes (or fails). Safe to call when nothing
    /// is mounted (returns immediately/succeeds).
    public static func unmountDisk(bsdName: String, timeout: TimeInterval = 30) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw UnmountError.sessionFailed }
        let queue = DispatchQueue(label: "rufus4mac.unmount")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw UnmountError.diskFailed
        }

        let box = UnmountBox()
        let ctx = Unmanaged.passUnretained(box).toOpaque()

        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), unmountCallback, ctx)

        if box.sema.wait(timeout: .now() + timeout) == .timedOut {
            throw UnmountError.unmountFailed("timed out")
        }
        if let failure = box.failureMessage { throw UnmountError.unmountFailed(failure) }
    }
}

private func unmountCallback(
    _ disk: DADisk?,
    _ dissenter: DADissenter?,
    _ context: UnsafeMutableRawPointer?
) {
    let box = Unmanaged<UnmountBox>.fromOpaque(context!).takeUnretainedValue()
    if let dissenter {
        let status = DADissenterGetStatus(dissenter)
        box.failureMessage = "unmount dissented (status \(status))"
    }
    box.sema.signal()
}

// Class-based box avoids Swift 6 strict-concurrency issues with mutable captures:
// writes happen on the DA dispatch queue; reads happen after the semaphore signals
// (happens-before), so no data race. Using a final class (reference type) lets the
// C context pointer simply borrow the object without a manual allocate/deallocate.
private final class UnmountBox {
    let sema = DispatchSemaphore(value: 0)
    var failureMessage: String?
}
