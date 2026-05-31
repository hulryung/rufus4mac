public enum WriteError: Error, Equatable {
    case imageLargerThanTarget(imageSize: UInt64, targetSize: UInt64)
    case deviceOpenFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case shortWrite(expected: Int, actual: Int)
    case verificationMismatch
    case cancelled
    case targetNotRemovable(bsdName: String)
    case invalidExpectedHash
}
