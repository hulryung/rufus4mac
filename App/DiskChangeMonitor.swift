import Foundation
import Combine
import DiskEvents

/// A small C bridge avoids a Swift 6 compiler crash in Disk Arbitration callback registration.
/// The bridge schedules all events on the main run loop and unregisters before disposal.
final class DiskChangeMonitor: ObservableObject {
    let changes = PassthroughSubject<Void, Never>()
    private var monitor: UnsafeMutableRawPointer?
    func start() {
        guard monitor == nil else { return }
        monitor = RufusDiskEventsStart({ context in
            guard let context else { return }
            Unmanaged<DiskChangeMonitor>.fromOpaque(context).takeUnretainedValue().changes.send()
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    deinit { RufusDiskEventsStop(monitor) }
}
