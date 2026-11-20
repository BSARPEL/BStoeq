import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Quartz
import ArchiveCore

struct FileRow: Identifiable {
    let id: String
    let name: String
    let size: Int64
    let packed: Int64
    let directory: Bool
    let modified: String
    let crc: String
    let encrypted: Bool
    let url: URL?
    var kind: String { directory ? "Folder" : ((name as NSString).pathExtension.uppercased().isEmpty ? "File" : (name as NSString).pathExtension.uppercased()) }
}

enum AppSheet: String, Identifiable { case create, extract, settings, info, rename, password, report; var id: String { rawValue } }
struct CompressionProfile: Codable, Identifiable { var id = UUID(); var name: String; var options: ArchiveOptions }

@MainActor final class AppModel: ObservableObject {
    @Published var language: AppLanguage
    @Published var folder: URL
    @Published var archive: URL?
    @Published var listing = ArchiveListing()
    @Published var archiveFolder = ""
    @Published var files: [FileRow] = []
    @Published var selection: Set<String> = []
    @Published var search = ""
    @Published var sheet: AppSheet?
    @Published var busy = false
    @Published var progress: Double?
    @Published var operation = ""
    @Published var log = ""
    @Published var message: ArchiveNotice?
    @Published var error: ArchiveNotice?
    @Published var recent: [String] {
        didSet { defaults.set(recent, forKey: "archive.recent") }
    }
    @Published var favorites: [String] {
        didSet { defaults.set(favorites, forKey: "archive.favorites") }
    }
    @Published var showHidden = false
    @Published var rarPath: String {
        didSet { defaults.set(rarPath, forKey: "archive.rarPath") }
    }
    @Published var createFiles: [URL] = []
    @Published var createOptions = ArchiveOptions()
    @Published var createDestination = ""
    @Published var createPassword = ""
    @Published var confirmPassword = ""
    @Published var extractParent = ""
    @Published var extractSelected = false
    @Published var revealAfterExtract = true
    @Published var newName = ""
    @Published var passwordInput = ""
    @Published var passwordContext = ""
    @Published var report = ""
    @Published var profiles: [CompressionProfile] = []
    @Published var profileName = ""
    @Published var sortKey = "name"
    @Published var ascending = true
    var password = ""
    private var retry: (() -> Void)?
    private var control: JobControl?
    private var history: [URL] = []
    private let defaults: UserDefaults
    let changeAppLanguage: (AppLanguage) -> Void
    private let preview = PreviewController()
    let session = FileManager.default.temporaryDirectory.appendingPathComponent("BStoeq-Archive-" + UUID().uuidString)
    var L: (String) -> String { Localizer(language: language).text }
    var toolURL: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Tools/7zz")
    }
    var rarURL: URL? {
        guard !rarPath.isEmpty, FileManager.default.isExecutableFile(atPath: rarPath) else { return nil }
        return URL(fileURLWithPath: rarPath)
    }
    var service: ArchiveService { ArchiveService(tool: toolURL, rarTool: rarURL) }
    var isArchive: Bool { archive != nil }
    var canEdit: Bool { isArchive && ["zip", "7z", "tar"].contains(listing.format.lowercased()) && !listing.isMultiVolume && !listing.encrypted && listing.metadata["Container"] == nil && archive?.pathExtension != "001" }
    var selectedRows: [FileRow] { rows.filter { selection.contains($0.id) } }
    var rows: [FileRow] {
        let values: [FileRow]
        if isArchive {
            values = listing.children(of: archiveFolder, search: search).map {
                FileRow(id: $0.path, name: search.isEmpty ? $0.name : $0.path, size: $0.size, packed: $0.packedSize,
                        directory: $0.isDirectory, modified: $0.modified, crc: $0.crc, encrypted: $0.encrypted, url: nil)
            }
        } else { values = files.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
        return values.sorted { a, b in
            if a.directory != b.directory { return a.directory }
            let result: Bool
            switch sortKey {
            case "size": result = a.size == b.size ? a.name < b.name : a.size < b.size
            case "modified": result = a.modified == b.modified ? a.name < b.name : a.modified < b.modified
            case "kind": result = a.kind == b.kind ? a.name < b.name : a.kind < b.kind
            default: result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? result : (a.id != b.id && !result)
        }
    }
    init(language: AppLanguage, initialFolder: URL, defaults: UserDefaults = .standard,
         changeAppLanguage: @escaping (AppLanguage) -> Void) {
        self.defaults = defaults
        self.language = language
        self.changeAppLanguage = changeAppLanguage
        folder = initialFolder
        Self.importArchivePreferences(into: defaults)
        recent = defaults.stringArray(forKey: "archive.recent") ?? []
        favorites = defaults.stringArray(forKey: "archive.favorites") ?? []
        rarPath = defaults.string(forKey: "archive.rarPath") ?? ""
        if let data = defaults.data(forKey: "archive.profiles"), let decoded = try? JSONDecoder().decode([CompressionProfile].self, from: data) { profiles = decoded }
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        loadFolder(folder)
    }
    private static func importArchivePreferences(into defaults: UserDefaults) {
        let imported = "archive.importedLegacyPreferences"
        guard !defaults.bool(forKey: imported) else { return }
        if let previous = defaults.persistentDomain(forName: "local.arclet.app") {
            for key in ["recent", "favorites", "rarPath", "profiles"] {
                let destination = "archive." + key
                if defaults.object(forKey: destination) == nil, let value = previous[key] {
                    defaults.set(value, forKey: destination)
                }
            }
        }
        defaults.set(true, forKey: imported)
    }
    func loadFolder(_ url: URL, record: Bool = true) {
        guard !busy else { return }
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: showHidden ? [] : [.skipsHiddenFiles])
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let values = try urls.map { url -> FileRow in
                let v = try url.resourceValues(forKeys: keys)
                return FileRow(id: url.path, name: url.lastPathComponent, size: Int64(v.fileSize ?? 0), packed: 0,
                    directory: v.isDirectory == true, modified: v.contentModificationDate.map(formatter.string) ?? "", crc: "", encrypted: false, url: url)
            }
            if record && folder != url { history.append(folder) }
            folder = url; archive = nil; listing = ArchiveListing(); archiveFolder = ""; password = ""
            files = values; selection = []; search = ""; message = nil
        } catch { self.error = ArchiveNotice(error.localizedDescription) }
    }
    func openDialog() {
        guard !busy, sheet == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.title = L("Open an archive or folder"); panel.prompt = L("Open")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, password supplied: String = "", afterOpen: (() -> Void)? = nil) {
        guard !busy else { return }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { loadFolder(url); return }
        passwordContext = url.lastPathComponent
        let service = self.service
        perform("Opening archive") { token, log in
            let result = try await service.list(url, password: supplied, control: token)
            self.archive = url; self.folder = url.deletingLastPathComponent(); self.archiveFolder = ""
            self.listing = result; self.password = supplied; self.selection = []; self.search = ""
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            self.recent.removeAll { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == canonicalPath }
            self.recent.insert(url.path, at: 0); self.recent = Array(self.recent.prefix(12))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if let afterOpen { self.busy = false; afterOpen() }
        } retry: { [weak self] in guard let self else { return }; self.open(url, password: self.passwordInput, afterOpen: afterOpen) }
    }
    func enter(_ row: FileRow) {
        guard !busy else { return }
        if isArchive && row.directory { archiveFolder = row.id; selection = []; search = "" }
        else if let url = row.url {
            if row.directory || Self.archiveExtensions.contains(url.pathExtension.lowercased()) { open(url) }
            else { preview.show(url) }
        } else { selection = [row.id]; viewSelection() }
    }
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "001", "tar", "gz", "bz2", "xz", "tgz", "tbz", "tbz2", "txz", "cab", "iso", "dmg", "xar", "arj", "lzma", "z", "wim", "deb", "rpm", "jar", "war", "cpio", "lzh"]
    func up() {
        if isArchive && !archiveFolder.isEmpty { archiveFolder = (archiveFolder as NSString).deletingLastPathComponent; selection = []; search = "" }
        else if isArchive { loadFolder(folder) }
        else { loadFolder(folder.deletingLastPathComponent()) }
    }
    func back() { guard !busy else { return }; if let last = history.popLast() { loadFolder(last, record: false) } else { up() } }
    func refresh() { if let archive { open(archive, password: password) } else { loadFolder(folder, record: false) } }
    func addFavorite() {
        let path = (archive ?? folder).path
        if favorites.contains(path) { favorites.removeAll { $0 == path } } else { favorites.append(path) }
    }
    func chooseInputs() -> [URL] {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.title = L("Select files and folders"); panel.prompt = L("Select")
        return panel.runModal() == .OK ? panel.urls : []
    }
    func prepareCreate(_ inputs: [URL]? = nil) {
        guard !busy else { return }
        let selected = inputs ?? selectedRows.compactMap(\.url)
        let files = selected.isEmpty ? chooseInputs() : selected
        guard !files.isEmpty else { return }
        createFiles = files; createPassword = ""; confirmPassword = ""
        let name = files.count == 1 ? files[0].lastPathComponent : L("Archive")
        let parent = inputs == nil ? folder : files[0].deletingLastPathComponent()
        createDestination = parent.appendingPathComponent(name + "." + createOptions.format.rawValue).path
        sheet = .create
    }
    func chooseCreateDestination() {
        let panel = NSSavePanel(); panel.title = L("Save archive")
        let url = URL(fileURLWithPath: createDestination)
        panel.directoryURL = url.deletingLastPathComponent(); panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { createDestination = url.path }
    }
    func create() {
        guard !createDestination.isEmpty else { return }
        guard createPassword == confirmPassword else { error = "Passwords do not match"; return }
        let files = createFiles, options = createOptions, pass = createPassword, destination = URL(fileURLWithPath: createDestination), service = self.service
        sheet = nil; createPassword = ""; confirmPassword = ""
        perform("Creating archive") { token, log in
            let result = try await service.create(files: files, at: destination, options: options, password: pass, control: token, output: log)
            self.message = ArchiveNotice("Archive created", detail: result.first?.lastPathComponent)
            self.busy = false
            if let first = result.first { self.open(first, password: pass) }
        }
    }
    func prepareExtract() {
        guard !busy, isArchive else { return }
        extractParent = folder.path; extractSelected = !selectedRows.isEmpty; sheet = .extract
    }
    func chooseExtractDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: extractParent); panel.prompt = L("Select")
        if panel.runModal() == .OK, let url = panel.url { extractParent = url.path }
    }
    func extract() {
        guard !busy, let archive else { return }
        guard !extractSelected || !selectedRows.isEmpty else { error = "Select at least one item"; return }
        let dest = URL(fileURLWithPath: extractParent), paths = extractSelected ? selectedRows.map(\.id) : [], service = self.service, pass = password
        sheet = nil
        perform("Extracting files") { token, log in
            let out = try await service.extract(archive, to: dest, paths: paths, password: pass, control: token, output: log)
            self.message = ArchiveNotice("Files extracted", detail: out.path)
            if self.revealAfterExtract { NSWorkspace.shared.activateFileViewerSelecting([out]) }
        } retry: { [weak self] in self?.password = self?.passwordInput ?? ""; self?.extract() }
    }
    func testArchive() {
        guard let archive else { return }
        let service = self.service, pass = password
        perform("Testing archive") { token, log in
            self.report = Self.cleanTerminal(try await service.test(archive, password: pass, control: token, output: log))
            self.message = "Archive test passed"; self.sheet = .report
        } retry: { [weak self] in self?.password = self?.passwordInput ?? ""; self?.testArchive() }
    }
    func viewSelection() {
        guard let row = selectedRows.first, !row.directory else { return }
        if let url = row.url { preview.show(url); return }
        guard let archive else { return }
        let service = self.service, pass = password, session = self.session
        perform("Preparing preview") { token, log in
            let out = try await service.extract(archive, to: session, paths: [row.id], password: pass, control: token, output: log)
            let url = out.appendingPathComponent(row.id)
            if Self.archiveExtensions.contains(url.pathExtension.lowercased()) {
                self.busy = false; self.open(url)
            } else { self.preview.show(url) }
        } retry: { [weak self] in self?.password = self?.passwordInput ?? ""; self?.viewSelection() }
    }
    func addFiles() {
        guard !busy, canEdit else { return }
        let files = chooseInputs(); guard !files.isEmpty else { return }
        edit(.add(files))
    }
    func deleteSelection() {
        guard !busy, canEdit, !selectedRows.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = L("Remove selected items?")
        alert.informativeText = L("The original archive will be kept as a .backup file.")
        alert.addButton(withTitle: L("Remove")); alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { edit(.delete(selectedRows.map(\.id))) }
    }
    func prepareRename() {
        guard !busy, selectedRows.count == 1, !isArchive || canEdit, let row = selectedRows.first else { return }
        newName = (row.id as NSString).lastPathComponent; sheet = .rename
    }
    func rename() {
        guard !busy, let row = selectedRows.first else { return }
        do { try FileOperations.validateName(newName) } catch { self.error = ArchiveNotice(error.localizedDescription); return }
        if let source = row.url {
            do {
                let destination = try FileOperations.rename(source, to: newName)
                sheet = nil; loadFolder(folder, record: false); selection = [destination.path]
            } catch { self.error = ArchiveNotice(error.localizedDescription) }
        } else {
            let parent = (row.id as NSString).deletingLastPathComponent
            let path = parent.isEmpty ? newName : parent + "/" + newName
            if path == row.id { sheet = nil; return }
            sheet = nil; edit(.rename(row.id, path))
        }
    }
    func edit(_ operation: ArchiveService.Edit) {
        guard !busy, canEdit, let archive else { return }
        if case .add(let inputs) = operation {
            let names = Set(inputs.map(\.lastPathComponent))
            if listing.entries.contains(where: { names.contains(String($0.path.split(separator: "/").first ?? "")) }) {
                let alert = NSAlert(); alert.messageText = L("Replace matching archive entries?")
                alert.informativeText = L("Existing entries may be replaced. The original archive will be kept as a .backup file.")
                alert.addButton(withTitle: L("Continue")); alert.addButton(withTitle: L("Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        let service = self.service, pass = password
        perform("Updating archive") { token, log in
            try await service.edit(archive, operation: operation, password: pass, control: token, output: log)
            self.listing = try await service.list(archive, password: pass, control: token)
            self.selection = []; self.message = "Archive updated; original backed up"
        }
    }
    func convert() {
        guard let archive else { return }
        let service = self.service, pass = password, session = self.session
        perform("Preparing conversion") { token, log in
            let out = try await service.extract(archive, to: session, password: pass, control: token, output: log)
            self.createFiles = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            self.createDestination = self.folder.appendingPathComponent(archive.deletingPathExtension().lastPathComponent + "-converted." + self.createOptions.format.rawValue).path
            self.createPassword = ""; self.confirmPassword = ""; self.sheet = .create
        } retry: { [weak self] in self?.password = self?.passwordInput ?? ""; self?.convert() }
    }
    func repair() {
        guard let archive else { return }
        guard rarURL != nil else { sheet = .settings; return }
        let service = self.service
        perform("Repairing RAR archive") { token, log in
            let out = try await service.repairRAR(archive, control: token, output: log)
            self.message = "Repair completed"; NSWorkspace.shared.activateFileViewerSelecting([out])
        }
    }
    func chooseRAR() {
        let panel = NSOpenPanel(); panel.title = L("Select the RAR command-line executable"); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            guard url.lastPathComponent == "rar", FileManager.default.isExecutableFile(atPath: url.path) else { error = "Choose the executable named rar"; return }
            rarPath = url.path
        }
    }
    func saveProfile() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        profiles.removeAll { $0.name == name }; profiles.append(CompressionProfile(name: name, options: createOptions))
        defaults.set(try? JSONEncoder().encode(profiles), forKey: "archive.profiles"); profileName = ""
    }
    func exportReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "BStoeq-report.txt"
        if panel.runModal() == .OK, let url = panel.url { do { try report.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = ArchiveNotice(error.localizedDescription) } }
    }
    func benchmark() {
        let tool = toolURL
        perform("Benchmark") { token, log in
            self.report = try await ProcessRunner.run(tool: tool, arguments: ["b", "-mmt2", "-md20", "1"], control: token, output: log)
            self.sheet = .report
        }
    }
    func hashSelection() {
        let urls = selectedRows.compactMap(\.url); guard !urls.isEmpty else { return }
        let tool = toolURL
        perform("Calculating SHA-256") { token, log in
            self.report = try await ProcessRunner.run(tool: tool, arguments: ["h", "-scrcSHA256", "--"] + urls.map(\.path), control: token, output: log)
            self.sheet = .report
        }
    }
    func acceptPassword() {
        guard !busy, sheet == .password, !passwordInput.isEmpty else { return }
        sheet = nil; let action = retry; retry = nil; action?(); passwordInput = ""
    }
    func cancel() { control?.cancel() }
    func cleanUp() { control?.cancel(); try? FileManager.default.removeItem(at: session) }
    func perform(_ operation: String, action: @escaping (JobControl, @escaping @Sendable (String) -> Void) async throws -> Void,
                 retry: (() -> Void)? = nil) {
        guard !busy else { return }
        if operation != "Opening archive" { passwordContext = archive?.lastPathComponent ?? "" }
        let token = JobControl(); control = token; busy = true; self.operation = operation; log = ""; progress = nil; message = nil
        let logger: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                guard let self, self.control === token else { return }
                self.log = Self.cleanTerminal(String((self.log + text).suffix(18_000)))
                if let match = text.range(of: #"\b\d{1,3}%"#, options: .regularExpression), let number = Double(text[match].dropLast()) {
                    self.progress = min(1, number / 100)
                }
            }
        }
        Task {
            do { try await action(token, logger) }
            catch ArchiveError.password {
                self.retry = retry; passwordInput = ""
                if retry != nil { sheet = .password } else { error = "Password is missing or incorrect" }
            }
            catch ArchiveError.cancelled { message = "Operation cancelled" }
            catch ArchiveError.unsafePath(let path) { error = ArchiveNotice("This archive contains a path outside its destination folder:", detail: path) }
            catch ArchiveError.linksUnsupported(let path) { error = ArchiveNotice("This version cannot extract links inside an archive:", detail: path) }
            catch {
                let text = error.localizedDescription
                self.error = ArchiveNotice(text)
            }
            if control === token { busy = false; control = nil; progress = nil }
        }
    }
    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !busy, sheet == nil else { error = "Finish the current operation or close the dialog first."; return }
        if urls.count == 1, let url = urls.first, Self.archiveExtensions.contains(url.pathExtension.lowercased()) { open(url) }
        else { prepareCreate(urls) }
    }
    static func cleanTerminal(_ text: String) -> String {
        var result = ""
        for c in text {
            if c == "\u{8}" { if !result.isEmpty && result.last != "\n" { result.removeLast() } }
            else if c != "\r" { result.append(c) }
        }
        return result
    }
}

@MainActor final class PreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var url: URL?
    func show(_ url: URL) {
        self.url = url
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}
