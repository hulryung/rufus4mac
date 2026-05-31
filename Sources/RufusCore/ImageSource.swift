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
/// Single-task ownership; not safe for concurrent use.
public final class FileImageSource: ImageSource, @unchecked Sendable {
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
