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
    /// Off by default: the MIT splitter is verified against wimlib but not yet by a real install.
    @AppStorage("useNativeWimSplit") private var useNativeWimSplit = false
    @AppStorage("fmtScheme") private var fmtSchemeRaw = FormatOptions.PartitionScheme.gpt.rawValue
    @AppStorage("fmtFileSystem") private var fmtFSRaw = FormatOptions.FileSystem.exfat.rawValue
    @AppStorage("fmtLabel") private var fmtLabel = "RUFUS4MAC"
    @StateObject private var drivers = DriverLibrary()
    @State private var newProfileName = ""
    @State private var pendingDriverFiles: [URL] = []
    @State private var driverError: String?
    @State private var downloadingDrivers = false
    @State private var driverURLText = ""
    @State private var driverURLModel = ""
    @State private var driverDownloading = false
    @State private var pickingModel = false
    @State private var catalogModel: CatalogModel?
    @State private var clock = ProgressClock()
    /// Ticks once a second so elapsed time keeps moving between progress callbacks.
    @State private var now = Date()

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
                        Divider().padding(.vertical, 2)
                        Toggle("Split install.wim without wimlib (experimental)",
                               isOn: $useNativeWimSplit)
                        if useNativeWimSplit {
                            Text("Uses the built-in MIT-licensed splitter instead of the bundled "
                                 + "wimlib. Verified against wimlib, but not yet by a real Windows install.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox).font(.callout)
                }

                field(title: "Drivers to carry", systemImage: "shippingbox") {
                    VStack(alignment: .leading, spacing: 8) {
                        if drivers.profiles.isEmpty {
                            Text("No models yet. Add the driver installer you downloaded — a fresh "
                                 + "Windows install with no Wi-Fi cannot fetch one.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(drivers.profiles) { p in
                                HStack(spacing: 6) {
                                    Toggle(isOn: Binding(get: { drivers.selected.contains(p.name) },
                                                         set: { _ in drivers.toggle(p.name) })) {
                                        Text(p.name)
                                    }
                                    .toggleStyle(.checkbox)
                                    Text("\(p.files.count) file\(p.files.count == 1 ? "" : "s") · "
                                         + DriverLibrary.sizeLabel(p.totalSize))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        drivers.delete(profileNamed: p.name)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless).controlSize(.small)
                                    .help("Remove \(p.name) from the library")
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            // One menu rather than four buttons: the window is at most 480pt wide,
                            // and a row of them truncated to "From cat…" and "Show in Fi…".
                            Menu("Add") {
                                Button("From catalog…") {
                                    driverError = nil
                                    catalogModel = catalog?.models.first
                                    pickingModel = true
                                }
                                .disabled(catalog == nil)
                                Button("From files…", action: pickDriverFiles)
                                Button("From link…") {
                                    driverURLText = ""; driverURLModel = ""
                                    driverError = nil; downloadingDrivers = true
                                }
                            }
                            .fixedSize()
                            Button("Show in Finder") {
                                drivers.refresh()
                                NSWorkspace.shared.activateFileViewerSelecting([DriverLibrary.rootURL])
                            }
                            Spacer()
                            Button {
                                drivers.refresh()
                            } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).help("Rescan the library")
                        }
                        .controlSize(.small).font(.callout)
                        if !drivers.selected.isEmpty {
                            Text("Copied to \(DriverStore.usbFolderName)/ on the USB. Not installed by "
                                 + "Windows Setup — run them once Windows is up.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout)
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: activeRunning) { running in
            if running { clock.start() } else { clock.finish() }
            now = Date()
        }
        .onChange(of: activeFraction) { f in clock.observe(phase: activePhase, fraction: f) }
        .onChange(of: activePhase) { p in clock.observe(phase: p, fraction: activeFraction) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: imageTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                image.select(url: url)
                checksums.clear()
                Task { await image.computeHash() }
            }
        }
        .sheet(isPresented: Binding(get: { !pendingDriverFiles.isEmpty },
                                    set: { if !$0 { pendingDriverFiles = [] } })) {
            driverNamingSheet
        }
        .sheet(isPresented: $downloadingDrivers) { driverDownloadSheet }
        .sheet(isPresented: $pickingModel) { catalogSheet }
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

    /// Names the model the picked files belong to, so the library reads as a list of machines
    /// rather than a pile of installers.
    private var driverNamingSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add drivers").font(.headline)
            Text(pendingDriverFiles.map(\.lastPathComponent).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Model, e.g. NT950XEV", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitDriverFiles)
            if let e = driverError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { pendingDriverFiles = []; driverError = nil }
                Button("Add", action: commitDriverFiles)
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(DriverLibrary.sanitize(newProfileName).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
    }

    /// AppKit's panel rather than SwiftUI's `.fileImporter`: only one file importer can be attached
    /// to a view, and the image picker already holds it — a second one simply never opens. The panel
    /// also lets a whole extracted driver folder be chosen, not just loose installers.
    private func pickDriverFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose the driver installers or folders for this model"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        newProfileName = ""
        driverError = nil
        pendingDriverFiles = panel.urls
    }

    /// Loaded once; a missing or malformed catalogue simply hides the button rather than failing.
    private var catalog: DriverCatalog? { try? DriverCatalog.bundled() }

    /// Pick the machine, get the driver. The model does not decide the file — every Intel Galaxy
    /// Book takes the same package — so the list is a way to find yourself, not a mapping to get
    /// wrong.
    private var catalogSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add from catalog").font(.headline)
            if let catalog {
                Picker("Model", selection: $catalogModel) {
                    ForEach(catalog.models) { m in
                        Text(m.name).tag(Optional(m))
                    }
                }
                .labelsHidden()

                if let m = catalogModel {
                    Text(m.modelNumbers).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(catalog.packages(for: m)) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName).font(.callout).fontWeight(.medium)
                            Text(p.covers).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(DriverLibrary.sizeLabel(p.sizeBytes)
                                 + " · verified against the vendor's SHA-256")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if let e = driverError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if driverDownloading {
                    ProgressView().controlSize(.small)
                    Text("Downloading and verifying…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { pickingModel = false; driverError = nil }
                    .disabled(driverDownloading)
                Button("Download", action: installFromCatalog)
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(driverDownloading || catalogModel == nil)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func installFromCatalog() {
        guard let catalog, let model = catalogModel else { return }
        let packages = catalog.packages(for: model)
        guard !packages.isEmpty else { return }
        driverDownloading = true
        driverError = nil
        Task {
            do {
                for p in packages {
                    try await drivers.install(package: p, forModel: model.name, progress: { _ in })
                }
                driverDownloading = false
                pickingModel = false
            } catch {
                driverDownloading = false
                driverError = error.localizedDescription
            }
        }
    }

    /// Samsung builds its download links dynamically, so there is no model list to ship — paste
    /// the link from the download centre instead.
    private var driverDownloadSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download drivers").font(.headline)
            Text("Paste the link to the driver file. Samsung's download centre builds links "
                 + "dynamically, so right-click the download and copy its address.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $driverURLText)
                .textFieldStyle(.roundedBorder).disabled(driverDownloading)
            TextField("Model, e.g. NT950XEV", text: $driverURLModel)
                .textFieldStyle(.roundedBorder).disabled(driverDownloading)
            if let e = driverError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if driverDownloading {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { downloadingDrivers = false; driverError = nil }
                    .disabled(driverDownloading)
                Button("Download", action: startDriverDownload)
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(driverDownloading
                              || DriverLibrary.sanitize(driverURLModel).isEmpty
                              || driverURLText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func startDriverDownload() {
        guard let url = URL(string: driverURLText.trimmingCharacters(in: .whitespaces)) else {
            driverError = DriverLibraryError.badURL.localizedDescription
            return
        }
        driverDownloading = true
        driverError = nil
        Task {
            do {
                try await drivers.download(from: url, toProfileNamed: driverURLModel,
                                           progress: { _ in })
                driverDownloading = false
                downloadingDrivers = false
            } catch {
                driverDownloading = false
                driverError = error.localizedDescription
            }
        }
    }

    private func commitDriverFiles() {
        let name = DriverLibrary.sanitize(newProfileName)
        guard !name.isEmpty else { return }
        do {
            try drivers.add(files: pendingDriverFiles, toProfileNamed: name)
            pendingDriverFiles = []
            driverError = nil
        } catch {
            driverError = error.localizedDescription
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
                if activeFinished, activeError == nil, let e = clock.elapsed(at: now) {
                    Spacer()
                    Text("in \(ProgressClock.format(e))")
                        .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                }
            }
            if !activeFinished || activeError == nil {
                ProgressView(value: activeFinished ? 1 : activeFraction).tint(accent)
            }
            if !activeFinished, activeError == nil, let e = clock.elapsed(at: now) {
                HStack(spacing: 4) {
                    Text("\(ProgressClock.format(e)) elapsed")
                    if let r = clock.remaining(at: now) {
                        Text("·")
                        Text("about \(ProgressClock.format(r)) left")
                    } else {
                        Text("· estimating…")
                    }
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
            winWriter.start(isoPath: url.path, bsdName: disk.bsdName,
                            customization: windowsCustomization(),
                            useNativeSplitter: useNativeWimSplit,
                            driverRoot: DriverLibrary.rootURL.path,
                            driverProfiles: Array(drivers.selected).sorted())
        } else if let hash = image.sha256Base64 {
            writer.startWrite(imagePath: url.path, bsdName: disk.bsdName, sha256Base64: hash, verify: verifyAfterWrite)
        }
    }
}
