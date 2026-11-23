import XCTest
@testable import BStoeqCore

final class PermissionProbeTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("barlet-permissions-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for name in ["closed.db", "closed"] { _ = chmod(root.appendingPathComponent(name).path, 0o700) }
        try fm.removeItem(at: root)
    }

    func testFirstExistingProbeDecidesFullDiskAccess() throws {
        let open = root.appendingPathComponent("open.db").path, closed = root.appendingPathComponent("closed.db").path
        let missing = root.appendingPathComponent("missing.db").path
        try Data([1]).write(to: URL(fileURLWithPath: open))
        try Data([1]).write(to: URL(fileURLWithPath: closed))
        XCTAssertEqual(chmod(closed, 0), 0)
        XCTAssertEqual(PermissionProbe.fullDiskAccess(probes: [missing, open, closed]), .granted)
        XCTAssertEqual(PermissionProbe.fullDiskAccess(probes: [missing, closed, open]), .denied)
        XCTAssertEqual(PermissionProbe.fullDiskAccess(probes: [missing]), .unknown)
        XCTAssertEqual(PermissionProbe.fullDiskAccess(probes: []), .unknown)
        XCTAssertEqual(PermissionProbe.fullDiskAccessProbes(home: "/Users/example"),
                       ["/Library/Application Support/com.apple.TCC/TCC.db",
                        "/Users/example/Library/Application Support/com.apple.TCC/TCC.db", "/Users/example/Library/Safari"])
        // A folder is a probe like any other.
        XCTAssertEqual(PermissionProbe.fullDiskAccess(probes: [root.path]), .granted)
    }

    func testFolderAccessTellsReadableClosedAndMissingApart() throws {
        let closed = root.appendingPathComponent("closed")
        try fm.createDirectory(at: closed, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(closed.path, 0), 0)
        XCTAssertEqual(PermissionProbe.folderAccess(root.path), .granted)
        XCTAssertEqual(PermissionProbe.folderAccess(closed.path), .denied)
        XCTAssertEqual(PermissionProbe.folderAccess(root.appendingPathComponent("missing").path), .unknown)
    }
}
