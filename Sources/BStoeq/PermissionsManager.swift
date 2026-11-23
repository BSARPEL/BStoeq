import AppKit
import BStoeqCore

/// What macOS currently allows BStoeq to do. Accessibility is tracked by `AppModel`.
@MainActor final class PermissionsManager: ObservableObject {
    enum Folder: String, CaseIterable {
        case desktop = "Desktop", documents = "Documents", downloads = "Downloads"

        var titleKey: String {
            switch self {
            case .desktop: "Masaüstü klasörü"
            case .documents: "Belgeler klasörü"
            case .downloads: "İndirilenler klasörü"
            }
        }
    }

    @Published private(set) var fullDisk = PermissionState.unknown
    @Published private(set) var folders: [Folder: PermissionState] = [:]
    @Published private(set) var checking = Set<Folder>()

    private let home: String
    private let defaults: UserDefaults
    private let fullDiskProbes: [String]
    private var generation = 0
    private static let checkedKey = "permissions.checkedFolders"

    init(home: String = NSHomeDirectory(), defaults: UserDefaults = .standard, fullDiskProbes: [String]? = nil) {
        self.home = home
        self.defaults = defaults
        self.fullDiskProbes = fullDiskProbes ?? PermissionProbe.fullDiskAccessProbes(home: home)
    }

    /// Folders the user has asked about before. macOS has their answer by now, so
    /// looking again shows no prompt.
    private var checked: Set<Folder> {
        get { Set((defaults.stringArray(forKey: Self.checkedKey) ?? []).compactMap(Folder.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.checkedKey) }
    }

    private func path(of folder: Folder) -> String { DiskListing.join(home, folder.rawValue) }

    /// Full Disk Access covers every folder.
    func state(of folder: Folder) -> PermissionState {
        fullDisk == .granted ? .granted : folders[folder] ?? .unknown
    }

    /// Reads the states that can be read without making macOS ask anything.
    func refresh() {
        generation += 1
        let generation = generation
        let known = checked.map { ($0, path(of: $0)) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, fullDiskProbes] in
            let fullDisk = PermissionProbe.fullDiskAccess(probes: fullDiskProbes)
            let states = known.map { ($0.0, PermissionProbe.folderAccess($0.1)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    if self.fullDisk != fullDisk { self.fullDisk = fullDisk }
                    for (folder, state) in states where self.folders[folder] != state { self.folders[folder] = state }
                }
            }
        }
    }

    /// Tries the folder. If macOS has never asked about it, this is when it asks.
    func check(_ folder: Folder) {
        guard !checking.contains(folder) else { return }
        checking.insert(folder)
        let path = path(of: folder)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = PermissionProbe.folderAccess(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checking.remove(folder)
                    self.folders[folder] = state
                    self.checked.insert(folder)
                }
            }
        }
    }
}
