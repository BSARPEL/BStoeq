import Foundation
import Combine
import BStoeqCore

extension CacheGroup {
    var fileCount: Int { files.count }
}

struct CacheCleanupSummary {
    let isApps: Bool
    let wasStopped: Bool
    let movedCount: Int
    let movedBytes: Int64
    let skippedCount: Int
    let failedCount: Int
}

@MainActor final class CacheCleanupManager: ObservableObject {
    enum Phase { case idle, scanning, ready, cleaning }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var groups: [CacheGroup] = []
    @Published private(set) var sourceReports: [CacheSourceReport] = []
    @Published private(set) var selection: Set<String> = []
    @Published private(set) var unreadable = 0
    @Published private(set) var scanFailed = false
    @Published private(set) var apps: [UnusedApp] = []
    @Published private(set) var unknownUsageApps: [AppWithUnknownUsage] = []
    @Published private(set) var appSelection: Set<String> = []
    @Published private(set) var appUnreadable = 0
    @Published private(set) var appsScanFailed = false
    @Published private(set) var appAgeDays = 180
    @Published private(set) var scanStep = ""
    @Published private(set) var cleanupTotal = 0
    @Published private(set) var cleanedCount = 0
    @Published private(set) var isStopping = false
    @Published private(set) var report: CacheCleanupSummary?

    private let home: String
    private let applicationsRoot: String
    private let now: @Sendable () -> Date
    private let lastUsed: @Sendable (URL) -> Date?
    private let moveToTrash: @Sendable (URL) throws -> Void
    private var worker: Task<Void, Never>?
    private var operationID: UUID?
    private var previousAppAge: Int?

    init(home: String = NSHomeDirectory(),
         applicationsRoot: String = "/Applications",
         now: @escaping @Sendable () -> Date = { Date() },
         lastUsed: @escaping @Sendable (URL) -> Date? = { UnusedApps.lastUsedDate($0) },
         moveToTrash: @escaping @Sendable (URL) throws -> Void = {
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         }) {
        self.home = home
        self.applicationsRoot = applicationsRoot
        self.now = now
        self.lastUsed = lastUsed
        self.moveToTrash = moveToTrash
    }

    var unassessableApps: Int { unknownUsageApps.count }

    func setAppAgeDays(_ days: Int) {
        guard phase == .ready || phase == .idle, [30, 90, 180].contains(days), days != appAgeDays else { return }
        let previous = appAgeDays
        appAgeDays = days
        if phase == .ready {
            previousAppAge = previous
            startScan(appsOnly: true)
        }
    }

    private func clearResults() {
        groups = []
        sourceReports = []
        selection = []
        unreadable = 0
        scanFailed = false
        apps = []
        unknownUsageApps = []
        appSelection = []
        appUnreadable = 0
        appsScanFailed = false
        report = nil
    }

    func scan() {
        guard phase == .idle || phase == .ready else { return }
        clearResults()
        startScan(appsOnly: false)
    }

    private func startScan(appsOnly: Bool) {
        phase = .scanning
        scanStep = appsOnly ? "Uygulamalar taranıyor…" : "Dosyalar taranıyor…"
        let id = UUID()
        operationID = id
        worker = Task.detached(priority: .utility) { [weak self, home, applicationsRoot, now, lastUsed, appAgeDays] in
            let date = now()
            var files: CacheScanResult?
            if !appsOnly {
                files = try? CacheCleanup.scan(home: home, now: date, progress: { [weak self] source in
                    Task { @MainActor in self?.updateStep(source.titleKey, id: id) }
                }, isCancelled: { Task.isCancelled })
            }
            guard !Task.isCancelled else { return }
            await self?.updateStep("Uygulamalar taranıyor…", id: id)
            let applications = try? UnusedApps.scan(home: home, applicationsRoot: applicationsRoot, now: date,
                                                    minimumAgeDays: appAgeDays, lastUsed: lastUsed,
                                                    isCancelled: { Task.isCancelled })
            await self?.finishScan(files, applications, id: id, appsOnly: appsOnly)
        }
    }

    private func updateStep(_ step: String, id: UUID) {
        guard operationID == id else { return }
        scanStep = step
    }

    private func finishScan(_ files: CacheScanResult?, _ applications: UnusedAppScanResult?, id: UUID, appsOnly: Bool) {
        guard operationID == id else { return }
        operationID = nil
        worker = nil
        previousAppAge = nil
        if !appsOnly {
            scanFailed = files == nil
            groups = files?.groups ?? []
            sourceReports = files?.sources ?? []
            unreadable = files?.unreadable ?? 0
        }
        appsScanFailed = applications == nil
        apps = applications?.apps ?? []
        appUnreadable = applications?.unreadable ?? 0
        unknownUsageApps = applications?.unknownUsageApps ?? []
        appSelection = []
        phase = (scanFailed && appsScanFailed) ? .idle : .ready
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        worker?.cancel()
        worker = nil
        operationID = nil
        if let previousAppAge {
            appAgeDays = previousAppAge
            self.previousAppAge = nil
            phase = .ready
        } else {
            phase = .idle
        }
    }

