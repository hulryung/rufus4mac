import SwiftUI
import UniformTypeIdentifiers
import DiskDiscovery

struct ContentView: View {
    @StateObject private var diskVM = DiskListViewModel()
    @StateObject private var image = ImageSelection()
    @StateObject private var writer = ElevatedWriter()
    @State private var showConfirm = false
    @State private var importing = false

    /// Brand accent — matches the app icon's orange.
    private let accent = Color(red: 0.90, green: 0.32, blue: 0.06)

    private var oversize: Bool {
        guard let disk = diskVM.selected, image.imageSize > 0 else { return false }
        return !image.fits(disk: disk)
    }
    private var canWrite: Bool {
        image.imageURL != nil && diskVM.selected != nil && image.sha256Base64 != nil && !oversize
            && !writer.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            field(title: "Image", systemImage: "opticaldiscdrive") {
                HStack(spacing: 8) {
                    if image.hashing { ProgressView().controlSize(.small) }
                    Text(image.imageURL?.lastPathComponent ?? "No image selected")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(image.imageURL == nil ? .secondary : .primary)
                    Spacer(minLength: 8)
                    Button("Choose…") { importing = true }
                }
            }

            field(title: "Target disk", systemImage: "externaldrive") {
                HStack(spacing: 8) {
                    Picker("", selection: $diskVM.selected) {
                        Text("Select a disk").tag(DiskInfo?.none)
                        ForEach(diskVM.disks) { d in
                            Text("\(d.model) — \(d.displaySize)").tag(DiskInfo?.some(d))
                        }
                    }
                    .labelsHidden()
                    Button { diskVM.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan disks")
                }
            }

            if oversize {
                Label("Image is larger than the selected disk.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }

            if writer.isRunning || writer.finished {
                statusRow
            }

            Button { showConfirm = true } label: {
                Label("Write", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            .disabled(!canWrite)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 420, maxWidth: 480, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
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
            Text("All data on /dev/\(diskVM.selected?.bsdName ?? "") (\(diskVM.selected?.displaySize ?? "")) will be permanently destroyed.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("rufus4mac").font(.title2.bold())
                Text("Create a bootable USB drive").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        let pct = Int(writer.fraction * 100)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if writer.finished, writer.errorText == nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Done").fontWeight(.medium)
                } else if let err = writer.errorText {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(err).lineLimit(2).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(writer.phase.capitalized)…").fontWeight(.medium)
                    Spacer()
                    Text("\(pct)%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !writer.finished || writer.errorText == nil {
                ProgressView(value: writer.finished ? 1 : writer.fraction).tint(accent)
            }
        }
    }

    private func field<Content: View>(title: String, systemImage: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var imageTypes: [UTType] {
        [UTType(filenameExtension: "iso"), UTType(filenameExtension: "img"),
         UTType(filenameExtension: "dmg")].compactMap { $0 }
    }

    private func startWrite() {
        guard let url = image.imageURL, let disk = diskVM.selected,
              let hash = image.sha256Base64 else { return }
        writer.startWrite(imagePath: url.path, bsdName: disk.bsdName, sha256Base64: hash)
    }
}
