import AppKit
import os
import BStoeqCore

/// A place the user can scan: a mounted disk, the home folder, or a folder they picked.
struct DiskTarget: Identifiable, Equatable {
    enum Kind: Equatable { case volume, home, folder }
    var id: String { path }
    let path: String
    let name: String
    let kind: Kind
    var capacity: Int64?
    var available: Int64?
    var used: Int64? {
        guard let capacity, let available else { return nil }
        return max(0, capacity - available)
    }
}

/// Finds what takes up space and moves what the user picks to the Trash. Nothing is
/// ever deleted here: the Trash keeps every item recoverable.
@MainActor final class DiskScanManager: ObservableObject {
    enum Phase: Equatable { case idle, scanning, finished }

    @Published private(set) var targets: [DiskTarget] = []
    @Published private(set) var phase = Phase.idle
    @Published private(set) var progress = DiskScanProgress()
    /// The place being scanned or shown.
    @Published private(set) var target: DiskTarget?
    /// From the scanned root down to the folder on screen.
    @Published private(set) var trail: [DiskNode] = []
    @Published private(set) var rows: [DiskRow] = []
    @Published private(set) var loading = false
    @Published private(set) var trashing = false
    @Published private(set) var unreadable = 0
    @Published private(set) var skipped = 0
    /// Bytes moved to the Trash since this result was produced.
    @Published private(set) var trashed: Int64 = 0
    @Published var selection = Set<String>()
    @Published var problem: UserMessage?

    private let home: String
    private let ownBundle: String?
    private let moveToTrash: @Sendable (URL) throws -> Void
    private let mountPoints: @Sendable () -> Set<String>
    private var volumes = Set<String>()
    private var scanGeneration = 0
    private var listGeneration = 0
    private var cancellation: OSAllocatedUnfairLock<Bool>?

    init(home: String = NSHomeDirectory(), ownBundle: String? = Bundle.main.bundleURL.path,
         mountPoints: @escaping @Sendable () -> Set<String> = { DiskScanner.mountPoints() },
         moveToTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        // Rows carry real paths, so the folders they are compared with must be real too.
        self.home = DiskScanner.canonicalPath(home) ?? home
        self.ownBundle = ownBundle.map { DiskScanner.canonicalPath($0) ?? $0 }
        self.moveToTrash = moveToTrash; self.mountPoints = mountPoints
    }

    // MARK: Targets

    var homeTarget: DiskTarget {
        DiskTarget(path: home, name: (home as NSString).lastPathComponent, kind: .home)
    }

