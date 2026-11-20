import AppKit
import CoreServices

/// A third-party application with an old, known LaunchServices usage record.
public struct UnusedApp: Identifiable, Sendable {
    public var id: String { path }
    public let path, name, bundleIdentifier, version: String
    public let lastUsed: Date
    public let bytes: Int64
    fileprivate let minimumAgeDays: Int
    fileprivate let identity: AppIdentity
}

/// An installed app for manual review. Cleanup accepts only a reviewed UnusedApp.
public struct AppWithUnknownUsage: Identifiable, Sendable {
    public var id: String { path }
    public let path, name: String
}

public struct UnusedAppScanResult: Sendable {
    public fileprivate(set) var apps: [UnusedApp] = []
    /// Otherwise eligible applications without a usable Spotlight usage record.
    public var unassessable: Int { unknownUsageApps.count }
    public fileprivate(set) var unknownUsageApps: [AppWithUnknownUsage] = []
    public fileprivate(set) var unreadable = 0
}

public struct UnusedAppCleanResult: Sendable {
    public fileprivate(set) var moved: [UnusedApp] = []
    public fileprivate(set) var skipped: [UnusedApp] = []
    public fileprivate(set) var failed: [UnusedApp] = []
}

public struct RunningAppSnapshot: Sendable {
    let identifiers: Set<String>
    let paths: Set<String>

    public init(identifiers: Set<String> = [], paths: Set<String> = []) {
        self.identifiers = identifiers
        self.paths = paths
    }

    public static func current() -> Self {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let paths = apps.flatMap { [$0.bundleURL?.path, $0.executableURL?.path] }.compactMap { $0 }
        return Self(identifiers: Set(apps.compactMap(\.bundleIdentifier)), paths: Set(paths))
    }

    func contains(_ identifier: String, path: String) -> Bool {
        identifiers.contains(identifier) || paths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
}

fileprivate struct AppFileStamp: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let bytes: off_t
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
    let flags: UInt32
    let changedSeconds, changedNanos, modifiedSeconds, modifiedNanos: Int

    init(_ s: stat) {
        device = s.st_dev
        inode = s.st_ino
        bytes = s.st_size
        owner = s.st_uid
        group = s.st_gid
        mode = s.st_mode
        flags = s.st_flags
        changedSeconds = s.st_ctimespec.tv_sec
        changedNanos = s.st_ctimespec.tv_nsec
        modifiedSeconds = s.st_mtimespec.tv_sec
        modifiedNanos = s.st_mtimespec.tv_nsec
    }
}

fileprivate struct AppIdentity: Equatable, Sendable {
    let directory, info, executable: AppFileStamp
    let identifier, version, build, executableName: String
    let tree: AppTreeStamp
}

fileprivate struct AppTreeStamp: Equatable, Sendable {
    var bytes: Int64 = 0
    var entries = 0
    var fingerprint: UInt64 = 0
}

public enum UnusedApps {
    public static let minimumAgeDays = 180
    private static let protectedFlags = UInt32(SF_DATALESS | SF_RESTRICTED | SF_NOUNLINK | SF_FIRMLINK |
                                               SF_IMMUTABLE | UF_IMMUTABLE | SF_APPEND | UF_APPEND)
    private static let maximumGroupDepth = 2

    /// LaunchServices records opens. A missing or disabled Spotlight index gives no usage evidence.
    public static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    public static func dateAdded(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
    }

    private struct Roots {
        let paths: Set<String>
        let mounts: Set<String>

        init(home: String, applicationsRoot: String, mounts: Set<String>) {
            var requested = [applicationsRoot]
            if let home = DiskScanner.canonicalPath(home), home != "/" {
                requested.append(DiskListing.join(home, "Applications"))
            }
            paths = Set(requested.filter { $0.hasPrefix("/") && $0 != "/" })
            self.mounts = Set(mounts.map(DiskSafety.normalized))
        }

        /// A mount inside an app would be moved along with its containing bundle.
        func containsMount(_ path: String) -> Bool {
            let normalized = DiskSafety.normalized(path)
            return mounts.contains { $0 == normalized || $0.hasPrefix(normalized + "/") }
        }

        func isSafeDirectory(_ path: String) -> Bool {
            guard let info = status(path), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_flags & UInt32(SF_DATALESS) == 0, !mounts.contains(DiskSafety.normalized(path)),
                  DiskScanner.canonicalPath(path) == path else { return false }
            return true
        }

