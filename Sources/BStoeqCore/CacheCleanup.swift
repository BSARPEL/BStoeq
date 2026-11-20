import Foundation

/// A file that the scan actually inspected. Keep the metadata used to recognize it
/// private so cleanup can only accept candidates from a scan.
public struct CacheFile: Sendable {
    public let path: String
    public let bytes: Int64
    fileprivate let root: CacheRoot
    fileprivate let stamp: FileStamp
}

fileprivate struct FileStamp: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modified, accessed, changed: timespec

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        size = status.st_size
        modified = status.st_mtimespec
        accessed = status.st_atimespec
        changed = status.st_ctimespec
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        func same(_ a: timespec, _ b: timespec) -> Bool {
            a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec
        }
        return lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && same(lhs.modified, rhs.modified) && same(lhs.accessed, rhs.accessed) && same(lhs.changed, rhs.changed)
    }
}

public struct CacheGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let source: CacheSource
    public let files: [CacheFile]
    public let bytes: Int64

    public init(id: String, files: [CacheFile]) {
        self.init(id: id, name: id, source: .userCaches, files: files)
    }

    public init(id: String, name: String, source: CacheSource, files: [CacheFile]) {
        self.id = id
        self.name = name
        self.source = source
        self.files = files
        bytes = files.reduce(0) { $0 + $1.bytes }
    }

    public func replacingFiles(_ files: [CacheFile]) -> CacheGroup {
        CacheGroup(id: id, name: name, source: source, files: files)
    }
}

public struct CacheScanResult: Sendable {
    public let groups: [CacheGroup]
    public let unreadable: Int
    public let sources: [CacheSourceReport]

    fileprivate init(groups: [CacheGroup], unreadable: Int, sources: [CacheSourceReport] = []) {
        self.groups = groups
        self.unreadable = unreadable
        self.sources = sources
    }
}

public struct CacheSourceReport: Sendable {
    public let source: CacheSource
    public let scannedRoots: Int
    public let unreadable: Int
}

public struct CacheCleanResult: Sendable {
    public fileprivate(set) var moved: [CacheFile] = []
    public fileprivate(set) var skipped: [CacheFile] = []
    public fileprivate(set) var failed: [CacheFile] = []
}

public enum CacheCleanup {
    private static let minimumAge: TimeInterval = 30 * 24 * 60 * 60
    private static let excludedFlags = UInt32(SF_DATALESS | SF_RESTRICTED | SF_NOUNLINK | SF_FIRMLINK
                                             | SF_IMMUTABLE | UF_IMMUTABLE | SF_APPEND | UF_APPEND)

    /// The home may have a system alias (such as /var). From the resolved home down
    /// every component must be a real, local directory on the same filesystem.
    private struct Location {
        let home: String
        let device: dev_t
        let mounts: Set<String>

        init(home requested: String, mountPoints: Set<String>) throws {
            guard requested.hasPrefix("/"), let home = DiskScanner.canonicalPath(requested), home != "/" else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            var status = stat()
            guard lstat(home, &status) == 0 else { throw posixError(errno) }
            self.home = home
            device = status.st_dev
            let requestedHome = DiskSafety.normalized(requested)
            let actualHome = DiskSafety.normalized(home)
            var mounts = Set(mountPoints.map(DiskSafety.normalized))
            if requestedHome != actualHome {
                for mount in mounts where mount.hasPrefix(requestedHome + "/") {
                    mounts.insert(actualHome + mount.dropFirst(requestedHome.count))
                }
            }
            self.mounts = mounts
            guard validDirectory(status, path: home, allowMount: true) else {
                throw CocoaError(.fileReadNoPermission)
            }
        }

        func validDirectory(_ status: stat, path: String, allowMount: Bool = false) -> Bool {
            status.st_mode & S_IFMT == S_IFDIR && status.st_flags & excludedFlags == 0
                && status.st_dev == device && (allowMount || !mounts.contains(DiskSafety.normalized(path)))
        }

