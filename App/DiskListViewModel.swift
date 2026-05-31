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
        if let sel = selected, !found.contains(where: { $0.id == sel.id }) {
            selected = nil
        }
    }
}
