import Foundation

/// A third-party application the user may remove.
public struct InstalledApp: Identifiable, Sendable {
    public var id: String { path }
    public let path, name, bundleIdentifier, version: String
    /// Folder names the app may have used for its data, besides its identifier.
    fileprivate let dataNames: [String]
    fileprivate let bundle, info: AppFileStamp
}

/// Something an application left in the user's Library.
public struct AppLeftover: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case support, caches, preferences, savedState, webData, logs, container, scripts, launchAgent

        public var titleKey: String {
            switch self {
            case .support: "Uygulama verileri"
            case .caches: "Önbellek"
            case .preferences: "Tercihler"
            case .savedState: "Kayıtlı pencere durumu"
            case .webData: "Web verileri"
            case .logs: "Günlükler"
            case .container: "Korumalı alan verileri"
            case .scripts: "Uygulama betikleri"
            case .launchAgent: "Başlangıç öğesi"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let kind: Kind
    /// `nil` when the contents could not be read, so the size is unknown.
    public let bytes: Int64?
    /// Found under the app's name rather than its identifier: a weaker match,
    /// since two developers may pick the same name.
    public let matchedByName: Bool
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
}

public struct AppUninstallPlan: Sendable {
    public let app: InstalledApp
    public let appBytes: Int64
    public let leftovers: [AppLeftover]
    /// Another installed copy has the same identifier and uses the same data, so
    /// none of it is offered.
    public let sharesData: Bool
}

public struct AppUninstallResult: Sendable {
    public enum Outcome: Equatable, Sendable {
        case moved
        /// The app is open. Nothing was touched.
        case running
        /// The bundle is no longer the one that was inspected. Nothing was touched.
        case changed
        case failed(String)
    }
    public let outcome: Outcome
    public fileprivate(set) var moved: [AppLeftover] = []
    public fileprivate(set) var skipped: [AppLeftover] = []
    public fileprivate(set) var failed: [AppLeftover] = []
}

/// Removes an application together with what it left behind. Everything goes to the
/// Trash; leftovers are taken only from fixed places in the user's Library and only
/// under the exact identifier or name of the app.
public enum AppUninstaller {
    /// An identifier becomes part of a path, and it comes from a file the app's
    /// author wrote. Only plain reverse-DNS names are used to look for data.
    static func isPlainIdentifier(_ identifier: String) -> Bool {
        let bytes = identifier.utf8
        guard bytes.count >= 3, bytes.count <= 155, identifier.contains("."), !identifier.contains(".."),
              !identifier.hasPrefix("."), !identifier.hasSuffix(".") else { return false }
        return bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x2D || byte == 0x5F
        }
    }

    static func isPlainName(_ name: String) -> Bool {
        name.count >= 3 && name.utf8.count <= 100 && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func describe(_ url: URL) -> InstalledApp? {
        let path = url.path
        guard let bundle = UnusedApps.status(path), bundle.st_mode & S_IFMT == S_IFDIR,
              bundle.st_flags & UnusedApps.protectedFlags == 0,
              (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == false,
              let manifest = UnusedApps.manifest(of: url, bundle: bundle) else { return nil }
        let identifier = manifest.identifier, normalized = identifier.lowercased()
        // macOS owns Apple's apps, and BStoeq cannot move itself while it runs.
        guard normalized != "local.barlet.app", normalized != "com.apple", !normalized.hasPrefix("com.apple."),
              path != Bundle.main.bundlePath else { return nil }
        func text(_ key: String) -> String? {
            (manifest.values[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        var names: [String] = []
        for name in [fileName, text("CFBundleName")].compactMap({ $0 }) where isPlainName(name) {
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        }
        return InstalledApp(path: path, name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? fileName,
                            bundleIdentifier: identifier,
                            version: text("CFBundleShortVersionString") ?? text("CFBundleVersion") ?? "",
                            dataNames: names, bundle: AppFileStamp(bundle), info: AppFileStamp(manifest.info))
    }

    /// Applications in `/Applications` and `~/Applications`, including those in plain
    /// grouping folders. Other packages are never entered.
    public static func installedApps(home: String = NSHomeDirectory(), applicationsRoot: String = "/Applications",
                                     mountPoints: Set<String> = DiskScanner.mountPoints()) -> [InstalledApp] {
        let roots = UnusedApps.Roots(home: home, applicationsRoot: applicationsRoot, mounts: mountPoints)
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        func visit(_ directory: String, depth: Int) {
            guard roots.isSafeDirectory(directory),
                  let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for url in entries {
                guard let info = UnusedApps.status(url.path), info.st_mode & S_IFMT == S_IFDIR,
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
                if url.pathExtension.lowercased() == "app" {
                    guard seen.insert(url.path).inserted, roots.containsApp(url.path), let app = describe(url) else { continue }
                    apps.append(app)
                } else if depth < UnusedApps.maximumGroupDepth, UnusedApps.isGroup(url),
                          !roots.mounts.contains(DiskSafety.normalized(url.path)) {
                    visit(url.path, depth: depth + 1)
                }
            }
        }
        for root in roots.paths.sorted() { visit(root, depth: 0) }
        return apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order != .orderedSame ? order == .orderedAscending : $0.path < $1.path
        }
    }

    public static func isRunning(_ app: InstalledApp, in snapshot: RunningAppSnapshot) -> Bool {
        snapshot.contains(app.bundleIdentifier, path: app.path)
    }

    private static func isCurrent(_ app: InstalledApp) -> Bool {
        guard let live = describe(URL(fileURLWithPath: app.path)) else { return false }
        return live.bundle == app.bundle && live.info == app.info && live.bundleIdentifier == app.bundleIdentifier
    }

    /// The user's Library, as a real folder reached without any link.
    private static func library(of home: String) -> (home: String, path: String, device: dev_t)? {
        guard home.hasPrefix("/"), let home = DiskScanner.canonicalPath(home), home != "/" else { return nil }
        let path = DiskListing.join(home, "Library")
        guard DiskScanner.canonicalPath(path) == path, let info = UnusedApps.status(path),
              info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return (home, path, info.st_dev)
    }

    /// A leftover is a plain file or folder that sits directly where it was looked
    /// for: on the Library's own volume, not behind a link, and not a folder macOS
    /// or the account needs.
    private static func resolve(_ path: String, home: String, device: dev_t, mounts: Set<String>) -> (path: String, info: stat)? {
        guard let info = UnusedApps.status(path) else { return nil }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG, info.st_dev == device, info.st_flags & UnusedApps.protectedFlags == 0,
              let real = DiskScanner.canonicalPath(path) else { return nil }
        // The disk may store the name in another letter case than the identifier has.
        guard (real as NSString).deletingLastPathComponent == (path as NSString).deletingLastPathComponent,
              (real as NSString).lastPathComponent.caseInsensitiveCompare((path as NSString).lastPathComponent) == .orderedSame,
              real.hasPrefix(home + "/Library/"),
              !DiskSafety.isProtected(real, home: home, volumes: mounts, ownBundle: Bundle.main.bundlePath) else { return nil }
        return (real, info)
    }

    private static func locations(for app: InstalledApp, among apps: [InstalledApp],
                                  library: String) -> [(path: String, kind: AppLeftover.Kind, byName: Bool)] {
        var found: [(String, AppLeftover.Kind, Bool)] = []
        let identifier = app.bundleIdentifier
        if isPlainIdentifier(identifier) {
            let exact: [(String, AppLeftover.Kind)] = [
                ("Application Support/" + identifier, .support),
                ("Caches/" + identifier, .caches),
                ("Preferences/" + identifier + ".plist", .preferences),
                ("Saved Application State/" + identifier + ".savedState", .savedState),
                ("HTTPStorages/" + identifier, .webData),
                ("HTTPStorages/" + identifier + ".binarycookies", .webData),
                ("WebKit/" + identifier, .webData),
                ("Cookies/" + identifier + ".binarycookies", .webData),
                ("Logs/" + identifier, .logs),
                ("Containers/" + identifier, .container),
                ("Application Scripts/" + identifier, .scripts),
                ("LaunchAgents/" + identifier + ".plist", .launchAgent)
            ]
            found += exact.map { (DiskListing.join(library, $0.0), $0.1, false) }
            // Per-machine preferences carry the hardware identifier between the two.
            let byHost = DiskListing.join(library, "Preferences/ByHost")
            let prefix = identifier.lowercased() + ".", suffix = ".plist"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: byHost)) ?? [] {
                let lowered = name.lowercased()
                guard lowered.hasPrefix(prefix), lowered.hasSuffix(suffix), lowered.count > prefix.count + suffix.count else { continue }
                let machine = lowered.dropFirst(prefix.count).dropLast(suffix.count)
                guard machine.count >= 12, machine.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { continue }
                found.append((DiskListing.join(byHost, name), .preferences, false))
            }
        }
        // A name is only evidence while no other installed app answers to it.
        let taken = apps.filter { $0.path != app.path }.flatMap { [$0.name] + $0.dataNames + [$0.bundleIdentifier] }
        for name in app.dataNames where !taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            for (folder, kind) in [("Application Support", AppLeftover.Kind.support), ("Caches", .caches), ("Logs", .logs)] {
                found.append((DiskListing.join(library, folder + "/" + name), kind, true))
            }
        }
        return found
    }

    /// Measures the app and looks for what it left in the Library. Returns `nil`
    /// when cancelled or when the app is no longer the one that was listed.
    public static func inspect(_ app: InstalledApp, among apps: [InstalledApp], home: String = NSHomeDirectory(),
                               mountPoints: Set<String> = DiskScanner.mountPoints(),
                               isCancelled: () -> Bool = { false }) -> AppUninstallPlan? {
        guard isCurrent(app),
              let measured = DiskScanner.scan(app.path, mountPoints: mountPoints, isCancelled: isCancelled) else { return nil }
        let identifier = app.bundleIdentifier.lowercased()
        let shares = apps.contains { $0.path != app.path && $0.bundleIdentifier.lowercased() == identifier }
        var leftovers: [AppLeftover] = []
        if !shares, let library = library(of: home) {
            let mounts = Set(mountPoints.map(DiskSafety.normalized))
            var seen = Set<String>()
            for location in locations(for: app, among: apps, library: library.path) {
                if isCancelled() { return nil }
                guard let item = resolve(location.path, home: library.home, device: library.device, mounts: mounts),
                      seen.insert(item.path).inserted else { continue }
                var bytes: Int64? = Int64(item.info.st_blocks) * 512
                if item.info.st_mode & S_IFMT == S_IFDIR {
                    let scan = DiskScanner.scan(item.path, mountPoints: mountPoints, isCancelled: isCancelled)
                    if isCancelled() { return nil }
                    // An empty folder holds nothing worth listing.
                    if let root = scan?.root, !root.unreadable, root.fileCount == 0, root.children.isEmpty { continue }
                    bytes = scan.flatMap { $0.unreadable > 0 ? nil : $0.root.size }
                }
                leftovers.append(AppLeftover(path: item.path, kind: location.kind, bytes: bytes,
                                             matchedByName: location.byName,
                                             device: item.info.st_dev, inode: item.info.st_ino))
            }
        }
        leftovers.sort {
            if $0.matchedByName != $1.matchedByName { return !$0.matchedByName }
            let first = $0.bytes ?? -1, second = $1.bytes ?? -1
            return first != second ? first > second : $0.path < $1.path
        }
        return AppUninstallPlan(app: app, appBytes: measured.root.size, leftovers: leftovers, sharesData: shares)
    }

    /// Moves the app to the Trash, then the chosen leftovers of its plan. While the
    /// app is open, was replaced, or cannot be moved, its data stays where it is.
    public static func uninstall(_ plan: AppUninstallPlan, leftovers selection: Set<String>,
                                 home: String = NSHomeDirectory(), applicationsRoot: String = "/Applications",
                                 mountPoints: () -> Set<String> = DiskScanner.mountPoints,
                                 running: () -> RunningAppSnapshot = RunningAppSnapshot.current,
                                 isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in },
                                 moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> AppUninstallResult {
        let app = plan.app
        let roots = UnusedApps.Roots(home: home, applicationsRoot: applicationsRoot, mounts: mountPoints())
        guard roots.containsApp(app.path), isCurrent(app) else { return AppUninstallResult(outcome: .changed) }
        guard !isRunning(app, in: running()) else { return AppUninstallResult(outcome: .running) }
        do { try moveToTrash(URL(fileURLWithPath: app.path)) }
        catch { return AppUninstallResult(outcome: .failed(error.localizedDescription)) }
        var result = AppUninstallResult(outcome: .moved)
        var done = 1
        progress(done)
        guard !plan.sharesData, let library = library(of: home) else { return result }
        for leftover in plan.leftovers where selection.contains(leftover.id) {
            if isCancelled() { break }
            defer { done += 1; progress(done) }
            let mounts = Set(mountPoints().map(DiskSafety.normalized))
            guard let live = resolve(leftover.path, home: library.home, device: library.device, mounts: mounts),
                  live.path == leftover.path, live.info.st_dev == leftover.device, live.info.st_ino == leftover.inode else {
                result.skipped.append(leftover)
                continue
            }
            do { try moveToTrash(URL(fileURLWithPath: leftover.path)); result.moved.append(leftover) }
            catch { result.failed.append(leftover) }
        }
        return result
    }
}