        /// A missing optional path is normal. An inaccessible or unsafe directory is
        /// reported separately so it cannot turn an incomplete scan into an empty one.
        func directory(_ relative: String) throws -> String? {
            var path = home
            for component in relative.split(separator: "/") {
                let name = String(component)
                guard name != ".", name != ".." else { throw CocoaError(.fileReadInvalidFileName) }
                path = DiskListing.join(path, name)
                var status = stat()
                guard lstat(path, &status) == 0 else {
                    if errno == ENOENT || errno == ENOTDIR { return nil }
                    throw posixError(errno)
                }
                guard validDirectory(status, path: path), !isExcludedDirectory(name: name, path: path) else {
                    throw CocoaError(.fileReadNoPermission)
                }
            }
            return path
        }

        func children(_ relative: String, unreadable: inout Int, isCancelled: () -> Bool) throws -> [String] {
            guard let parent = try directory(relative) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: parent).filter { name in
                if isCancelled() { throw CancellationError() }
                guard !name.hasPrefix("."), !name.contains("/") else { return false }
                let path = DiskListing.join(parent, name)
                var status = stat()
                guard lstat(path, &status) == 0 else {
                    if errno != ENOENT { unreadable += 1 }
                    return false
                }
                return validDirectory(status, path: path) && !isExcludedDirectory(name: name, path: path)
            }
        }

        func isChromiumProfile(_ name: String) throws -> Bool {
            guard let path = try directory(CacheRoot.applicationSupport + "/" + name) else { return false }
            func marker(_ component: String, type: mode_t) throws -> Bool {
                var status = stat()
                let markerPath = DiskListing.join(path, component)
                guard lstat(markerPath, &status) == 0 else {
                    if errno == ENOENT { return false }
                    throw posixError(errno)
                }
                return status.st_mode & S_IFMT == type
                    && status.st_dev == device && status.st_flags & excludedFlags == 0
                    && !mounts.contains(DiskSafety.normalized(markerPath))
            }
            return try marker("Local State", type: S_IFREG) || marker("Network Persistent State", type: S_IFREG)
                || (marker("Preferences", type: S_IFREG) && marker("Session Storage", type: S_IFDIR))
        }

        func stillContains(_ file: CacheFile, cutoff: TimeInterval) -> Bool {
            let prefix = DiskListing.join(home, file.root.relativePath) + "/"
            guard file.path.hasPrefix(prefix), !mounts.contains(DiskSafety.normalized(file.path)) else { return false }
            let relativeFile = file.path.dropFirst(prefix.count)
            let relativeParent = String(file.path.dropFirst(home.count + 1)) as NSString
            guard (try? directory(relativeParent.deletingLastPathComponent)) != nil else { return false }
            if case .chromium(let app, _) = file.root, (try? isChromiumProfile(app)) != true { return false }
            // O_EVTONLY inspects the inode without reading bytes or updating its access
            // time. O_NOFOLLOW_ANY also rejects a link swapped into an ancestor during
            // the checks above.
            let fd = open(file.path, O_EVTONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var status = stat()
            guard fstat(fd, &status) == 0, eligible(status, device: device, cutoff: cutoff) else { return false }
            return FileStamp(status) == file.stamp && Int64(status.st_blocks) * 512 == file.bytes
                && file.root.accepts(relativeFile: relativeFile, path: file.path, status: status, cutoff: cutoff)
        }
    }

    public static func scan(home: String, now: Date = Date(),
                            mountPoints: Set<String> = DiskScanner.mountPoints(),
                            progress: (CacheSource) -> Void = { _ in },
                            isCancelled: () -> Bool = { false }) throws -> CacheScanResult {
        try usingLocalData {
            if isCancelled() { throw CancellationError() }
            let location = try Location(home: home, mountPoints: mountPoints)
            let cutoff = now.timeIntervalSince1970 - minimumAge
            var groups: [CacheGroup] = [], unreadable = 0, completed = 0
            var reports: [CacheSourceReport] = []
            for source in CacheSource.allCases {
                if isCancelled() { throw CancellationError() }
                progress(source)
                let priorRoots = completed, priorErrors = unreadable
                defer {
                    reports.append(CacheSourceReport(source: source, scannedRoots: completed - priorRoots,
                                                     unreadable: unreadable - priorErrors))
                }
                let roots: [CacheRoot]
                do {
                    roots = try rootsForSource(source, in: location, unreadable: &unreadable, isCancelled: isCancelled)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    unreadable += 1
                    continue
                }
                for root in roots {
                    if isCancelled() { throw CancellationError() }
                    do {
                        guard let path = try location.directory(root.relativePath) else { continue }
                        let part = try scan(root, at: path, in: location, cutoff: cutoff, isCancelled: isCancelled)
                        groups.append(contentsOf: part.groups)
                        unreadable += part.unreadable
                        completed += 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        unreadable += 1
                    }
                }
            }
            if isCancelled() { throw CancellationError() }
            guard completed > 0 else {
                throw CocoaError(unreadable == 0 ? .fileReadNoSuchFile : .fileReadNoPermission)
            }
            groups.sort { left, right in
                if left.bytes == right.bytes { return left.id < right.id }
                return left.bytes > right.bytes
            }
            return CacheScanResult(groups: groups, unreadable: unreadable, sources: reports)
        }
    }

