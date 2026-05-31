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
