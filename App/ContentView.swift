import DiskDiscovery
import DiskFormat
import RufusCore
import SwiftUI
import UniformTypeIdentifiers
import WindowsMedia

struct ContentView: View {
    @StateObject private var diskVM = DiskListViewModel()
    @StateObject private var image = ImageSelection()
    @StateObject private var writer = ElevatedWriter()
    @StateObject private var winWriter = WindowsWriter()
    @StateObject private var formatRunner = FormatRunner()
    @StateObject private var driverCopy = DriverCopyRunner()
    @AppStorage("includeDriversWithInstaller") private var includeDrivers = false
    @State private var modelSearch = ""
    @StateObject private var checksums = ChecksumRunner()
    private enum TaskMode: String, CaseIterable {
        case bootable = "Create bootable USB"
        case format = "Format USB"
        case drivers = "Add drivers"
    }
    @State private var mode: TaskMode = .bootable
    @State private var showResult = false
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
    @StateObject private var catalogs = CatalogLibrary()
    @State private var pickingModel = false
    @State private var catalogEntry: CatalogEntry?
    @State private var managingCatalogs = false
    @State private var catalogURLText = ""
    @State private var catalogBusy = false
    @State private var clock = ProgressClock()
    /// Ticks once a second so elapsed time keeps moving between progress callbacks.
    @State private var now = Date()

    /// Brand accent — matches the app icon's orange.
    private let accent = Color(red: 0.90, green: 0.32, blue: 0.06)

    private var oversize: Bool {
        guard let disk = diskVM.selected, image.imageSize > 0 else { return false }
        if bootableMode && image.isWindows && includeDrivers {
            return image.imageSize > disk.sizeBytes || selectedDriverBytes > disk.sizeBytes - min(image.imageSize, disk.sizeBytes)
        }
        return !image.fits(disk: disk)
    }