        /// Accept only the same install roots and plain grouping directories used by the scan.
        func containsApp(_ path: String) -> Bool {
            guard let root = paths.first(where: { path.hasPrefix($0 + "/") }), isSafeDirectory(root) else { return false }
            let relative = path.dropFirst(root.count + 1).split(separator: "/")
            guard !relative.isEmpty, relative.count <= maximumGroupDepth + 1 else { return false }
            var parent = root
            for part in relative.dropLast() {
                parent = DiskListing.join(parent, String(part))
                guard isSafeDirectory(parent), isGroup(URL(fileURLWithPath: parent)) else { return false }
            }
            return !containsMount(path) && isSafeDirectory(path)
        }
    }

    private enum Assessment {
        case eligible(UnusedApp), excluded, unknownUsage(AppWithUnknownUsage), unreadable
    }

    /// Reports an application path before inspecting it. Never descends into other packages.
    public static func scan(home: String = NSHomeDirectory(), applicationsRoot: String = "/Applications",
                            now: Date = Date(), minimumAgeDays: Int = UnusedApps.minimumAgeDays,
                            mountPoints: Set<String> = DiskScanner.mountPoints(),
                            lastUsed: (URL) -> Date? = UnusedApps.lastUsedDate,
                            added: (URL) -> Date? = UnusedApps.dateAdded,
                            running: () -> RunningAppSnapshot = RunningAppSnapshot.current,
                            isCancelled: () -> Bool = { false }, progress: (String) -> Void = { _ in }) throws -> UnusedAppScanResult {
        let previousPolicy = disableCloudDownloads()
        defer { restoreCloudPolicy(previousPolicy) }
        let roots = Roots(home: home, applicationsRoot: applicationsRoot, mounts: mountPoints)
        var result = UnusedAppScanResult()
        let active = running()
        let age = max(30, minimumAgeDays)
        let cutoff = now.addingTimeInterval(-Double(age) * 86_400)
        var seenApps = Set<String>()
        func visit(_ directory: String, depth: Int) throws {
            if isCancelled() { throw CancellationError() }
            guard status(directory) != nil else {
                if errno != ENOENT { result.unreadable += 1 }
                return
            }
            guard roots.isSafeDirectory(directory) else { result.unreadable += 1; return }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            } catch {
                result.unreadable += 1
                return
            }
            for url in entries {
                if isCancelled() { throw CancellationError() }
                guard let info = status(url.path) else { result.unreadable += 1; continue }
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
                if url.pathExtension.lowercased() == "app" {
                    guard seenApps.insert(url.path).inserted, roots.containsApp(url.path) else { continue }
                    progress(url.path)
                    switch try assess(url, cutoff: cutoff, minimumAgeDays: age, lastUsed: lastUsed, added: added,
                                      active: active, isCancelled: isCancelled) {
                    case .eligible(let app): result.apps.append(app)
                    case .unknownUsage(let item): result.unknownUsageApps.append(item)
                    case .unreadable: result.unreadable += 1
                    case .excluded: break
                    }
                } else if depth < maximumGroupDepth, isGroup(url), !roots.mounts.contains(DiskSafety.normalized(url.path)) {
                    try visit(url.path, depth: depth + 1)
                }
            }
        }
        for root in roots.paths { try visit(root, depth: 0) }
        if isCancelled() { throw CancellationError() }
        result.apps.sort { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
        result.unknownUsageApps.sort { $0.name == $1.name ? $0.path < $1.path : $0.name < $1.name }
        return result
    }

