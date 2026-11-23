import XCTest
@testable import BStoeqCore

final class AppUninstallTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!, systemApps: URL!, userApps: URL!, trash: URL!, library: URL!

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        home = URL(fileURLWithPath: temporary).appendingPathComponent("barlet-uninstall-\(UUID().uuidString)")
        systemApps = home.appendingPathComponent("SharedApplications")
        userApps = home.appendingPathComponent("Applications")
        trash = home.appendingPathComponent("TestTrash")
        library = home.appendingPathComponent("Library")
        for folder in [systemApps!, userApps!, trash!, library!] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    @discardableResult
    private func makeApp(_ file: String, in folder: URL, id: String, name: String? = nil, version: String = "2.1") throws -> URL {
        let root = folder.appendingPathComponent(file + ".app")
        let binary = root.appendingPathComponent("Contents/MacOS/fixture")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 37, count: 40_000).write(to: binary)
        XCTAssertEqual(chmod(binary.path, 0o755), 0)
        let values: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id, "CFBundleExecutable": "fixture",
                                     "CFBundleName": name ?? file, "CFBundleVersion": "7", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        return root
    }
    @discardableResult
    private func data(_ relative: String, bytes: Int = 10_000) throws -> String {
        let url = library.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 4, count: bytes).write(to: url)
        return url.path
    }
    private func apps() -> [InstalledApp] {
        AppUninstaller.installedApps(home: home.path, applicationsRoot: systemApps.path, mountPoints: [])
    }
    private func plan(_ name: String, among list: [InstalledApp]? = nil) throws -> AppUninstallPlan {
        let all = list ?? apps()
        let app = try XCTUnwrap(all.first { $0.name == name }, name)
        return try XCTUnwrap(AppUninstaller.inspect(app, among: all, home: home.path, mountPoints: []))
    }
    private func uninstall(_ plan: AppUninstallPlan, _ selection: Set<String>,
                           running: RunningAppSnapshot = RunningAppSnapshot(), deny: Set<String> = []) -> AppUninstallResult {
        AppUninstaller.uninstall(plan, leftovers: selection, home: home.path, applicationsRoot: systemApps.path,
                                 mountPoints: { [] }, running: { running }) { url in
            if deny.contains(url.path) { throw CocoaError(.fileWriteNoPermission) }
            try self.fm.moveItem(at: url, to: self.trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    func testListsThirdPartyAppsFromBothRoots() throws {
        try makeApp("Zeta", in: systemApps, id: "org.example.zeta")
        try makeApp("alpha", in: userApps.appendingPathComponent("Vendor"), id: "org.example.alpha", name: "Alpha")
        try makeApp("Apple", in: systemApps, id: "com.apple.sample")
        try makeApp("Self", in: systemApps, id: "local.barlet.app")
        try makeApp("TooDeep", in: userApps.appendingPathComponent("a/b/c"), id: "org.example.deep")
        try fm.createDirectory(at: systemApps.appendingPathComponent("Broken.app/Contents"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: systemApps.appendingPathComponent("Link.app"),
                                  withDestinationURL: systemApps.appendingPathComponent("Zeta.app"))
        let list = apps()
        XCTAssertEqual(list.map(\.name), ["Alpha", "Zeta"])
        XCTAssertEqual(list[1].bundleIdentifier, "org.example.zeta")
        XCTAssertEqual(list[1].version, "2.1")
        XCTAssertTrue(AppUninstaller.isRunning(list[1], in: RunningAppSnapshot(identifiers: ["org.example.zeta"])))
        XCTAssertFalse(AppUninstaller.isRunning(list[0], in: RunningAppSnapshot(identifiers: ["org.example.zeta"])))
    }

    func testPlanFindsDataUnderTheExactIdentifierAndName() throws {
        try makeApp("Painter", in: systemApps, id: "org.example.Painter")
        try makeApp("Painter Pro", in: systemApps, id: "org.example.Painter.pro")
        let support = try data("Application Support/org.example.Painter/db.sqlite", bytes: 200_000)
        let caches = try data("Caches/org.example.Painter/blob")
        let preferences = try data("Preferences/org.example.Painter.plist")
        let byHost = try data("Preferences/ByHost/org.example.Painter.0A1B2C3D-0000-1111-2222-333344445555.plist")
        let state = try data("Saved Application State/org.example.Painter.savedState/window")
        let container = try data("Containers/org.example.Painter/Data/file")
        let named = try data("Application Support/Painter/brushes")
        let logs = try data("Logs/Painter/run.log")
        // Belongs to another app, a longer identifier or an unrelated name.
        try data("Application Support/org.example.Painter.pro/db")
        try data("Preferences/org.example.Painter.pro.plist")
        try data("Preferences/ByHost/org.example.Painter.pro.0A1B2C3D-0000-1111-2222-333344445555.plist")
        try data("Application Support/Painter Pro/x")
        try data("Application Support/PainterHelper/x")
        try data("Caches/org.example.other/blob")
        try fm.createDirectory(at: library.appendingPathComponent("WebKit/org.example.Painter"), withIntermediateDirectories: true)

        let plan = try plan("Painter")
        XCTAssertFalse(plan.sharesData)
        XCTAssertGreaterThanOrEqual(plan.appBytes, 40_000)
        let exact = plan.leftovers.filter { !$0.matchedByName }, byName = plan.leftovers.filter(\.matchedByName)
        func folder(_ path: String) -> String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
        XCTAssertEqual(Set(exact.map(\.path)), [folder(support), folder(caches), preferences, byHost, folder(state),
                                                 library.appendingPathComponent("Containers/org.example.Painter").path])
        XCTAssertEqual(Set(byName.map(\.path)), [folder(named), folder(logs)])
        XCTAssertEqual(plan.leftovers.first?.path, folder(support), "Exact matches first, largest first")
        XCTAssertEqual(plan.leftovers.last?.matchedByName, true)
        XCTAssertEqual(exact.first { $0.path == preferences }?.kind, .preferences)
        XCTAssertEqual(exact.first { $0.path == folder(container).replacingOccurrences(of: "/Data", with: "") }?.kind, .container)
        XCTAssertTrue(plan.leftovers.allSatisfy { ($0.bytes ?? 0) > 0 })
    }

    func testUnsafeIdentifiersNamesAndLinksFindNothing() throws {
        XCTAssertTrue(AppUninstaller.isPlainIdentifier("com.vendor.App-2_x"))
        for bad in ["../../Documents", "com..app", ".hidden.app", "app", "com.vendor/app", "com.vendor.app.", "com.vendor app", "com.öl.app"] {
            XCTAssertFalse(AppUninstaller.isPlainIdentifier(bad), bad)
        }
        XCTAssertTrue(AppUninstaller.isPlainName("Çizim Aracı"))
        for bad in ["..", "ab", ".Trash", "a/b", " padded "] { XCTAssertFalse(AppUninstaller.isPlainName(bad), bad) }

        try makeApp("Escape", in: systemApps, id: "../../Documents")
        try fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try data("Preferences/placeholder.plist")
        XCTAssertTrue(try plan("Escape").leftovers.isEmpty)

        // Data reached through a link belongs to whatever the link points at.
        try makeApp("Linked", in: systemApps, id: "org.example.linked")
        let outside = home.appendingPathComponent("Outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("keep"))
        try fm.createDirectory(at: library.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: library.appendingPathComponent("Caches/org.example.linked"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: library.appendingPathComponent("Application Support"), withDestinationURL: outside)
        try fm.createDirectory(at: outside.appendingPathComponent("org.example.linked"), withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("org.example.linked/keep"))
        XCTAssertTrue(try plan("Linked").leftovers.isEmpty)
    }

    func testSharedIdentifierOrNameKeepsTheData() throws {
        try makeApp("Editor", in: systemApps, id: "org.example.editor")
        try makeApp("Editor Beta", in: userApps, id: "org.example.editor")
        try makeApp("Notes", in: systemApps, id: "org.example.notes")
        try makeApp("Notes", in: userApps, id: "org.other.notes")
        try data("Application Support/org.example.editor/x")
        try data("Application Support/Notes/x")
        let notesData = try data("Caches/org.example.notes/x")
        let list = apps()
        let editor = try plan("Editor", among: list)
        XCTAssertTrue(editor.sharesData)
        XCTAssertTrue(editor.leftovers.isEmpty)
        let notes = try XCTUnwrap(list.first { $0.bundleIdentifier == "org.example.notes" })
        let notesPlan = try XCTUnwrap(AppUninstaller.inspect(notes, among: list, home: home.path, mountPoints: []))
        XCTAssertEqual(notesPlan.leftovers.map(\.path), [URL(fileURLWithPath: notesData).deletingLastPathComponent().path],
                       "A name two apps answer to is no evidence")
    }

    func testUninstallMovesTheAppThenOnlyChosenUnchangedLeftovers() throws {
        let app = try makeApp("Player", in: systemApps, id: "org.example.player")
        let support = URL(fileURLWithPath: try data("Application Support/org.example.player/library.db")).deletingLastPathComponent().path
        let caches = URL(fileURLWithPath: try data("Caches/org.example.player/blob")).deletingLastPathComponent().path
        let preferences = try data("Preferences/org.example.player.plist")
        let logs = URL(fileURLWithPath: try data("Logs/org.example.player/run.log")).deletingLastPathComponent().path
        let named = URL(fileURLWithPath: try data("Application Support/Player/skins")).deletingLastPathComponent().path
        let unrelated = try data("Preferences/org.example.other.plist")
        let plan = try plan("Player")
        XCTAssertEqual(plan.leftovers.count, 5)

        // Open: nothing moves.
        var result = uninstall(plan, Set(plan.leftovers.map(\.id)), running: RunningAppSnapshot(identifiers: ["org.example.player"]))
        XCTAssertEqual(result.outcome, .running)
        // Cannot be moved: its data stays.
        result = uninstall(plan, Set(plan.leftovers.map(\.id)), deny: [app.path])
        guard case .failed = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue([app.path, support, caches, preferences, logs, named].allSatisfy(fm.fileExists(atPath:)))

        // The preferences file was replaced after the inspection; a path outside the plan is ignored.
        try fm.removeItem(atPath: preferences)
        try data("Preferences/org.example.player.plist")
        var steps: [Int] = []
        result = AppUninstaller.uninstall(plan, leftovers: [support, caches, preferences, logs, unrelated], home: home.path,
                                          applicationsRoot: systemApps.path, mountPoints: { [] },
                                          running: { RunningAppSnapshot() }, progress: { steps.append($0) }) { url in
            if url.path == logs { throw CocoaError(.fileWriteNoPermission) }
            try self.fm.moveItem(at: url, to: self.trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
        XCTAssertEqual(result.outcome, .moved)
        XCTAssertEqual(Set(result.moved.map(\.path)), [support, caches])
        XCTAssertEqual(result.skipped.map(\.path), [preferences])
        XCTAssertEqual(result.failed.map(\.path), [logs])
        XCTAssertEqual(steps, [1, 2, 3, 4, 5])
        XCTAssertFalse(fm.fileExists(atPath: app.path))
        XCTAssertFalse(fm.fileExists(atPath: support))
        XCTAssertTrue([preferences, logs, named, unrelated].allSatisfy(fm.fileExists(atPath:)), "Unchosen and unrelated items stay")
    }

    func testReplacedOrMissingAppIsNotUninstalled() throws {
        let app = try makeApp("Swap", in: systemApps, id: "org.example.swap")
        let kept = try data("Caches/org.example.swap/blob")
        let plan = try plan("Swap")
        try fm.removeItem(at: app)
        try makeApp("Swap", in: systemApps, id: "org.example.swap", version: "3.0")
        let result = uninstall(plan, Set(plan.leftovers.map(\.id)))
        XCTAssertEqual(result.outcome, .changed)
        XCTAssertTrue(fm.fileExists(atPath: app.path))
        XCTAssertTrue(fm.fileExists(atPath: kept))
        XCTAssertNil(AppUninstaller.inspect(plan.app, among: [plan.app], home: home.path, mountPoints: []))
        let fresh = try self.plan("Swap")
        XCTAssertNil(AppUninstaller.inspect(fresh.app, among: [fresh.app], home: home.path, mountPoints: [], isCancelled: { true }))
    }
}
