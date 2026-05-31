import SwiftUI
import UniformTypeIdentifiers
import DiskDiscovery

struct ContentView: View {
    @StateObject private var diskVM = DiskListViewModel()
    @StateObject private var image = ImageSelection()
    @StateObject private var writer = WriteClient()
    @State private var showConfirm = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("rufus4mac").font(.largeTitle.bold())

            GroupBox("Image") {
                HStack {
                    Text(image.imageURL?.lastPathComponent ?? "No image selected")
                        .foregroundStyle(image.imageURL == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { importing = true }
                }
            }

            GroupBox("Target disk") {
                HStack {
                    Picker("Disk", selection: $diskVM.selected) {
                        Text("Select a disk").tag(DiskInfo?.none)
                        ForEach(diskVM.disks) { d in
                            Text("\(d.model) — \(d.displaySize) (/dev/\(d.bsdName))")
                                .tag(DiskInfo?.some(d))
                        }
                    }
                    Button("Refresh") { diskVM.refresh() }
                }
            }

            if let disk = diskVM.selected, image.imageSize > 0, !image.fits(disk: disk) {
                Label("Image is larger than the selected disk.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if writer.phase.isEmpty == false || writer.finished {
                ProgressView(value: writer.fraction) {
                    Text(writer.finished
                         ? (writer.errorText.map { "Failed: \($0)" } ?? "Done ✅")
                         : "\(writer.phase.capitalized)… \(Int(writer.fraction * 100))%")
                }
            }

            Button("Write") { showConfirm = true }
                .disabled(image.imageURL == nil || diskVM.selected == nil || image.sha256Base64 == nil
                          || (diskVM.selected.map { !image.fits(disk: $0) } ?? true))
                .keyboardShortcut(.defaultAction)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { diskVM.refresh() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: imageTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                image.select(url: url)
                Task { await image.computeHash() }
            }
        }
        .alert("Erase \(diskVM.selected?.model ?? "")?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Erase and Write", role: .destructive) { startWrite() }
        } message: {
            Text("All data on /dev/\(diskVM.selected?.bsdName ?? "") (\(diskVM.selected?.displaySize ?? "")) will be destroyed.")
        }
    }

    private var imageTypes: [UTType] {
        [UTType(filenameExtension: "iso"), UTType(filenameExtension: "img"),
         UTType(filenameExtension: "dmg")].compactMap { $0 }
    }

    private func startWrite() {
        guard let url = image.imageURL, let disk = diskVM.selected,
              let hash = image.sha256Base64 else { return }
        do {
            guard try HelperInstaller.ensureInstalled() else {
                writer.errorText = "Approve the helper in System Settings > Login Items, then try again."
                writer.finished = true
                return
            }
        } catch {
            writer.errorText = "Helper install failed: \(error)"
            writer.finished = true
            return
        }
        writer.startWrite(imagePath: url.path, bsdName: disk.bsdName,
                          expectedSHA256Base64: hash)
    }
}