    private var driverMode: Bool { mode == .drivers }
    private var bootableMode: Bool { mode == .bootable }
    private var selectedDrivers: [DriverProfile] {
        drivers.profiles.filter { drivers.selected.contains($0.name) && !$0.files.isEmpty }
    }
    private var selectedDriverBytes: UInt64 { selectedDrivers.reduce(0) { $0 + $1.totalSize } }
    private var driverSummary: String {
        "\(selectedDrivers.count) model\(selectedDrivers.count == 1 ? "" : "s") · \(DriverLibrary.sizeLabel(selectedDriverBytes))"
    }
    private var formatMode: Bool { mode == .format }
    private var configurationLocked: Bool { activeRunning || image.hashing || checksums.isRunning }
    private var formatOptions: FormatOptions {
        .init(
            scheme: .init(rawValue: fmtSchemeRaw) ?? .gpt,
            fileSystem: .init(rawValue: fmtFSRaw) ?? .exfat, label: fmtLabel)
    }
    private var readiness: String {
        if activeRunning { return "Keep the USB connected until the task finishes." }
        if driverMode {
            if driverCopy.selected == nil { return "Select a mounted USB volume to receive the drivers." }
            if selectedDrivers.isEmpty { return "Add drivers to your library, then select at least one model." }
            if let volume = driverCopy.selected, selectedDriverBytes > volume.availableBytes {
                return "The selected USB needs more free space for these drivers."
            }
            return "Adds files to Drivers/. Existing files are kept. Run the installers on your Windows PC."
        }
        if bootableMode && image.imageURL == nil { return "Choose an image to get started." }
        if checksums.isRunning { return "Computing checksums. Please wait before continuing." }
        if image.hashing { return "Checking the image. This may take a few minutes." }
        if bootableMode, let error = image.errorText { return error }
        if diskVM.selected == nil { return "Select the USB drive you want to use." }
        if bootableMode && oversize { return "Choose a USB drive with more space." }
        if bootableMode && image.isWindows && winLocalAccount
            && winUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Enter a username for the Windows local account."
        }
        if bootableMode && image.isWindows && includeDrivers && selectedDrivers.isEmpty {
            return "Select at least one driver model, or turn off Include drivers."
        }
        return "All data on the selected USB drive will be erased."
    }

    // Active-writer accessors: route to whichever writer is relevant for the selected image type.
    private var activePhase: String {
        driverMode ? driverCopy.phase : formatMode ? formatRunner.phase : (image.isWindows ? winWriter.phase : writer.phase)
    }
    private var activeFraction: Double {
        driverMode ? driverCopy.fraction : formatMode ? formatRunner.fraction : (image.isWindows ? winWriter.fraction : writer.fraction)
    }
    private var activeFinished: Bool {
        driverMode ? driverCopy.finished : formatMode ? formatRunner.finished : (image.isWindows ? winWriter.finished : writer.finished)
    }
    private var activeError: String? {
        driverMode ? driverCopy.errorText : formatMode ? formatRunner.errorText : (image.isWindows ? winWriter.errorText : writer.errorText)
    }
    private var activeRunning: Bool {
        driverMode ? driverCopy.isRunning : formatMode ? formatRunner.isRunning : (image.isWindows ? winWriter.isRunning : writer.isRunning)
    }

    private var canWrite: Bool {
        guard !configurationLocked else { return false }
        if driverMode {
            guard let volume = driverCopy.selected else { return false }
            return !selectedDrivers.isEmpty && selectedDriverBytes <= volume.availableBytes
        }
        guard diskVM.selected != nil else { return false }
        if formatMode { return true }
        guard image.imageURL != nil, image.errorText == nil,
            let disk = diskVM.selected
        else { return false }
        if image.isWindows && winLocalAccount
            && winUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        if image.isWindows && includeDrivers && selectedDrivers.isEmpty { return false }
        if oversize { return false }
        return image.isWindows ? true : (image.sha256Base64 != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(24)
            Picker("Task", selection: $mode) {
                ForEach(TaskMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(configurationLocked)
            .padding(.horizontal, 24).padding(.bottom, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if bootableMode {
                        field(title: "1  Choose an image", systemImage: "opticaldiscdrive") {
                            HStack(spacing: 8) {
                                if image.hashing { ProgressView().controlSize(.small) }
                                Text(image.imageURL?.lastPathComponent ?? "No image selected")
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(image.imageURL == nil ? .secondary : .primary)
                                Spacer(minLength: 8)
                                Button(image.imageURL == nil ? "Choose image…" : "Change…") {
                                    importing = true
                                }
                            }
                            if let url = image.imageURL {
                                Text(
                                    "\(DriverLibrary.sizeLabel(image.imageSize)) · \(image.hashing ? "Checking image…" : (image.isWindows ? "Windows installer · FAT32 / MBR" : "Disk image · direct copy"))"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                Text(url.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(url.path)
                                if let error = image.errorText {
                                    Label(error, systemImage: "exclamationmark.circle")
                                        .font(.callout).foregroundStyle(.red)
                                }
                            } else {
                                Text("Select a Windows or Linux image. ISO, IMG and DMG files are supported.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }

                        if image.imageURL != nil {
                            DisclosureGroup("Image checksums") {
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
                                            if let p = image.imageURL?.path {
                                                checksums.compute(imagePath: p)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                    }
                    if driverMode {
                        driverDestination
                    } else {
                    field(
                        title: formatMode ? "1  Choose a USB drive" : "2  Choose a USB drive",
                        systemImage: "externaldrive"
                    ) {
                        HStack(spacing: 8) {
                            Picker("USB drive", selection: $diskVM.selected) {
                                Text("Select a disk").tag(DiskInfo?.none)
                                ForEach(diskVM.disks) { d in
                                    Text("\(d.model) — \(d.displaySize) · \(d.bsdName)").tag(
                                        DiskInfo?.some(d))
                                }
                            }
                            .labelsHidden()
                            Button {
                                diskVM.refresh()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Rescan disks")
                            .accessibilityLabel("Refresh USB drives")
                        }
                        if diskVM.disks.isEmpty {
                            Label("Connect a USB drive, then click Refresh.", systemImage: "cable.connector")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if let disk = diskVM.selected {
                            Text(
                                "\(disk.devicePath) · \(disk.displaySize) · All existing data will be erased"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(
                                "Only external drives are listed. Check the name and capacity before continuing."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    }

                    if formatMode {
                        field(title: "2  Set up the format", systemImage: "gearshape") {
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
                                HStack {
                                    Text("Drive name")
                                    TextField("Drive name", text: $fmtLabel).textFieldStyle(.roundedBorder)
                                }
                                Text("The drive will be named \(formatOptions.normalizedLabel).")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(
                                    fmtFSRaw == "exFAT"
                                        ? "exFAT supports large files and works with macOS and Windows."
                                        : "FAT32 works with older devices. Individual files must be smaller than 4 GB."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                Text(
                                    fmtSchemeRaw == "GPT"
                                        ? "GPT is suited to modern computers."
                                        : "MBR offers compatibility with older computers."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if bootableMode && image.isWindows {
                        field(title: "3  Customize your installer", systemImage: "slider.horizontal.3") {
                            Text(
                                "Windows files are copied and checked automatically. Large installation files are split to fit the USB."
                            )
                            .font(.callout).foregroundStyle(.secondary)
                            DisclosureGroup("Windows setup preferences") {
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
                                    DisclosureGroup("Advanced") {
                                        Toggle(
                                            "Split install.wim without wimlib (experimental)",
                                            isOn: $useNativeWimSplit)
                                        if useNativeWimSplit {
                                            Text(
                                                "Uses the built-in MIT-licensed splitter instead of the bundled "
                                                    + "wimlib. Verified against wimlib, but not yet by a real Windows install."
                                            )
                                            .font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox).font(.callout)
                            }
                        }

                    }
                    if driverMode {
                        driverLibraryCard
                    } else if bootableMode && image.isWindows {
                        field(title: "4  Include drivers", systemImage: "shippingbox") {
                            Toggle("Include drivers on this USB", isOn: $includeDrivers)
                                .toggleStyle(.switch)
                            Text("Carry Wi-Fi and other installers for use after Windows setup. Nothing is installed automatically.")
                                .font(.callout).foregroundStyle(.secondary)
                            if includeDrivers { driverLibraryContent }
                        }
                    }

                    if !image.isWindows && bootableMode && image.imageURL != nil {
                        field(title: "3  Review write options", systemImage: "checkmark.shield") {
                            Toggle("Verify after writing (recommended)", isOn: $verifyAfterWrite)
                                .toggleStyle(.checkbox)
                            Text(
                                "Reads the USB back and compares it with your image. Verification takes extra time."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Text("Driver bundles can be included when creating Windows install media. For other images, use Add drivers later if the USB has a writable volume.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(configurationLocked)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 540, idealWidth: 600, minHeight: 600, idealHeight: 760)
        .tint(accent)
        .onChange(of: mode) { _ in
            showResult = false
            if driverMode { driverCopy.refresh() }
        }
        .onChange(of: driverCopy.selected) { _ in if !activeRunning { showResult = false } }
        .onChange(of: drivers.selected) { _ in if !activeRunning { showResult = false } }
        .onChange(of: image.imageURL) { _ in showResult = false }
        .onChange(of: diskVM.selected) { _ in if !activeRunning { showResult = false } }
        .onAppear { diskVM.refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: activeRunning) { running in
            if running { clock.start() } else { clock.finish() }
            now = Date()
        }
        .onChange(of: activeFraction) { f in clock.observe(phase: activePhase, fraction: f) }
        .onChange(of: activePhase) { p in clock.observe(phase: p, fraction: activeFraction) }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: imageTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                image.select(url: url)
                checksums.clear()
                Task { await image.computeHash() }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { !pendingDriverFiles.isEmpty },
                set: { if !$0 { pendingDriverFiles = [] } })
        ) {
            driverNamingSheet
        }
        .sheet(isPresented: $downloadingDrivers) { driverDownloadSheet }
        .sheet(isPresented: $pickingModel) { catalogSheet }
        .sheet(isPresented: $managingCatalogs) { catalogManagerSheet }
        .alert(driverMode ? "Add drivers to \(driverCopy.selected?.name ?? "USB")?" : "Erase \(diskVM.selected?.model ?? "")?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            if driverMode {
                Button("Add drivers", action: startWrite)
            } else {
                Button(formatMode ? "Erase and Format" : "Erase and Write", role: .destructive) {
                    startWrite()
                }
            }
        } message: {
            if driverMode {
                Text("Copy \(driverSummary) to \(driverCopy.selected?.mountPath ?? "")/Drivers/. Existing files will not be replaced. Eject the USB in Finder when copying finishes.")
            } else if formatMode {
                Text(
                    "All data on \(diskVM.selected?.devicePath ?? "") (\(diskVM.selected?.displaySize ?? "")) will be permanently erased.\n\nFormat: \(fmtFSRaw) · \(fmtSchemeRaw)\nDrive name: \(formatOptions.normalizedLabel)"
                )
            } else {
                Text(
                    "All data on \(diskVM.selected?.devicePath ?? "") (\(diskVM.selected?.displaySize ?? "")) will be permanently erased.\n\nImage: \(image.imageURL?.lastPathComponent ?? "")"
                )
            }
        }
    }

    private var driverDestination: some View {
        field(title: "1  Choose a USB volume", systemImage: "externaldrive") {
            HStack {
                Picker("USB volume", selection: $driverCopy.selected) {
                    Text("Select a volume").tag(USBVolume?.none)
                    ForEach(driverCopy.volumes) { volume in
                        Text("\(volume.name) · \(DriverLibrary.sizeLabel(volume.availableBytes)) free · \(volume.bsdName)")
                            .tag(USBVolume?.some(volume))
                    }
                }.labelsHidden()
                Button { driverCopy.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh mounted USB volumes").accessibilityLabel("Refresh mounted USB volumes")
            }
            if driverCopy.volumes.isEmpty {
                Text("Connect a USB that appears in Finder, then refresh. Only mounted, writable external volumes are listed.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let volume = driverCopy.selected {
                Text(volume.mountPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Label("Adds driver files without formatting the USB.", systemImage: "checkmark.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var driverLibraryCard: some View {
        field(title: "2  Choose drivers", systemImage: "shippingbox") {
            Text("Keep installers ready for a PC without Wi-Fi. After Windows starts, open Drivers on the USB and run the installer for your model.")
                .font(.callout).foregroundStyle(.secondary)
            driverLibraryContent
        }
    }

    private var driverLibraryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if drivers.profiles.isEmpty {
                Text("Your driver library is empty. Choose a model from a catalog, add downloaded files, or paste a driver link.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(drivers.profiles) { profile in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { drivers.selected.contains(profile.name) },
                                             set: { _ in drivers.toggle(profile.name) })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).fixedSize(horizontal: false, vertical: true)
                                Text("\(profile.files.count) file\(profile.files.count == 1 ? "" : "s") · \(DriverLibrary.sizeLabel(profile.totalSize))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if profile.files.isEmpty {
                                    Text("Add files to this model before selecting it.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox).disabled(profile.files.isEmpty)
                        .accessibilityLabel("\(profile.name), \(profile.files.count) files, \(DriverLibrary.sizeLabel(profile.totalSize))")
                        Spacer(minLength: 0)
                        Button { drivers.delete(profileNamed: profile.name) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless).help("Remove \(profile.name) from the library")
                        .accessibilityLabel("Remove \(profile.name) from the library")
                    }
                    if profile.id != drivers.profiles.last?.id { Divider() }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { driverImportActions; Spacer(); driverLibraryActions }
                VStack(alignment: .leading, spacing: 8) { driverImportActions; driverLibraryActions }
            }
            if !selectedDrivers.isEmpty {
                Label(driverSummary, systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var driverImportActions: some View {
        HStack {
            Button("From catalog…") {
                driverError = nil; modelSearch = ""
                catalogs.refresh(); catalogEntry = catalogs.entries.first; pickingModel = true
            }
            Menu("More") {
                Button("From files…", action: pickDriverFiles)
                Button("From link…") {
                    driverURLText = ""; driverURLModel = ""
                    driverError = nil; downloadingDrivers = true
                }
            }.fixedSize()
        }.fixedSize()
    }

    private var driverLibraryActions: some View {
        HStack {
            Button("Show in Finder") {
                drivers.refresh()
                NSWorkspace.shared.activateFileViewerSelecting([DriverLibrary.rootURL])
            }
            Button { drivers.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh driver library").accessibilityLabel("Refresh driver library")
        }
    }

    private var actionFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if activeRunning || showResult { statusRow }
            if activeRunning {
                Label(readiness, systemImage: "cable.connector")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !activeRunning {
                if driverMode, let volume = driverCopy.selected {
                    Label("\(volume.name) · \(driverSummary)", systemImage: "shippingbox")
                        .font(.callout)
                } else if !driverMode, let disk = diskVM.selected {
                    HStack {
                        Label(disk.model, systemImage: "externaldrive.fill")
                            .fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(
                            formatMode
                                ? "\(fmtFSRaw) · \(fmtSchemeRaw)"
                                : (image.isWindows ? "Windows installer" : "Disk image")
                        )
                        .foregroundStyle(.secondary)
                    }.font(.callout)
                }
                Label(readiness, systemImage: canWrite && !driverMode ? "exclamationmark.triangle" : "info.circle")
                    .font(.callout).foregroundStyle(canWrite && !driverMode ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                showConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Label(
                        activeRunning
                            ? "Working…" : (driverMode ? "Add drivers to USB…" : formatMode ? "Erase & format USB…" : "Create bootable USB…"),
                        systemImage: formatMode ? "eraser" : "arrow.down.to.line")
                    Spacer()
                }.padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!canWrite).keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
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

    /// Pick the machine, get the driver. The device list spans every installed catalog, so entries
    /// carry the catalog they came from — two publishers can name a device the same thing.
    private var filteredModels: [CatalogEntry] {
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalogs.entries.filter {
            query.isEmpty || "\($0.name) \($0.model.modelNumbers) \($0.catalogName)".localizedCaseInsensitiveContains(query)
        }
    }

    private var catalogSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find drivers for your PC").font(.title2.bold())
                    Text("Search by model, model number, or catalog.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage catalogs…") {
                    catalogURLText = ""; driverError = nil; managingCatalogs = true
                }.disabled(driverDownloading)
            }
            TextField("Search models and catalogs", text: $modelSearch)
                .textFieldStyle(.roundedBorder).disabled(driverDownloading)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if filteredModels.isEmpty {
                        Text(catalogs.entries.isEmpty
                             ? "No models are available. Add a catalog using Manage catalogs."
                             : "No matching models. Try a model number or another search.")
                            .foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(filteredModels) { entry in
                        Button {
                            catalogEntry = entry
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: catalogEntry?.id == entry.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(catalogEntry?.id == entry.id ? accent : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).fontWeight(.medium)
                                    Text(entry.model.modelNumbers).font(.caption).foregroundStyle(.secondary)
                                    Text(entry.catalogName).font(.caption).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(catalogEntry?.id == entry.id ? accent.opacity(0.08) : Color.primary.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(driverDownloading)
                        .accessibilityLabel("\(entry.name), \(entry.model.modelNumbers), \(entry.catalogName)")
                        .accessibilityValue(catalogEntry?.id == entry.id ? "Selected" : "Not selected")
                    }
                }
            }.frame(minHeight: 150, maxHeight: 240)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let entry = catalogEntry {
                        Text("Packages for \(entry.name)").font(.headline)
                        ForEach(catalogs.catalog(for: entry).map { $0.packages(for: entry.model) } ?? []) { package in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(package.displayName).fontWeight(.medium)
                                Text(package.covers).foregroundStyle(.secondary)
                                Label(DriverLibrary.sizeLabel(package.sizeBytes) + " · SHA-256 checked on download",
                                      systemImage: "checkmark.shield").foregroundStyle(.secondary)
                            }.font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Select a model to review its driver packages.").foregroundStyle(.secondary)
                    }
                    ForEach(catalogs.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let error = driverError {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 90, maxHeight: 180)
            HStack {
                if driverDownloading {
                    ProgressView().controlSize(.small)
                    Text("Downloading and verifying…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(filteredModels.count) of \(catalogs.entries.count) models")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { pickingModel = false; driverError = nil }
                    .disabled(driverDownloading)
                Button("Add to library", action: installFromCatalog)
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(driverDownloading || catalogEntry == nil)
            }
        }
        .padding(24).frame(width: 560)
        .onChange(of: modelSearch) { _ in
            if !filteredModels.contains(where: { $0.id == catalogEntry?.id }) {
                catalogEntry = filteredModels.first
            }
        }
    }

    /// Catalogs are files, so managing them is add, update and remove.
    private var catalogManagerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Driver catalogs").font(.headline)
            Text("A catalog is a JSON file listing devices and the driver packages they need. "
                 + "Share one by sending the file or hosting it at a link.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(catalogs.catalogs) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                                Text("\(c.catalog.models.count) devices"
                                     + (c.origin.isRemovable ? "" : " · built in")
                                     + (c.catalog.updatedAt.map { " · \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if c.canUpdate {
                                Button("Update") { updateCatalog(c) }
                                    .controlSize(.small).disabled(catalogBusy)
                            }
                            if c.origin.isRemovable {
                                Button { catalogs.remove(c) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).controlSize(.small).disabled(catalogBusy)
                            }
                        }
                        .padding(.vertical, 5)
                        if c.id != catalogs.catalogs.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 170)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))

            if !catalogs.problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(catalogs.problems, id: \.self) { p in
                        Text(p).font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Add file…", action: importCatalogFile).disabled(catalogBusy)
                TextField("https://…/catalog.json", text: $catalogURLText)
                    .textFieldStyle(.roundedBorder).disabled(catalogBusy)
                Button("Fetch", action: fetchCatalog)
                    .disabled(catalogBusy || catalogURLText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)

            if let e = driverError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if catalogBusy { ProgressView().controlSize(.small) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([CatalogLibrary.rootURL])
                }
                .controlSize(.small)
                Spacer()
                Button("Done") {
                    managingCatalogs = false
                    driverError = nil
                    catalogEntry = catalogs.entries.first
                }
                .buttonStyle(.borderedProminent).tint(accent).disabled(catalogBusy)
            }
        }
        .padding(20).frame(width: 480)
    }

    private func importCatalogFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json]
        panel.message = "Choose one or more driver catalog files"
        guard panel.runModal() == .OK else { return }
        driverError = nil
        for url in panel.urls {
            do { try catalogs.addFromFile(url) }
            catch { driverError = error.localizedDescription }
        }
    }

    private func fetchCatalog() {
        guard let url = URL(string: catalogURLText.trimmingCharacters(in: .whitespaces)) else {
            driverError = CatalogLibraryError.notACatalog.localizedDescription
            return
        }
        catalogBusy = true
        driverError = nil
        Task {
            do {
                try await catalogs.addFromURL(url)
                catalogURLText = ""
            } catch { driverError = error.localizedDescription }
            catalogBusy = false
        }
    }

    private func updateCatalog(_ c: LoadedCatalog) {
        catalogBusy = true
        driverError = nil
        Task {
            do { try await catalogs.update(c) }
            catch { driverError = error.localizedDescription }
            catalogBusy = false
        }
    }

    private func installFromCatalog() {
        guard let entry = catalogEntry, let catalog = catalogs.catalog(for: entry) else { return }
        let packages = catalog.packages(for: entry.model)
        guard !packages.isEmpty else { return }
        driverDownloading = true
        driverError = nil
        Task {
            do {
                for p in packages {
                    try await drivers.install(package: p, forModel: entry.model.name, progress: { _ in })
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
                Text("Your next installation starts here.").font(.subheadline).foregroundStyle(.secondary)
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
                    Text(driverMode ? "Drivers copied and checked" : formatMode ? "USB formatted" : "Your USB is ready").fontWeight(.medium)
                } else if let err = activeError {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    ScrollView {
                        Text(err).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                } else {
                    Text("\(activePhase.capitalized)…").fontWeight(.medium)
                    Spacer()
                    Text("\(pct)% of this step").monospacedDigit().foregroundStyle(.secondary)
                }
                if activeFinished, activeError == nil, let e = clock.elapsed(at: now) {
                    Spacer()
                    Text("in \(ProgressClock.format(e))")
                        .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                }
            }
            if activeFinished && activeError == nil {
                Text(
                    driverMode || formatMode
                        ? "Eject the drive in Finder before unplugging it."
                        : (image.isWindows
                            ? "The drive has been ejected. You can unplug it and start your installation."
                            : "Eject the drive in Finder before unplugging it.")
                )
                .font(.caption).foregroundStyle(.secondary)
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
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless).help("Copy \(label)")
            .accessibilityLabel("Copy \(label) checksum")
        }
    }

    private func field<Content: View>(
        title: String, systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var imageTypes: [UTType] {
        [
            UTType(filenameExtension: "iso"), UTType(filenameExtension: "img"),
            UTType(filenameExtension: "dmg"),
        ].compactMap { $0 }
    }

    private func windowsCustomization() -> WindowsCustomization {
        // Locale.current.identifier is an ICU id ("en_KR"), not a Windows locale — map it.
        let locale: String? = winUseRegion ? WindowsLocale.current() : nil
        let tz: String? =
            winUseRegion
            ? WindowsTimeZone.windowsName(forIANA: TimeZone.current.identifier) : nil
        let user = winLocalAccount ? winUsername.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return WindowsCustomization(
            bypassWin11: bypassWin11,
            localAccountUsername: user.isEmpty ? nil : user,
            skipPrivacy: winSkipPrivacy,
            regionLocale: locale,
            regionTimeZone: tz,
            disableBitLocker: winDisableBitLocker)
    }

    private func startWrite() {
        guard canWrite else { return }
        showResult = true
        if driverMode {
            driverCopy.start(profileNames: selectedDrivers.map(\.name), root: DriverLibrary.rootURL.path)
            return
        }
        guard let disk = diskVM.selected else { return }
        if formatMode {
            let scheme = FormatOptions.PartitionScheme(rawValue: fmtSchemeRaw) ?? .gpt
            let fs = FormatOptions.FileSystem(rawValue: fmtFSRaw) ?? .exfat
            formatRunner.start(
                bsdName: disk.bsdName,
                options: .init(scheme: scheme, fileSystem: fs, label: fmtLabel))
            return
        }
        guard let url = image.imageURL else { return }
        if image.isWindows {
            winWriter.start(
                isoPath: url.path, bsdName: disk.bsdName,
                customization: windowsCustomization(),
                useNativeSplitter: useNativeWimSplit,
                driverRoot: DriverLibrary.rootURL.path,
                driverProfiles: includeDrivers ? selectedDrivers.map(\.name).sorted() : [])
        } else if let hash = image.sha256Base64 {
            writer.startWrite(
                imagePath: url.path, bsdName: disk.bsdName, sha256Base64: hash, verify: verifyAfterWrite)
        }
    }
}
