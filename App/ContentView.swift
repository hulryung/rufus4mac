import SwiftUI
import UniformTypeIdentifiers
import DiskDiscovery
import DiskFormat
import WindowsMedia
import RufusCore

struct ContentView: View {
    @StateObject private var diskVM = DiskListViewModel()
    @StateObject private var image = ImageSelection()
    @StateObject private var writer = ElevatedWriter()
    @StateObject private var winWriter = WindowsWriter()
    @StateObject private var formatRunner = FormatRunner()
    @StateObject private var checksums = ChecksumRunner()
    @State private var showConfirm = false
    @State private var importing = false
    @AppStorage("verifyAfterWrite") private var verifyAfterWrite = true
    @AppStorage("bypassWin11") private var bypassWin11 = true
    @AppStorage("winLocalAccount") private var winLocalAccount = false
    @AppStorage("winUsername") private var winUsername = ""
    @AppStorage("winSkipPrivacy") private var winSkipPrivacy = false
    @AppStorage("winUseRegion") private var winUseRegion = false
    @AppStorage("winDisableBitLocker") private var winDisableBitLocker = false
    @AppStorage("fmtScheme") private var fmtSchemeRaw = FormatOptions.PartitionScheme.gpt.rawValue
    @AppStorage("fmtFileSystem") private var fmtFSRaw = FormatOptions.FileSystem.exfat.rawValue
    @AppStorage("fmtLabel") private var fmtLabel = "RUFUS4MAC"

    /// Brand accent — matches the app icon's orange.
    private let accent = Color(red: 0.90, green: 0.32, blue: 0.06)

    private var oversize: Bool {
        guard let disk = diskVM.selected, image.imageSize > 0 else { return false }
        return !image.fits(disk: disk)
    }

    /// Format-only mode: no image selected → the primary action formats the disk.
    private var formatMode: Bool { image.imageURL == nil }

    // Active-writer accessors: route to whichever writer is relevant for the selected image type.
    private var activePhase: String { formatMode ? formatRunner.phase : (image.isWindows ? winWriter.phase : writer.phase) }
    private var activeFraction: Double { formatMode ? formatRunner.fraction : (image.isWindows ? winWriter.fraction : writer.fraction) }
    private var activeFinished: Bool { formatMode ? formatRunner.finished : (image.isWindows ? winWriter.finished : writer.finished) }
    private var activeError: String? { formatMode ? formatRunner.errorText : (image.isWindows ? winWriter.errorText : writer.errorText) }
    private var activeRunning: Bool { formatMode ? formatRunner.isRunning : (image.isWindows ? winWriter.isRunning : writer.isRunning) }

    private var canWrite: Bool {
        guard diskVM.selected != nil, !activeRunning, !image.hashing else { return false }
        if formatMode { return true }
        guard let disk = diskVM.selected else { return false }
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

            if image.imageURL != nil {
                field(title: "Checksums", systemImage: "number") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let r = checksums.result {
                            checksumRow("MD5", r.md5)
                            checksumRow("SHA-1", r.sha1)
                            checksumRow("SHA-256", r.sha256)
                        } else if checksums.isRunning {
                            ProgressView(value: checksums.fraction) {
                                Text("Computing… \(Int(checksums.fraction * 100))%")
                            }
                        } else if let e = checksums.errorText {
                            Text(e).font(.callout).foregroundStyle(.red)
                        } else {
                            Button("Compute checksums") {
                                if let p = image.imageURL?.path { checksums.compute(imagePath: p) }
                            }
                        }
                    }
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

            if formatMode {
                field(title: "Format options", systemImage: "gearshape") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Partition scheme", selection: $fmtSchemeRaw) {
                            ForEach(FormatOptions.PartitionScheme.allCases, id: \.rawValue) {
                                Text($0.rawValue).tag($0.rawValue)
                            }
                        }
                        Picker("File system", selection: $fmtFSRaw) {
                            ForEach(FormatOptions.FileSystem.allCases, id: \.rawValue) {
                                Text($0.rawValue).tag($0.rawValue)
                            }
                        }
                        TextField("Volume label", text: $fmtLabel)
                    }
                }
            }

            if image.isWindows {
                field(title: "Windows install media", systemImage: "window.shade.closed") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Bypass Windows 11 compatibility checks", isOn: $bypassWin11)
                        Toggle("Skip privacy questions", isOn: $winSkipPrivacy)
                        Toggle("Use this Mac's region & language", isOn: $winUseRegion)
                        Toggle("Disable BitLocker auto-encryption", isOn: $winDisableBitLocker)
                        Toggle("Create local account", isOn: $winLocalAccount)
                        if winLocalAccount {
                            TextField("Username", text: $winUsername)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
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

            if !image.isWindows && !formatMode {
                Toggle("Verify after writing", isOn: $verifyAfterWrite)
                    .toggleStyle(.checkbox).font(.callout)
                    .disabled(activeRunning)
            }

            Button { showConfirm = true } label: {
                Label(formatMode ? "Format" : "Write",
                      systemImage: formatMode ? "eraser" : "arrow.down.to.line")
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
                checksums.clear()
                Task { await image.computeHash() }
            }
        }
        .alert("Erase \(diskVM.selected?.model ?? "")?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(formatMode ? "Erase and Format" : "Erase and Write", role: .destructive) { startWrite() }
        } message: {
            if formatMode {
                Text("Erase and format /dev/\(diskVM.selected?.bsdName ?? "") as \(fmtFSRaw)? All data will be permanently destroyed.")
            } else {
                Text("All data on /dev/\(diskVM.selected?.bsdName ?? "") (\(diskVM.selected?.displaySize ?? "")) will be permanently destroyed.")
            }
        }
    }

    /// Short version from the app bundle, e.g. "0.3.1". Shown in the header so the running
    /// build is always identifiable — two builds of this app look identical otherwise.
    private static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("rufus4mac").font(.title2.bold())
                    Text(Self.appVersion)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Version \(Self.appVersion)")
                }
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

    private func checksumRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
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

    private func windowsCustomization() -> WindowsCustomization {
        // Locale.current.identifier is an ICU id ("en_KR"), not a Windows locale — map it.
        let locale: String? = winUseRegion ? WindowsLocale.current() : nil
        let tz: String? = winUseRegion
            ? WindowsTimeZone.windowsName(forIANA: TimeZone.current.identifier) : nil
        let user = winLocalAccount ? winUsername.trimmingCharacters(in: .whitespaces) : ""
        return WindowsCustomization(
            bypassWin11: bypassWin11,
            localAccountUsername: user.isEmpty ? nil : user,
            skipPrivacy: winSkipPrivacy,
            regionLocale: locale,
            regionTimeZone: tz,
            disableBitLocker: winDisableBitLocker)
    }

    private func startWrite() {
        guard let disk = diskVM.selected else { return }
        if formatMode {
            let scheme = FormatOptions.PartitionScheme(rawValue: fmtSchemeRaw) ?? .gpt
            let fs = FormatOptions.FileSystem(rawValue: fmtFSRaw) ?? .exfat
            formatRunner.start(bsdName: disk.bsdName,
                               options: .init(scheme: scheme, fileSystem: fs, label: fmtLabel))
            return
        }
        guard let url = image.imageURL else { return }
        if image.isWindows {
            winWriter.start(isoPath: url.path, bsdName: disk.bsdName, customization: windowsCustomization())
        } else if let hash = image.sha256Base64 {
            writer.startWrite(imagePath: url.path, bsdName: disk.bsdName, sha256Base64: hash, verify: verifyAfterWrite)
        }
    }
}
