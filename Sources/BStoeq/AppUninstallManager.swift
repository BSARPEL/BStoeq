import AppKit
import os
import BStoeqCore

struct AppUninstallSummary: Equatable {
    let appName: String
    let outcome: AppUninstallResult.Outcome
    /// The app itself and the leftovers that went with it.
    let movedCount: Int
    let movedBytes: Int64
    let skippedCount: Int
    let failedPaths: [String]
    let wasStopped: Bool
}

/// Lists installed apps and removes the one the user picks, with the data it left
/// in the Library. Everything goes to the Trash.
@MainActor final class AppUninstallManager: ObservableObject {
    enum Phase: Equatable { case idle, listing, list, inspecting, review, removing }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var apps: [InstalledApp] = []
    /// Paths of listed apps that are open right now.
    @Published private(set) var runningApps = Set<String>()
    /// The app being inspected, reviewed or removed.
    @Published private(set) var current: InstalledApp?
    @Published private(set) var plan: AppUninstallPlan?
    @Published private(set) var selection = Set<String>()
    @Published private(set) var removeTotal = 0
    @Published private(set) var removedCount = 0
    @Published private(set) var isStopping = false
    @Published private(set) var report: AppUninstallSummary?

    private let home: String
    private let applicationsRoot: String
    private let running: @Sendable () -> RunningAppSnapshot
    private let moveToTrash: @Sendable (URL) throws -> Void
    private var generation = 0
    private var cancellation: OSAllocatedUnfairLock<Bool>?
    private var observers: [NSObjectProtocol] = []

    init(home: String = NSHomeDirectory(), applicationsRoot: String = "/Applications",
         running: @escaping @Sendable () -> RunningAppSnapshot = { RunningAppSnapshot.current() },
         moveToTrash: @escaping @Sendable (URL) throws -> Void = { try AppUninstallManager.moveLikeFinder($0) }) {
        self.home = home
        self.applicationsRoot = applicationsRoot
        self.running = running
        self.moveToTrash = moveToTrash
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// An app from the App Store or an installer belongs to root, so moving it needs
    /// an administrator. Finder can ask for one; hand such an app to it.
    nonisolated static func moveLikeFinder(_ url: URL) throws {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch {
            guard url.pathExtension.lowercased() == "app", !Thread.isMainThread else { throw error }
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle([url]) { _, _ in finished.signal() }
            }
            // Finder may be waiting for the administrator's password; do not wait for ever.
            _ = finished.wait(timeout: .now() + 300)
            if FileManager.default.fileExists(atPath: url.path) { throw error }
        }
    }

    // MARK: Listing

    func refreshRunning() {
        let snapshot = running()
        let open = Set(apps.filter { AppUninstaller.isRunning($0, in: snapshot) }.map(\.path))
        if open != runningApps { runningApps = open }
    }