    public static func clean(_ apps: [UnusedApp], home: String = NSHomeDirectory(), applicationsRoot: String = "/Applications",
                             now: Date = Date(), minimumAgeDays: Int = UnusedApps.minimumAgeDays,
                             mountPoints: () -> Set<String> = DiskScanner.mountPoints,
                             lastUsed: (URL) -> Date? = UnusedApps.lastUsedDate,
                             added: (URL) -> Date? = UnusedApps.dateAdded,
                             running: () -> RunningAppSnapshot = RunningAppSnapshot.current,
                             isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in },
                             moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> UnusedAppCleanResult {
        let previousPolicy = disableCloudDownloads()
        defer { restoreCloudPolicy(previousPolicy) }
        var result = UnusedAppCleanResult()
        for (index, app) in apps.enumerated() {
            if isCancelled() { break }
            let age = max(30, minimumAgeDays, app.minimumAgeDays)
            let cutoff = now.addingTimeInterval(-Double(age) * 86_400)
            let mounts = mountPoints(), url = URL(fileURLWithPath: app.path)
            let roots = Roots(home: home, applicationsRoot: applicationsRoot, mounts: mounts)
            guard roots.containsApp(app.path),
                  case .eligible(let live) = try? assess(url, cutoff: cutoff, minimumAgeDays: age, lastUsed: lastUsed, added: added,
                                                        active: running(), isCancelled: isCancelled),
                  live.identity == app.identity, live.lastUsed == app.lastUsed, live.bytes == app.bytes,
                  // Measuring a large bundle can take time. Check again immediately before handing it to Finder.
                  !running().contains(app.bundleIdentifier, path: app.path),
                  lastUsed(url) == app.lastUsed,
                  Roots(home: home, applicationsRoot: applicationsRoot, mounts: mountPoints()).containsApp(app.path),
                  let dir = status(app.path), AppFileStamp(dir) == app.identity.directory else {
                if isCancelled() { break }
                result.skipped.append(app)
                progress(index + 1)
                continue
            }
            if isCancelled() { break }
            do { try moveToTrash(url); result.moved.append(app) }
            catch { result.failed.append(app) }
            progress(index + 1)
        }
        return result
    }