    private static func rootsForSource(_ source: CacheSource, in location: Location,
                                       unreadable: inout Int, isCancelled: () -> Bool) throws -> [CacheRoot] {
        func children(_ path: String) throws -> [String] {
            try location.children(path, unreadable: &unreadable, isCancelled: isCancelled)
        }
        switch source {
        case .userCaches: return [.user]
        case .containerCaches: return try children(CacheRoot.containers).map(CacheRoot.container)
        case .groupContainerCaches: return try children(CacheRoot.groupContainers).map(CacheRoot.groupContainer)
        case .browserCaches:
            var roots: [CacheRoot] = []
            for app in try children(CacheRoot.applicationSupport) {
                if isCancelled() { throw CancellationError() }
                do {
                    guard try location.isChromiumProfile(app) else { continue }
                } catch {
                    unreadable += 1
                    continue
                }
                for area in ["Cache/Cache_Data", "GPUCache", "Code Cache/js", "Code Cache/wasm"] {
                    roots.append(.chromium(app: app, area: area))
                }
            }
            return roots
        case .logs: return [.logs]
        case .installers: return [.installers]
        case .developerCaches: return [.npmTemporary, .pipWheels, .gradleBuildCache]
        case .xcode:
            var roots: [CacheRoot] = [.xcodeShared("ModuleCache.noindex"), .xcodeShared("SDKStatCaches.noindex")]
            for name in try children(CacheRoot.derivedData) where !name.hasSuffix(".noindex") {
                roots.append(.xcodeProject(name: name, area: "Index.noindex"))
                roots.append(.xcodeProject(name: name, area: "Build/Intermediates.noindex"))
            }
            return roots
        }
    }

    private static func scan(_ root: CacheRoot, at path: String, in location: Location, cutoff: TimeInterval,
                             isCancelled: () -> Bool) throws -> CacheScanResult {
        guard access(path, R_OK | X_OK) == 0 else { throw posixError(errno) }
        guard let buffer = strdup(path) else { throw posixError(ENOMEM) }
        defer { free(buffer) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [buffer, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw posixError(errno)
        }
        defer { fts_close(stream) }

        var files: [String: [CacheFile]] = [:]
        var unreadable = 0, visited = 0
        let prefixLength = path.count + 1
        while true {
            if visited.isMultiple(of: 128), isCancelled() { throw CancellationError() }
            errno = 0
            guard let entry = fts_read(stream) else {
                if errno != 0 { throw posixError(errno) }
                break
            }
            visited += 1
            let item = entry.pointee, level = item.fts_level, info = Int32(item.fts_info)
            if level == 0, info != FTS_D && info != FTS_DP {
                throw posixError(item.fts_errno == 0 ? ENOTDIR : item.fts_errno)
            }
            switch info {
            case FTS_D:
                guard let path = String(validatingCString: item.fts_path),
                      location.validDirectory(item.fts_statp.pointee, path: path) else {
                    if level == 0 { throw CocoaError(.fileReadNoPermission) }
                    fts_set(stream, entry, FTS_SKIP)
                    continue
                }
                if level > 0, root.source == .installers || root.source == .browserCaches
                    || isExcludedDirectory(name: (path as NSString).lastPathComponent, path: path) {
                    fts_set(stream, entry, FTS_SKIP)
                }
            case FTS_F:
                let status = item.fts_statp.pointee
                guard eligible(status, device: location.device, cutoff: cutoff),
                      let path = String(validatingCString: item.fts_path),
                      !location.mounts.contains(DiskSafety.normalized(path)),
                      !isStoreFile((path as NSString).lastPathComponent) else { continue }
                let relative = path.dropFirst(prefixLength)
                guard root.accepts(relativeFile: relative, path: path, status: status, cutoff: cutoff) else { continue }
                files[root.groupName(for: relative), default: []].append(
                    CacheFile(path: path, bytes: Int64(status.st_blocks) * 512, root: root, stamp: FileStamp(status))
                )
            case FTS_DNR, FTS_ERR, FTS_NS:
                if item.fts_errno != ENOENT { unreadable += 1 }
            default:
                break
            }
        }
        let groups = files.map { name, batch in
            CacheGroup(id: root.groupID(name: name), name: name, source: root.source, files: batch)
        }
        return CacheScanResult(groups: groups, unreadable: unreadable)
    }

    public static func clean(_ files: [CacheFile], home: String, now: Date = Date(),
                             mountPoints: Set<String> = DiskScanner.mountPoints(),
                             isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in },
                             moveToTrash: (URL) throws -> Void) -> CacheCleanResult {
        usingLocalData {
            var result = CacheCleanResult()
            guard !files.isEmpty, !isCancelled() else { return result }
            let location = try? Location(home: home, mountPoints: mountPoints)
            let cutoff = now.timeIntervalSince1970 - minimumAge
            var processed = 0, lastReport = 0
            for file in files {
                if isCancelled() { break }
                defer {
                    processed += 1
                    if processed == 1 || processed.isMultiple(of: 32) {
                        lastReport = processed
                        progress(processed)
                    }
                }
                guard let location, location.stillContains(file, cutoff: cutoff) else {
                    result.skipped.append(file)
                    continue
                }
                do {
                    try moveToTrash(URL(fileURLWithPath: file.path, isDirectory: false))
                    result.moved.append(file)
                } catch {
                    result.failed.append(file)
                }
            }
            if processed > lastReport { progress(processed) }
            return result
        }
    }

