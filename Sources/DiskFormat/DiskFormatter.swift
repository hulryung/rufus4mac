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
