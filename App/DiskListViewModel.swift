import Foundation
import Combine
import DiskDiscovery

@MainActor
final class DiskListViewModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var selected: DiskInfo?

    func refresh() {
        let found = DiskDiscovery.removableDisks()
        disks = found
        if let sel = selected, !found.contains(sel) {
            selected = nil
        }
    }
}