    func refreshTargets() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let found = urls.compactMap { url -> DiskTarget? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false else { return nil }
            return DiskTarget(path: url.path, name: values.volumeName ?? url.lastPathComponent, kind: .volume,
                              capacity: values.volumeTotalCapacity.map(Int64.init),
                              available: values.volumeAvailableCapacity.map(Int64.init))
        }
        if found != targets { targets = found }
        if let target, let fresh = found.first(where: { $0.path == target.path }), fresh != target { self.target = fresh }
    }

    // MARK: Scanning

    func scan(_ requested: DiskTarget) {
        cancelScan()
        scanGeneration += 1
        let generation = scanGeneration
        trail = []; rows = []; selection = []; unreadable = 0; skipped = 0; trashed = 0
        // A folder listing still on its way belongs to the result being replaced.
        listGeneration += 1; loading = false
        // Every row's path is built from this one, and the path decides what is protected.
        guard let path = DiskScanner.canonicalPath(requested.path) else {
            phase = .idle; target = nil
            problem = UserMessage("Bu klasör taranamadı. BStoeq’in bu klasöre erişim izni olmayabilir.")
            return
        }
        let target = DiskTarget(path: path, name: requested.name, kind: requested.kind,
                                capacity: requested.capacity, available: requested.available)
        self.target = target
        phase = .scanning; progress = DiskScanProgress(); problem = nil
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        cancellation = cancelled
        let root = target.path
        // A thread of its own: the scan sets a per-thread I/O policy and may wait on a
        // permission prompt, neither of which belongs on a shared queue.
        let thread = Thread { [weak self, mountPoints] in
            let mounts = mountPoints()
            let result = DiskScanner.scan(root, mountPoints: mounts, isCancelled: { cancelled.withLock { $0 } }) { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.scanGeneration == generation, self.phase == .scanning else { return }
                        self.progress = progress
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(result, mounts: mounts, generation: generation) }
            }
        }
        thread.name = "local.barlet.disk-scan"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func finish(_ result: DiskScanResult?, mounts: Set<String>, generation: Int) {
        guard scanGeneration == generation, phase == .scanning else { return }
        cancellation = nil
        guard let result, !(result.root.unreadable && result.root.children.isEmpty && result.root.fileCount == 0) else {
            phase = .idle
            problem = UserMessage("Bu klasör taranamadı. BStoeq’in bu klasöre erişim izni olmayabilir.")
            target = nil
            return
        }
        volumes = mounts
        unreadable = result.unreadable; skipped = result.skipped
        trail = [result.root]
        phase = .finished
        refreshTargets()
        reload()
    }

    /// Stops a running scan. A finished result stays.
    func cancelScan() {
        cancellation?.withLock { $0 = true }
        cancellation = nil
        guard phase == .scanning else { return }
        scanGeneration += 1
        phase = .idle; target = nil
    }

    /// Lets go of the result and the memory it holds.
    func close() {
        cancelScan()
        listGeneration += 1
        phase = .idle; target = nil
        trail = []; rows = []; selection = []; loading = false; problem = nil
        unreadable = 0; skipped = 0; trashed = 0
    }

    // MARK: Browsing

    var currentPath: String {
        guard let target else { return "" }
        return trail.dropFirst().reduce(target.path) { DiskListing.join($0, $1.name) }
    }
    var currentSize: Int64 { trail.last?.size ?? 0 }
    var scannedSize: Int64 { trail.first?.size ?? 0 }

    func open(_ row: DiskRow) {
        guard phase == .finished, !trashing, !loading, let node = row.node, !node.unreadable,
              rows.contains(where: { $0.node === node }) else { return }
        trail.append(node); showFolder()
    }

    /// Returns to the folder at `depth` in the trail; zero is the scanned root.
    func goUp(to depth: Int) {
        guard phase == .finished, !trashing, depth >= 0, depth < trail.count - 1 else { return }
        trail.removeSubrange((depth + 1)...); showFolder()
    }

    /// The rows on screen always belong to the folder at the end of the trail: the
    /// previous folder's rows go at once, not when the new listing arrives. A second
    /// click during that moment must not act on a row of the folder just left.
    private func showFolder() {
        rows = []; selection = []; reload()
    }

    func reload() {
        guard phase == .finished, let node = trail.last else { return }
        listGeneration += 1
        let generation = listGeneration
        let path = currentPath
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try DiskListing.items(at: path) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listGeneration == generation, self.trail.last === node else { return }
                    self.loading = false
                    switch outcome {
                    case .success(let items):
                        self.rows = DiskListing.rows(items, of: node, at: path)
                    case .failure(let error):
                        self.rows = []
                        self.problem = UserMessage("Klasör okunamadı: %@", detail: error.localizedDescription)
                    }
                    self.selection.formIntersection(self.rows.map(\.id))
                }
            }
        }
    }

    // MARK: Trash

    enum Lock: Equatable {
        /// macOS or the account needs the folder, or another volume is mounted in it.
        case required
        /// Nothing is known about what it holds: a cloud-only item, or a folder the
        /// scan did not measure. Moving it would free nothing that can be shown and
        /// may delete it from the cloud.
        case unmeasured
    }

    func lock(for row: DiskRow) -> Lock? {
        if DiskSafety.isProtected(row.path, home: home, volumes: volumes, ownBundle: ownBundle) { return .required }
        return row.cloudOnly || row.unmeasured ? .unmeasured : nil
    }
    func isProtected(_ row: DiskRow) -> Bool { lock(for: row) != nil }

    func toggle(_ row: DiskRow) {
        guard !trashing, !isProtected(row) else { return }
        if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
    }

    var selectedRows: [DiskRow] { rows.filter { selection.contains($0.id) && !isProtected($0) } }
    var selectedSize: Int64 { selectedRows.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Moves rows of the open folder to the Trash. Only rows that are on screen and not
    /// protected are accepted, whatever the caller passes.
    func trash(_ requested: [DiskRow]) {
        guard phase == .finished, !trashing, !loading else { return }
        // A disk may have been connected since the scan.
        volumes = mountPoints()
        let accepted = requested.filter { row in rows.contains { $0.id == row.id } && !isProtected(row) }
        guard !accepted.isEmpty else { return }
        let ancestors = trail
        let move = moveToTrash
        trashing = true; problem = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var moved: [DiskRow] = [], changed: [DiskRow] = [], failures: [(DiskRow, Error)] = []
            for row in accepted {
                // The user approved what the list showed. If the name now belongs to
                // something else (a file where a folder was), leave it alone.
                var status = stat()
                guard lstat(row.path, &status) == 0, (status.st_mode & S_IFMT == S_IFDIR) == row.isDirectory else {
                    changed.append(row); continue
                }
                do { try move(URL(fileURLWithPath: row.path)); moved.append(row) }
                catch { failures.append((row, error)) }
            }
            let done = moved, stale = changed, failed = failures
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishTrash(done, changed: stale, failed, ancestors: ancestors) }
            }
        }
    }

    private func finishTrash(_ moved: [DiskRow], changed: [DiskRow], _ failed: [(DiskRow, Error)], ancestors: [DiskNode]) {
        trashing = false
        // The result may have been closed or replaced while the files were moving.
        guard phase == .finished, trail.first === ancestors.first else { return }
        for row in moved {
            // One name of a hard-linked file frees nothing while the others remain.
            if !row.linked { trashed += row.size ?? 0 }
            DiskTree.remove(row, from: ancestors)
        }
        let gone = Set(moved.map(\.id))
        rows.removeAll { gone.contains($0.id) }
        selection.subtract(gone)
        if let (row, error) = failed.first {
            let rest = failed.count > 1 ? " (+\(failed.count - 1))" : ""
            problem = UserMessage("Çöp Sepeti’ne taşınamadı: %@", detail: "\(row.name) — \(error.localizedDescription)\(rest)")
        } else if let row = changed.first {
            let rest = changed.count > 1 ? " (+\(changed.count - 1))" : ""
            problem = UserMessage("Taramadan sonra değiştiği için taşınmadı: %@", detail: row.name + rest)
        }
        refreshTargets()
        reload()
    }
}