    var selectedCount: Int { groups.reduce(0) { $0 + (selection.contains($1.id) ? $1.fileCount : 0) } }
    var selectedBytes: Int64 { groups.reduce(0) { $0 + (selection.contains($1.id) ? $1.bytes : 0) } }
    var selectedAppBytes: Int64 { apps.reduce(0) { $0 + (appSelection.contains($1.id) ? $1.bytes : 0) } }
    private var bulkGroupIDs: Set<String> { Set(groups.lazy.filter { $0.source != .installers }.map(\.id)) }
    var hasBulkSelectableGroups: Bool { groups.contains { $0.source != .installers } }
    var allCacheGroupsSelected: Bool { hasBulkSelectableGroups && bulkGroupIDs.isSubset(of: selection) }

    func toggle(_ group: CacheGroup) {
        guard phase == .ready, groups.contains(where: { $0.id == group.id }) else { return }
        if !selection.insert(group.id).inserted { selection.remove(group.id) }
    }

    func toggleAll() {
        guard phase == .ready else { return }
        let ids = bulkGroupIDs
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggleApp(_ app: UnusedApp) {
        guard phase == .ready, apps.contains(where: { $0.id == app.id }) else { return }
        if !appSelection.insert(app.id).inserted { appSelection.remove(app.id) }
    }

    private func beginCleaning(total: Int) -> @Sendable (Int) -> Void {
        let id = UUID()
        operationID = id
        cleanupTotal = total
        cleanedCount = 0
        isStopping = false
        report = nil
        phase = .cleaning
        return { [weak self] done in
            Task { @MainActor in
                guard let self, self.operationID == id else { return }
                self.cleanedCount = max(self.cleanedCount, done)
            }
        }
    }

    func stopCleaning() {
        guard phase == .cleaning else { return }
        isStopping = true
        worker?.cancel()
    }

    func cleanSelectedApps() {
        guard phase == .ready, !appSelection.isEmpty else { return }
        let selected = apps.filter { appSelection.contains($0.id) }
        let progress = beginCleaning(total: selected.count)
        worker = Task.detached(priority: .utility) { [weak self, home, applicationsRoot, now, lastUsed, appAgeDays, moveToTrash] in
            let result = UnusedApps.clean(selected, home: home, applicationsRoot: applicationsRoot, now: now(),
                                          minimumAgeDays: appAgeDays, lastUsed: lastUsed,
                                          isCancelled: { Task.isCancelled }, progress: progress, moveToTrash: moveToTrash)
            let attempted = result.moved.count + result.skipped.count + result.failed.count
            let summary = CacheCleanupSummary(isApps: true, wasStopped: attempted < selected.count, movedCount: result.moved.count,
                                              movedBytes: result.moved.reduce(0) { $0 + $1.bytes },
                                              skippedCount: result.skipped.count, failedCount: result.failed.count)
            let removed = Set(result.moved.map(\.id) + result.skipped.map(\.id))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apps.removeAll { removed.contains($0.id) }
                self.appSelection = []
                self.finishCleaning(summary)
            }
        }
    }

    func cleanSelection() {
        guard phase == .ready, !selection.isEmpty else { return }
        let progress = beginCleaning(total: selectedCount)
        worker = Task.detached(priority: .utility) { [weak self, home, now, groups, selection, moveToTrash] in
            let files = groups.filter { selection.contains($0.id) }.flatMap(\.files)
            let result = CacheCleanup.clean(files, home: home, now: now(), isCancelled: { Task.isCancelled },
                                            progress: progress, moveToTrash: moveToTrash)
            let attempted = result.moved.count + result.skipped.count + result.failed.count
            let summary = CacheCleanupSummary(isApps: false, wasStopped: attempted < files.count, movedCount: result.moved.count,
                                              movedBytes: result.moved.reduce(0) { $0 + $1.bytes },
                                              skippedCount: result.skipped.count,
                                              failedCount: result.failed.count)
            // The worker visits files in order. Keep failures and the untouched tail
            // after cancellation, along with any groups the user didn't select.
            var keep = Set(result.failed.map(\.path))
            keep.formUnion(files.dropFirst(attempted).map(\.path))
            let remaining = groups.compactMap { group -> CacheGroup? in
                guard selection.contains(group.id) else { return group }
                let retry = group.files.filter { keep.contains($0.path) }
                return retry.isEmpty ? nil : group.replacingFiles(retry)
            }.sorted { $0.bytes > $1.bytes }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.groups = remaining
                self.selection = []
                self.finishCleaning(summary)
            }
        }
    }

    private func finishCleaning(_ summary: CacheCleanupSummary) {
        worker = nil
        operationID = nil
        isStopping = false
        report = summary
        phase = .ready
    }
}