    /// Reads the installed apps again. A review in progress is left alone.
    func refresh() {
        guard phase == .idle || phase == .list else { return }
        generation += 1
        let generation = generation
        phase = .listing
        DispatchQueue.global(qos: .userInitiated).async { [weak self, home, applicationsRoot] in
            let found = AppUninstaller.installedApps(home: home, applicationsRoot: applicationsRoot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.phase == .listing else { return }
                    self.apps = found
                    self.phase = .list
                    self.refreshRunning()
                }
            }
        }
    }

    // MARK: Review

    func inspect(_ app: InstalledApp) {
        guard phase == .list, apps.contains(where: { $0.id == app.id }) else { return }
        generation += 1
        let generation = generation
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        cancellation = cancelled
        current = app; plan = nil; selection = []; report = nil
        phase = .inspecting
        let thread = Thread { [weak self, home, apps] in
            let plan = AppUninstaller.inspect(app, among: apps, home: home, isCancelled: { cancelled.withLock { $0 } })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishInspection(plan, generation: generation) }
            }
        }
        thread.name = "local.barlet.app-inspect"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func finishInspection(_ plan: AppUninstallPlan?, generation: Int) {
        guard self.generation == generation, phase == .inspecting else { return }
        cancellation = nil
        guard let plan else {
            // The bundle changed or disappeared since it was listed.
            let name = current?.name ?? ""
            current = nil
            phase = .list
            report = AppUninstallSummary(appName: name, outcome: .changed, movedCount: 0, movedBytes: 0,
                                         skippedCount: 0, failedPaths: [], wasStopped: false)
            refresh()
            return
        }
        self.plan = plan
        // Data found under the app's own identifier goes with it unless the user
        // says otherwise; a match by name alone is theirs to tick.
        selection = Set(plan.leftovers.filter { !$0.matchedByName }.map(\.id))
        phase = .review
        refreshRunning()
    }

    /// Back to the list, from an inspection or a review.
    func back() {
        guard phase == .inspecting || phase == .review else { return }
        cancellation?.withLock { $0 = true }
        cancellation = nil
        generation += 1
        current = nil; plan = nil; selection = []
        phase = .list
        refreshRunning()
    }

    var isCurrentRunning: Bool { current.map { runningApps.contains($0.path) } ?? false }
    var selectedBytes: Int64 {
        guard let plan else { return 0 }
        return plan.appBytes + plan.leftovers.reduce(0) { $0 + (selection.contains($1.id) ? ($1.bytes ?? 0) : 0) }
    }

    func toggle(_ leftover: AppLeftover) {
        guard phase == .review, plan?.leftovers.contains(where: { $0.id == leftover.id }) == true else { return }
        if !selection.insert(leftover.id).inserted { selection.remove(leftover.id) }
    }

    // MARK: Removing

    func stopRemoving() {
        guard phase == .removing else { return }
        isStopping = true
        cancellation?.withLock { $0 = true }
    }

    func uninstall() {
        guard phase == .review, let plan else { return }
        let selection = selection.intersection(plan.leftovers.map(\.id))
        let total = 1 + selection.count
        generation += 1
        let generation = generation
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        cancellation = cancelled
        removeTotal = total; removedCount = 0; isStopping = false; report = nil
        phase = .removing
        DispatchQueue.global(qos: .userInitiated).async { [weak self, home, applicationsRoot, running, moveToTrash] in
            let result = AppUninstaller.uninstall(plan, leftovers: selection, home: home, applicationsRoot: applicationsRoot,
                                                  running: running, isCancelled: { cancelled.withLock { $0 } },
                                                  progress: { done in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation else { return }
                        self.removedCount = max(self.removedCount, done)
                    }
                }
            }, moveToTrash: moveToTrash)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishUninstall(result, plan: plan, total: total, generation: generation) }
            }
        }
    }

    private func finishUninstall(_ result: AppUninstallResult, plan: AppUninstallPlan, total: Int, generation: Int) {
        guard self.generation == generation, phase == .removing else { return }
        cancellation = nil
        isStopping = false
        let moved = result.outcome == .moved
        let attempted = (moved ? 1 : 0) + result.moved.count + result.skipped.count + result.failed.count
        report = AppUninstallSummary(appName: plan.app.name, outcome: result.outcome,
                                     movedCount: (moved ? 1 : 0) + result.moved.count,
                                     movedBytes: (moved ? plan.appBytes : 0) + result.moved.reduce(0) { $0 + ($1.bytes ?? 0) },
                                     skippedCount: result.skipped.count, failedPaths: result.failed.map(\.path),
                                     wasStopped: moved && attempted < total)
        switch result.outcome {
        case .moved, .changed:
            apps.removeAll { $0.id == plan.app.id }
            current = nil; self.plan = nil; selection = []
            phase = .list
            // A replaced bundle is another app now; list it afresh.
            if result.outcome == .changed { refresh() } else { refreshRunning() }
        case .running, .failed:
            phase = .review
            refreshRunning()
        }
    }

    /// For quitting: stops whatever is running.
    func stop() {
        back()
        stopRemoving()
    }
}