    private static func eligible(_ status: stat, device: dev_t, cutoff: TimeInterval) -> Bool {
        return status.st_dev == device && status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1
            && status.st_flags & excludedFlags == 0 && status.st_blocks > 0
            && isOld(status.st_atimespec, cutoff: cutoff) && isOld(status.st_mtimespec, cutoff: cutoff)
    }

    static func isOld(_ time: timespec, cutoff: TimeInterval) -> Bool {
        time.tv_sec > 0 && Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000 <= cutoff
    }

    /// Stores may need old pages, and signed bundles need their resources intact.
    private static func isExcludedDirectory(name: String, path: String) -> Bool {
        let name = name.lowercased()
        var marker = stat()
        if name.hasSuffix(".app") {
            // A bundle identifier ending in ".app" is also a common cache folder name.
            // Both the macOS bundle layout and the flat layout identify a real package.
            if lstat(DiskListing.join(path, "Contents"), &marker) == 0
                || lstat(DiskListing.join(path, "Info.plist"), &marker) == 0 { return true }
        } else if name.contains(".") && !name.hasPrefix(".") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
        }
        if [".git", ".venv", "venv", "virtualenvs", "node_modules", "site-packages", "checkouts",
            "repositories", "indexeddb", "leveldb"].contains(name) { return true }
        if lstat(DiskListing.join(path, "pyvenv.cfg"), &marker) == 0
            || lstat(DiskListing.join(path, ".git"), &marker) == 0
            || lstat(DiskListing.join(path, "conda-meta"), &marker) == 0 { return true }
        return [".leveldb", ".framework", ".bundle", ".xpc", ".appex", ".xcarchive", ".dsym", ".sparsebundle",
                ".photoslibrary", ".xcworkspace", ".xcodeproj"].contains(where: name.hasSuffix)
    }

    private static func isStoreFile(_ name: String) -> Bool {
        let name = name.lowercased()
        if name == "lock" || name == "lockfile" { return true }
        return [".lock", ".lck", ".db", ".db3", ".sqlite", ".sqlite3", ".ldb", ".sst",
                "-wal", "-shm", "-journal"].contains(where: name.hasSuffix)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func usingLocalData<T>(_ operation: () throws -> T) rethrows -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(type, scope)
        if previous >= 0 { setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) }
        defer { if previous >= 0 { setiopolicy_np(type, scope, previous) } }
        return try operation()
    }
}
