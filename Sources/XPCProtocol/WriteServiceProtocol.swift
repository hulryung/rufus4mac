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
