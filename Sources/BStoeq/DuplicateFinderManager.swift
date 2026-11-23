import AppKit
import os
import BStoeqCore

struct DuplicateTrashSummary: Equatable {
    let movedCount: Int
    let movedBytes: Int64
    let skippedCount: Int
    let failedCount: Int
    let wasStopped: Bool
}

/// Finds files with identical content and moves the copies the user picks to the
/// Trash. One file of every group always stays where it is.
@MainActor final class DuplicateFinderManager: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready, trashing }

    /// Smallest file worth comparing; `1` compares every file that is not empty.
    static let sizeOptions: [Int64] = [1, 100_000, 1_000_000, 10_000_000, 100_000_000]

    @Published private(set) var phase = Phase.idle
    /// The folder being scanned or shown.
    @Published private(set) var folder: String?
    @Published private(set) var minimumBytes: Int64 = 1_000_000
    @Published private(set) var progress = DuplicateScanProgress()
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var selection = Set<String>()
    @Published private(set) var scannedFiles = 0
    @Published private(set) var unreadable = 0
    @Published private(set) var skipped = 0
    @Published private(set) var trashTotal = 0
    @Published private(set) var trashedCount = 0
    @Published private(set) var isStopping = false
    @Published private(set) var report: DuplicateTrashSummary?
    @Published var problem: UserMessage?

    let home: String
    private let ownBundle: String?
    private let mountPoints: @Sendable () -> Set<String>
    private let moveToTrash: @Sendable (URL) throws -> Void
    private var generation = 0
    private var cancellation: OSAllocatedUnfairLock<Bool>?

    init(home: String = NSHomeDirectory(), ownBundle: String? = Bundle.main.bundleURL.path,
         mountPoints: @escaping @Sendable () -> Set<String> = { DiskScanner.mountPoints() },
         moveToTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.home = DiskScanner.canonicalPath(home) ?? home
        self.ownBundle = ownBundle.map { DiskScanner.canonicalPath($0) ?? $0 }
        self.mountPoints = mountPoints; self.moveToTrash = moveToTrash
    }

    func setMinimumBytes(_ value: Int64) {
        guard phase == .idle, Self.sizeOptions.contains(value) else { return }
        minimumBytes = value
    }

    // MARK: Scanning

    func scan(_ requested: String) {
        guard phase == .idle || phase == .ready else { return }
        clearResult()
        // Every result path is built from this one, and paths decide what is protected.
        guard let path = DiskScanner.canonicalPath(requested) else {
            phase = .idle; folder = nil
            problem = UserMessage("Bu klasör taranamadı. BStoeq’in bu klasöre erişim izni olmayabilir.")
            return
        }
        generation += 1
        let generation = generation
        folder = path; phase = .scanning; progress = DuplicateScanProgress(); problem = nil
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        cancellation = cancelled
        // A thread of its own: the scan sets a per-thread I/O policy and may wait on a
        // permission prompt, neither of which belongs on a shared queue.
        let thread = Thread { [weak self, home, minimumBytes, mountPoints] in
            let result = DuplicateFinder.scan(path, home: home, minimumBytes: minimumBytes, mountPoints: mountPoints(),
                                              isCancelled: { cancelled.withLock { $0 } }) { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation, self.phase == .scanning else { return }
                        self.progress = progress
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishScan(result, generation: generation) }
            }
        }
        thread.name = "local.barlet.duplicate-scan"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func finishScan(_ result: DuplicateScanResult?, generation: Int) {
        guard self.generation == generation, phase == .scanning else { return }
        cancellation = nil
        guard let result else {
            phase = .idle; folder = nil
            problem = UserMessage("Bu klasör taranamadı. BStoeq’in bu klasöre erişim izni olmayabilir.")
            return
        }
        groups = result.groups
        scannedFiles = result.scannedFiles; unreadable = result.unreadable; skipped = result.skipped
        phase = .ready
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        cancellation?.withLock { $0 = true }
        cancellation = nil
        generation += 1
        phase = .idle; folder = nil
    }

    private func clearResult() {
        groups = []; selection = []; scannedFiles = 0; unreadable = 0; skipped = 0; report = nil
    }

    /// Lets go of the result.
    func close() {
        guard phase == .ready else { return }
        clearResult()
        phase = .idle; folder = nil; problem = nil
    }

    // MARK: Selection

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var selectedCount: Int { selection.count }
    var selectedBytes: Int64 {
        groups.reduce(0) { total, group in
            total + group.files.reduce(0) { $0 + (selection.contains($1.id) ? $1.bytes : 0) }
        }
    }

    /// The only copy of a group that is not selected cannot be selected as well.
    func isLastKept(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        !selection.contains(file.id) && group.files.allSatisfy { $0.id == file.id || selection.contains($0.id) }
    }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard phase == .ready, let current = groups.first(where: { $0.id == group.id }),
              current.files.contains(where: { $0.id == file.id }) else { return }
        if selection.contains(file.id) { selection.remove(file.id) }
        else if !isLastKept(file, in: current) { selection.insert(file.id) }
    }

    /// Keeps the oldest copy of every group and selects the others.
    func selectAllButOldest() {
        guard phase == .ready else { return }
        selection = Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
    }

    func clearSelection() {
        guard phase == .ready else { return }
        selection = []
    }

    // MARK: Trash

    func stopTrashing() {
        guard phase == .trashing else { return }
        isStopping = true
        cancellation?.withLock { $0 = true }
    }

    func trashSelection() {
        guard phase == .ready, !selection.isEmpty else { return }
        let groups = groups, selection = selection
        let total = selection.count
        generation += 1
        let generation = generation
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        cancellation = cancelled
        trashTotal = total; trashedCount = 0; isStopping = false; report = nil; problem = nil
        phase = .trashing
        DispatchQueue.global(qos: .userInitiated).async { [weak self, home, ownBundle, mountPoints, moveToTrash] in
            let result = DuplicateFinder.trash(groups, selection: selection, home: home, mountPoints: mountPoints(),
                                               ownBundle: ownBundle, isCancelled: { cancelled.withLock { $0 } },
                                               progress: { done in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation else { return }
                        self.trashedCount = max(self.trashedCount, done)
                    }
                }
            }, moveToTrash: moveToTrash)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishTrash(result, total: total, generation: generation) }
            }
        }
    }

    private func finishTrash(_ result: DuplicateTrashResult, total: Int, generation: Int) {
        guard self.generation == generation, phase == .trashing else { return }
        cancellation = nil
        // A copy that changed is no longer known to be a copy; one that could not be
        // moved, or was not reached, stays for another try.
        let gone = Set((result.moved + result.skipped).map(\.id))
        groups = groups.compactMap { $0.keeping { !gone.contains($0.id) } }
            .sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.id < $1.id }
        selection = []
        let attempted = result.moved.count + result.skipped.count + result.failed.count
        report = DuplicateTrashSummary(movedCount: result.moved.count, movedBytes: result.moved.reduce(0) { $0 + $1.bytes },
                                       skippedCount: result.skipped.count, failedCount: result.failed.count,
                                       wasStopped: attempted < total)
        isStopping = false
        phase = .ready
    }

    /// For quitting: stops whatever is running.
    func stop() {
        cancelScan()
        stopTrashing()
    }
}