    private static func disableCloudDownloads() -> Int32 {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(type, scope)
        if previous >= 0 { setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) }
        return previous
    }

    private static func restoreCloudPolicy(_ previous: Int32) {
        if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
    }

    /// Measure a physical walk, without storing paths or following framework symlinks. Hash
    /// each name with its inode, ownership, flags and nanosecond change times. Combining the
    /// entry hashes commutatively keeps the stamp independent of directory enumeration order.
    private static func measure(_ root: String, device: dev_t, cutoff: Date,
                                isCancelled: () -> Bool) throws -> AppTreeStamp? {
        guard let path = strdup(root) else { return nil }
        defer { free(path) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(stream) }
        var result = AppTreeStamp()
        var hardLinks: Set<ino_t> = []
        while true {
            if result.entries.isMultiple(of: 64), isCancelled() { throw CancellationError() }
            errno = 0
            guard let entry = fts_read(stream) else { return errno == 0 ? result : nil }
            let item = entry.pointee
            switch Int32(item.fts_info) {
            case FTS_DP: continue
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE: break
            default: return nil  // Unreadable subtree, unsupported file type or concurrent removal.
            }
            let info = item.fts_statp.pointee
            guard info.st_dev == device, info.st_flags & protectedFlags == 0 else { return nil }
            guard oldEnough(info, cutoff: cutoff) else { throw RecentlyChanged() }
            var hash = Hasher()
            hash.combine(bytes: UnsafeRawBufferPointer(start: item.fts_path, count: Int(item.fts_pathlen)))
            hash.combine(AppFileStamp(info))
            hash.combine(info.st_nlink)
            hash.combine(info.st_blocks)
            result.fingerprint &+= UInt64(bitPattern: Int64(hash.finalize()))
            result.entries += 1
            if info.st_mode & S_IFMT == S_IFDIR || info.st_nlink == 1 || hardLinks.insert(info.st_ino).inserted {
                result.bytes += Int64(info.st_blocks) * 512
            }
        }
    }

    private struct RecentlyChanged: Error {}

    private static func status(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private static func isGroup(_ url: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."), url.pathExtension.isEmpty,
              let properties = try? url.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey]) else { return false }
        return properties.isAliasFile == false && properties.isPackage == false
    }

    private static func oldEnough(_ info: stat, cutoff: Date) -> Bool {
        [info.st_birthtimespec, info.st_mtimespec, info.st_ctimespec].allSatisfy {
            $0.tv_sec > 0 && Double($0.tv_sec) + Double($0.tv_nsec) / 1e9 <= cutoff.timeIntervalSince1970
        }
    }

    private static func assess(_ url: URL, cutoff: Date, minimumAgeDays: Int,
                               lastUsed: (URL) -> Date?, added: (URL) -> Date?,
                               active: RunningAppSnapshot, isCancelled: () -> Bool) throws -> Assessment {
        let path = url.path
        guard let bundle = status(path), bundle.st_flags & protectedFlags == 0,
              let properties = try? url.resourceValues(forKeys: [.isAliasFileKey]), properties.isAliasFile == false else { return .excluded }
        let metadataFolder: URL
        let binaryFolder: URL
        let contents = url.appendingPathComponent("Contents")
        if let directory = status(contents.path) {
            guard directory.st_mode & S_IFMT == S_IFDIR, directory.st_flags & protectedFlags == 0,
                  directory.st_dev == bundle.st_dev else { return .unreadable }
            metadataFolder = contents
            binaryFolder = contents.appendingPathComponent("MacOS")
        } else {
            // Apple Silicon wraps iOS apps in a second bundle. Read the wrapper's link
            // text, then inspect its actual directory only if it is a direct child of Wrapper.
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path + "/WrappedBundle") else { return .unreadable }
            let parts = target.components(separatedBy: "/")
            guard parts.count == 2, parts[0] == "Wrapper", !parts[1].hasPrefix("."), parts[1].lowercased().hasSuffix(".app") else { return .unreadable }
            let inner = url.appendingPathComponent(target)
            guard DiskScanner.canonicalPath(inner.path) == inner.path, let directory = status(inner.path),
                  directory.st_mode & S_IFMT == S_IFDIR, directory.st_dev == bundle.st_dev,
                  directory.st_flags & protectedFlags == 0 else { return .unreadable }
            metadataFolder = inner
            binaryFolder = inner
        }
        let plist = metadataFolder.appendingPathComponent("Info.plist")
        // Read fresh data: Foundation's Bundle cache may still describe a replaced app.
        let fd = open(plist.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { return .unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var manifest = stat()
        guard fstat(fd, &manifest) == 0, manifest.st_mode & S_IFMT == S_IFREG, manifest.st_flags & protectedFlags == 0,
              manifest.st_size > 0, manifest.st_size <= 4 * 1024 * 1024,
              let data = try? handle.read(upToCount: Int(manifest.st_size)),
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              values["CFBundlePackageType"] as? String == "APPL",
              let id = values["CFBundleIdentifier"] as? String, !id.isEmpty,
              let executable = values["CFBundleExecutable"] as? String, !executable.isEmpty,
              ![".", ".."].contains(executable), !executable.contains("/") else { return .unreadable }
        let normalized = id.lowercased()
        guard normalized != "local.barlet.app", !normalized.hasPrefix("com.apple."), normalized != "com.apple",
              path != Bundle.main.bundlePath, values["LSBackgroundOnly"] as? Bool != true,
              !active.contains(id, path: path) else { return .excluded }

        let executablePath = DiskListing.join(binaryFolder.path, executable)
        guard let binary = status(executablePath), binary.st_mode & S_IFMT == S_IFREG, binary.st_mode & 0o111 != 0, binary.st_flags & protectedFlags == 0,
              DiskScanner.canonicalPath(executablePath) == executablePath else { return .unreadable }
        guard [bundle, manifest, binary].allSatisfy({ oldEnough($0, cutoff: cutoff) }) else { return .excluded }
        guard added(url).map({ $0 <= cutoff }) ?? true else { return .excluded }
        let name = values["CFBundleDisplayName"] as? String ?? values["CFBundleName"] as? String ??
                   url.deletingPathExtension().lastPathComponent
        guard let lastUse = lastUsed(url), lastUse.timeIntervalSince1970 > 0 else {
            return .unknownUsage(AppWithUnknownUsage(path: path, name: name))
        }
        guard lastUse <= cutoff else { return .excluded }
        let tree: AppTreeStamp
        do {
            guard let measured = try measure(path, device: bundle.st_dev, cutoff: cutoff, isCancelled: isCancelled) else {
                return .unreadable
            }
            tree = measured
        } catch is RecentlyChanged { return .excluded }
        let version = values["CFBundleShortVersionString"] as? String ?? ""
        let build = values["CFBundleVersion"] as? String ?? ""
        guard !version.isEmpty || !build.isEmpty else { return .unreadable }
        let identity = AppIdentity(directory: AppFileStamp(bundle), info: AppFileStamp(manifest),
                                   executable: AppFileStamp(binary), identifier: id,
                                   version: version, build: build, executableName: executable, tree: tree)
        return .eligible(UnusedApp(path: path, name: name, bundleIdentifier: id, version: version.isEmpty ? build : version,
                                   lastUsed: lastUse, bytes: tree.bytes, minimumAgeDays: minimumAgeDays, identity: identity))
    }
}
