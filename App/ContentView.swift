import SwiftUI
import UniformTypeIdentifiers
import DiskDiscovery

struct ContentView: View {
    @StateObject private var diskVM = DiskListViewModel()
    @StateObject private var image = ImageSelection()
    @StateObject private var writer = ElevatedWriter()
    @StateObject private var winWriter = WindowsWriter()
    @State private var showConfirm = false
    @State private var importing = false
    @AppStorage("verifyAfterWrite") private var verifyAfterWrite = true
    @AppStorage("bypassWin11") private var bypassWin11 = true

    /// Brand accent — matches the app icon's orange.
    private let accent = Color(red: 0.90, green: 0.32, blue: 0.06)

    private var oversize: Bool {
        guard let disk = diskVM.selected, image.imageSize > 0 else { return false }
        return !image.fits(disk: disk)
    }

    // Active-writer accessors: route to whichever writer is relevant for the selected image type.
    private var activePhase: String { image.isWindows ? winWriter.phase : writer.phase }
    private var activeFraction: Double { image.isWindows ? winWriter.fraction : writer.fraction }
    private var activeFinished: Bool { image.isWindows ? winWriter.finished : writer.finished }
    private var activeError: String? { image.isWindows ? winWriter.errorText : writer.errorText }
    private var activeRunning: Bool { image.isWindows ? winWriter.isRunning : writer.isRunning }

    private var canWrite: Bool {
        guard image.imageURL != nil, let disk = diskVM.selected, !activeRunning, !image.hashing else { return false }
        if image.imageSize > 0 && !image.fits(disk: disk) { return false }
        return image.isWindows ? true : (image.sha256Base64 != nil)
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

            if image.isWindows {
                field(title: "Windows install media", systemImage: "window.shade.closed") {
                    Toggle("Bypass Windows 11 compatibility checks", isOn: $bypassWin11)
                        .toggleStyle(.checkbox).font(.callout)
                }
            }

            if oversize {
                Label("Image is larger than the selected disk.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }

            if activeRunning || activeFinished {
                statusRow
            }

            if !image.isWindows {
                Toggle("Verify after writing", isOn: $verifyAfterWrite)
                    .toggleStyle(.checkbox).font(.callout)
                    .disabled(activeRunning)
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
        let pct = Int(activeFraction * 100)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if activeFinished, activeError == nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Done").fontWeight(.medium)
                } else if let err = activeError {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(err).lineLimit(2).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(activePhase.capitalized)…").fontWeight(.medium)
                    Spacer()
                    Text("\(pct)%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !activeFinished || activeError == nil {
                ProgressView(value: activeFinished ? 1 : activeFraction).tint(accent)
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
        guard let url = image.imageURL, let disk = diskVM.selected else { return }
        if image.isWindows {
            winWriter.start(isoPath: url.path, bsdName: disk.bsdName, bypassWin11: bypassWin11)
        } else if let hash = image.sha256Base64 {
            writer.startWrite(imagePath: url.path, bsdName: disk.bsdName, sha256Base64: hash,
                              verify: verifyAfterWrite)
        }
    }
}
