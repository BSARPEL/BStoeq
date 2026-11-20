import XCTest
@testable import BStoeqCore

final class UnusedAppsTests: XCTestCase {
    private let fm = FileManager.default
    // Use a future inspection date: the fixture's actual creation and change times can remain intact.
    private let now = Date().addingTimeInterval(400 * 86_400)
    private var home: URL!, systemApps: URL!, userApps: URL!, trash: URL!

    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(DiskScanner.canonicalPath(fm.temporaryDirectory.path))
        home = URL(fileURLWithPath: temporary).appendingPathComponent(UUID().uuidString)
        systemApps = home.appendingPathComponent("SharedApplications")
        userApps = home.appendingPathComponent("Applications")
        trash = home.appendingPathComponent("TestTrash")
        for folder in [systemApps!, userApps!, trash!] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: home)
    }

    private func ago(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }

    @discardableResult
    private func makeApp(_ name: String, in folder: URL, id: String? = nil,
                         build: String = "1", background: Bool = false) throws -> URL {
        let root = folder.appendingPathComponent(name + ".app")
        let binary = root.appendingPathComponent("Contents/MacOS/fixture")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 37, count: 8_192).write(to: binary)
        XCTAssertEqual(chmod(binary.path, 0o755), 0)
        let values: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id ?? "org.example." + name,
                                     "CFBundleExecutable": "fixture", "CFBundleName": name, "CFBundleVersion": build,
                                     "CFBundleShortVersionString": "1.0", "LSBackgroundOnly": background]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
        return root
    }

    private func scan(age: Int = 180, usage: [String: Date], added: [String: Date] = [:],
                      running: RunningAppSnapshot = RunningAppSnapshot(), mounts: Set<String> = [],
                      progress: (String) -> Void = { _ in }) throws -> UnusedAppScanResult {
        try UnusedApps.scan(home: home.path, applicationsRoot: systemApps.path, now: now, minimumAgeDays: age,
                            mountPoints: mounts, lastUsed: { usage[$0.path] }, added: { added[$0.path] },
                            running: { running }, progress: progress)
    }

    private func clean(_ apps: [UnusedApp], usage: [String: Date], age: Int = 180,
                       running: () -> RunningAppSnapshot = { RunningAppSnapshot() },
                       mounts: Set<String> = [], added: [String: Date] = [:],
                       deny: Set<String> = []) -> UnusedAppCleanResult {
        UnusedApps.clean(apps, home: home.path, applicationsRoot: systemApps.path, now: now, minimumAgeDays: age,
                         mountPoints: { mounts }, lastUsed: { usage[$0.path] }, added: { added[$0.path] },
                         running: running, moveToTrash: { url in
            if deny.contains(url.path) { throw CocoaError(.fileWriteNoPermission) }
            try self.fm.moveItem(at: url, to: self.trash.appendingPathComponent(url.lastPathComponent))
        })
    }

    func testBothInstallRootsGroupingSizeAndConservativeUsageEvidence() throws {
        let shared = try makeApp("Shared", in: systemApps)
        let user = try makeApp("Grouped", in: userApps.appendingPathComponent("Vendor/Tools"))
        let unknown = try makeApp("Unknown", in: userApps)
        let recent = try makeApp("Recent", in: userApps)
        let newInstall = try makeApp("JustInstalled", in: userApps)
        let apple = try makeApp("Apple", in: systemApps, id: "com.apple.sample")
        let barlet = try makeApp("BStoeq", in: systemApps, id: "local.barlet.app")
        let foreground = try makeApp("CurrentlyRunning", in: userApps)
        let helper = try makeApp("HelperRunning", in: userApps)
        let background = try makeApp("Agent", in: userApps, background: true)
        let nested = try makeApp("Nested", in: shared.appendingPathComponent("Contents/Resources"))
        let other = try makeApp("Other", in: home.appendingPathComponent("Documents"))
        try fm.createSymbolicLink(at: userApps.appendingPathComponent("Linked.app"), withDestinationURL: other)
        try fm.createSymbolicLink(at: userApps.appendingPathComponent("FolderLink"), withDestinationURL: other.deletingLastPathComponent())
        let mounted = try makeApp("Mounted", in: userApps.appendingPathComponent("mounted"))
        let usage = [shared.path: ago(250), user.path: ago(181), recent.path: ago(179), newInstall.path: ago(250),
                     apple.path: ago(250), barlet.path: ago(250), foreground.path: ago(250), helper.path: ago(250),
                     background.path: ago(250), nested.path: ago(250), other.path: ago(250), mounted.path: ago(250)]
        let active = RunningAppSnapshot(identifiers: ["org.example.CurrentlyRunning"], paths: [helper.path + "/Contents/Helpers/tool"])
        var reported = Set<String>()
        let result = try scan(usage: usage, added: [newInstall.path: ago(14)], running: active,
                              mounts: [mounted.deletingLastPathComponent().path], progress: { reported.insert($0) })
        XCTAssertEqual(Set(result.apps.map(\.path)), [shared.path, user.path])
        XCTAssertTrue(Set(result.apps.map(\.path)).isSubset(of: reported))
        XCTAssertFalse(reported.contains(nested.path))
        XCTAssertEqual(result.unknownUsageApps.map(\.path), [unknown.path])
        XCTAssertEqual(result.unknownUsageApps.first?.name, "Unknown")
        XCTAssertEqual(result.unreadable, 0)
        let app = try XCTUnwrap(result.apps.first { $0.path == shared.path })
        XCTAssertEqual(app.bytes, DiskScanner.scan(shared.path)?.root.size)
        XCTAssertEqual(app.lastUsed, usage[shared.path])
        XCTAssertEqual(app.bundleIdentifier, "org.example.Shared")
    }

    func testCleanupRevalidatesIdentityVersionUsageMountsAndLateLaunch() throws {
        let names = ["Moved", "Updated", "Used", "NoHistory", "Running", "Replaced", "NestedMount", "Denied"]
        let urls = try names.map { try makeApp($0, in: userApps) }
        var usage = Dictionary(uniqueKeysWithValues: urls.map { ($0.path, ago(240)) })
        let reviewed = try scan(usage: usage).apps
        XCTAssertEqual(reviewed.count, urls.count)
        try makeApp("Updated", in: userApps, build: "2")
        usage[urls[2].path] = ago(200)  // Still old, but a later open than the one reviewed.
        usage.removeValue(forKey: urls[3].path)
        try fm.moveItem(at: urls[5], to: home.appendingPathComponent("previous.app"))
        try makeApp("Replaced", in: userApps)
        let keepData = home.appendingPathComponent("Library/Application Support/Moved/saved")
        try fm.createDirectory(at: keepData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([42]).write(to: keepData)
        var calls = 0
        let runningApp = try XCTUnwrap(reviewed.first { $0.path == urls[4].path })
        // The app starts after bundle measurement, just before the move.
        let lastSecond = clean([runningApp], usage: usage, running: {
            calls += 1
            return calls == 1 ? RunningAppSnapshot() : RunningAppSnapshot(identifiers: [runningApp.bundleIdentifier])
        })
        XCTAssertEqual(lastSecond.skipped.map(\.path), [runningApp.path])
        let result = clean(reviewed.filter { $0.id != runningApp.id }, usage: usage,
                           mounts: [urls[6].path + "/Contents/mounted"], deny: [urls[7].path])
        XCTAssertEqual(result.moved.map(\.path), [urls[0].path])
        XCTAssertEqual(Set(result.skipped.map(\.path)), Set([urls[1], urls[2], urls[3], urls[5], urls[6]].map(\.path)))
        XCTAssertEqual(result.failed.map(\.path), [urls[7].path])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: trash.path), ["Moved.app"])
        XCTAssertTrue(fm.fileExists(atPath: keepData.path))
        // Retrying an old selection leaves the already moved app alone.
        XCTAssertEqual(clean(result.moved, usage: usage).skipped.map(\.path), [urls[0].path])
    }

    func testChangedNestedResourceInvalidatesApprovalAndLockedContentsAreExcluded() throws {
        let app = try makeApp("Mutable", in: userApps)
        let resource = app.appendingPathComponent("Contents/Resources/nested/image")
        try fm.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 12, count: 8192).write(to: resource)
        // Common in frameworks. The target of a symlink is never inspected or moved independently.
        let outside = home.appendingPathComponent("personal.data")
        try Data([3]).write(to: outside)
        try fm.createSymbolicLink(at: resource.deletingLastPathComponent().appendingPathComponent("link"), withDestinationURL: outside)
        let usage = [app.path: ago(250)]
        let reviewed = try scan(usage: usage).apps
        XCTAssertEqual(reviewed.map(\.path), [app.path])
        let file = try FileHandle(forWritingTo: resource)
        try file.write(contentsOf: Data([15]))
        try file.close()
        XCTAssertEqual(clean(reviewed, usage: usage).skipped.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: outside.path))

        if chflags(resource.path, UInt32(UF_IMMUTABLE)) == 0 {
            defer { _ = chflags(resource.path, 0) }
            XCTAssertTrue(try scan(usage: usage).apps.isEmpty)
        }
    }

    func testAppleSiliconWrappedMobileAppsUseTheirOuterInstallLocation() throws {
        let mobile = try makeApp("Mobile", in: userApps)
        let info = mobile.appendingPathComponent("Contents/Info.plist")
        let binary = mobile.appendingPathComponent("Contents/MacOS/fixture")
        let inner = mobile.appendingPathComponent("Wrapper/App.app")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try fm.moveItem(at: info, to: inner.appendingPathComponent("Info.plist"))
        try fm.moveItem(at: binary, to: inner.appendingPathComponent("fixture"))
        try fm.removeItem(at: mobile.appendingPathComponent("Contents"))
        let link = mobile.appendingPathComponent("WrappedBundle")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "Wrapper/App.app")
        let usage = [mobile.path: ago(200)]
        let scanned = try scan(usage: usage)
        XCTAssertEqual(scanned.apps.map(\.path), [mobile.path])
        XCTAssertEqual(scanned.unreadable, 0)

        let outside = try makeApp("Unrelated", in: home)
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertEqual(clean(scanned.apps, usage: usage).skipped.count, 1)
        XCTAssertEqual(try scan(usage: usage).unreadable, 1)
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
    }

    func testCancelledMeasurementAndCancelledBatchLeaveUnattemptedAppsForReview() throws {
        let paths = try ["First", "Second"].map { try makeApp($0, in: userApps).path }
        let usage = Dictionary(uniqueKeysWithValues: paths.map { ($0, ago(240)) })
        let reviewed = try scan(usage: usage).apps
        XCTAssertEqual(reviewed.count, 2)
        var checks = 0
        let interrupted = UnusedApps.clean(reviewed, home: home.path, applicationsRoot: systemApps.path, now: now,
                            mountPoints: { [] }, lastUsed: { usage[$0.path] }, added: { _ in nil },
                            running: { RunningAppSnapshot() }, isCancelled: { checks += 1; return checks > 1 },
                            progress: { _ in XCTFail("An interrupted measurement did not attempt removal") },
                            moveToTrash: { _ in XCTFail("Cancellation must take effect before moving an app") })
        XCTAssertTrue(interrupted.moved.isEmpty && interrupted.skipped.isEmpty && interrupted.failed.isEmpty)
        var completed = 0
        let partial = UnusedApps.clean(reviewed, home: home.path, applicationsRoot: systemApps.path, now: now,
                            mountPoints: { [] }, lastUsed: { usage[$0.path] }, added: { _ in nil },
                            running: { RunningAppSnapshot() }, isCancelled: { completed == 1 },
                            progress: { completed = $0 }, moveToTrash: { url in
                                try self.fm.moveItem(at: url, to: self.trash.appendingPathComponent(url.lastPathComponent))
                            })
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(partial.moved.count, 1)
        XCTAssertTrue(partial.skipped.isEmpty && partial.failed.isEmpty)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: userApps.path).count, 1)
    }

    func testGroupReplacementWithSymlinkAndMissingRoots() throws {
        let vendor = userApps.appendingPathComponent("Vendor")
        let installed = try makeApp("Test", in: vendor)
        let usage = [installed.path: ago(240)]
        try fm.removeItem(at: systemApps)
        let initial = try scan(usage: usage)
        XCTAssertEqual(initial.apps.map(\.path), [installed.path])
        XCTAssertEqual(initial.unreadable, 0)
        let outside = home.appendingPathComponent("outside")
        try fm.moveItem(at: vendor, to: outside)
        try fm.createSymbolicLink(at: vendor, withDestinationURL: outside)
        XCTAssertEqual(clean(initial.apps, usage: usage).skipped.count, 1)
        XCTAssertTrue(try scan(usage: usage).apps.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("Test.app").path))
    }

    func testThresholdLowerBoundNewInstallsUnreadableBundlesAndCancellation() throws {
        let app = try makeApp("Eligible", in: userApps)
        let usage = [app.path: ago(80)]
        XCTAssertTrue(try scan(age: 90, usage: usage).apps.isEmpty)
        let thirty = try scan(age: 30, usage: usage)
        XCTAssertEqual(thirty.apps.map(\.path), [app.path])
        XCTAssertEqual(clean(thirty.apps, usage: usage, age: 90).skipped.count, 1)
        XCTAssertTrue(try scan(age: 0, usage: [app.path: ago(20)]).apps.isEmpty)
        // Today's creation date is recent even if a copied app has an old Spotlight usage record.
        let fresh = try UnusedApps.scan(home: home.path, applicationsRoot: systemApps.path, now: Date(),
                                        lastUsed: { _ in Date.distantPast }, added: { _ in nil },
                                        running: { RunningAppSnapshot() })
        XCTAssertTrue(fresh.apps.isEmpty)
        try Data([1]).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(try scan(usage: usage).unreadable, 1)
        XCTAssertThrowsError(try UnusedApps.scan(home: home.path, applicationsRoot: systemApps.path,
                                                 running: { RunningAppSnapshot() }, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
