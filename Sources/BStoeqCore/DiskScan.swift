import Foundation

/// One scanned folder. Files are not kept: a full disk holds millions of them, so a
/// folder's own files are read again when it is opened (see `DiskListing`).
///
/// A tree is built on the scanning thread, handed over once, and from then on
/// touched by its one owner only.
public final class DiskNode: @unchecked Sendable {
    public let name: String
    /// Allocated bytes of everything below; a file with several hard links counts once.
    public internal(set) var size: Int64
    /// Files and links below, at any depth.
    public internal(set) var fileCount: Int
    /// The folder could not be opened: its size is unknown, not zero.
    public internal(set) var unreadable = false
    public internal(set) var children: [DiskNode]

    public init(name: String, size: Int64 = 0, fileCount: Int = 0, children: [DiskNode] = []) {
        self.name = name; self.size = size; self.fileCount = fileCount; self.children = children
    }
}

public struct DiskScanProgress: Equatable, Sendable {
    public var files = 0
    public var bytes: Int64 = 0
    /// The path being read when the progress was reported.
    public var path = ""
    public init() {}
}

public struct DiskScanResult: Sendable {
    public let root: DiskNode
    /// Folders and entries that could not be read, usually for lack of permission.
    public let unreadable: Int
    /// Folders left out on purpose: other volumes and cloud-only folders.
    public let skipped: Int
}

public enum DiskScanner {
    private struct FileIdentity: Hashable { let device: dev_t; let inode: ino_t }

    /// The startup disk's data volume shows its folders a second time under this name.
    static let dataVolume = "/System/Volumes/Data"

    /// The one true name of a folder: no symbolic link on the way and the letter case
    /// the disk stores. Whether an item may be trashed is decided by its path, so a
    /// scan must not start from an alias such as a link to the home folder.
    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Every mount point, hidden system volumes included.
    public static func mountPoints() -> Set<String> {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        defer { free(list) }
        var result = Set<String>()
        for index in 0..<Int(count) {
            result.insert(withUnsafePointer(to: &list[index].f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            })
        }
        return result
    }

    /// Walks `root` and adds up what each folder occupies on disk.
    ///
    /// Symbolic links are not followed. A folder that is the mount point of another
    /// volume is left out, while firmlinks (`/Users` on the startup disk) are plain
    /// folders to the walk, so scanning `/` covers the user's data without counting
    /// it a second time under `/System/Volumes/Data`.
    /// Returns `nil` when cancelled or when `root` is not a readable folder.
    public static func scan(_ root: String, mountPoints: Set<String> = [],
                            isCancelled: () -> Bool = { false },
                            progress: (DiskScanProgress) -> Void = { _ in }) -> DiskScanResult? {
        // Listing a cloud-only folder would make its provider fetch it. Refuse that for
        // this thread only, and put the previous policy back afterwards.
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) } }

        guard let rootPath = strdup(root) else { return nil }
        defer { free(rootPath) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        // FTS_NOCHDIR: the working directory belongs to the whole process.
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(stream) }

        // `fts_number` marks how a directory was treated on the way in, so the matching
        // visit on the way out is paired with it whatever fts calls that visit.
        let entered = 1, leftOut = 2
        var rootNode: DiskNode?
        var stack: [DiskNode] = []
        // The startup disk and its data volume report one device number, so a changed
        // device does not reveal a mount point; the path has to be compared. Building
        // a string for every folder would be wasteful: only paths as long as a mount
        // point are looked at. A volume mounted below the data volume is reachable
        // under both of its names.
        let aliasPrefix = dataVolume + "/"
        var mounts = mountPoints
        for mount in mountPoints {
            mounts.insert(mount.hasPrefix(aliasPrefix) ? String(mount.dropFirst(dataVolume.count)) : dataVolume + mount)
        }
        let mountLengths = Set(mounts.map(\.utf8.count))
        var linked = Set<FileIdentity>()
        var state = DiskScanProgress()
        var unreadable = 0, skipped = 0
        var visited = 0
        var lastReport = DispatchTime.now().uptimeNanoseconds

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                let status = entry.pointee.fts_statp.pointee
                if entry.pointee.fts_level > 0 {
                    var leaveOut = status.st_flags & UInt32(SF_DATALESS) != 0
                    if !leaveOut, mountLengths.contains(Int(entry.pointee.fts_pathlen)) {
                        leaveOut = mounts.contains(String(cString: entry.pointee.fts_path))
                    }
                    if leaveOut {
                        skipped += 1
                        entry.pointee.fts_number = leftOut
                        fts_set(stream, entry, FTS_SKIP)
                        continue
                    }
                }
                let node = DiskNode(name: entry.pointee.fts_level == 0 ? root : name(of: entry),
                                    size: Int64(status.st_blocks) * 512)
                state.bytes += node.size
                entry.pointee.fts_number = entered
                if let parent = stack.last { parent.children.append(node) } else { rootNode = node }
                stack.append(node)
            case FTS_DP, FTS_DNR, FTS_ERR, FTS_DC:
                guard entry.pointee.fts_number == entered else {
                    if info == FTS_ERR { unreadable += 1 }
                    continue
                }
                guard let node = stack.popLast() else { continue }
                if info != FTS_DP, !node.unreadable { node.unreadable = true; unreadable += 1 }
                if let parent = stack.last { parent.size += node.size; parent.fileCount += node.fileCount }
            case FTS_NS, FTS_NSOK:
                // A file that vanished between listing and reading is not a permission
                // problem. One that may not be examined means its folder is closed to
                // us even though it could be listed; count that folder once.
                let reason = entry.pointee.fts_errno
                if reason == ENOENT { break }
                if let folder = stack.last, reason == EACCES || reason == EPERM {
                    if !folder.unreadable { folder.unreadable = true; unreadable += 1 }
                } else {
                    unreadable += 1
                }
            default:
                guard let folder = stack.last else { return nil }  // The root is a file.
                let status = entry.pointee.fts_statp.pointee
                if status.st_nlink > 1,
                   !linked.insert(FileIdentity(device: status.st_dev, inode: status.st_ino)).inserted { continue }
                let bytes = Int64(status.st_blocks) * 512
                folder.size += bytes; folder.fileCount += 1
                state.bytes += bytes; state.files += 1
            }
            visited += 1
            if visited & 1023 == 0 {
                if isCancelled() { return nil }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastReport >= 100_000_000 {
                    lastReport = now
                    state.path = String(cString: entry.pointee.fts_path)
                    progress(state)
                }
            }
        }
        guard let rootNode, !isCancelled() else { return nil }
        // An interrupted walk leaves folders open; close them so totals stay consistent.
        while let node = stack.popLast() {
            if let parent = stack.last { parent.size += node.size; parent.fileCount += node.fileCount }
        }
        return DiskScanResult(root: rootNode, unreadable: unreadable, skipped: skipped)
    }

    private static func name(of entry: UnsafeMutablePointer<FTSENT>) -> String {
        let offset = Int(entry.pointee.fts_pathlen) - Int(entry.pointee.fts_namelen)
        return String(cString: UnsafePointer(entry.pointee.fts_path.advanced(by: max(0, offset))))
    }
}

/// What a folder holds right now, as read from the disk.
public struct DiskItem: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    /// Allocated bytes of a file or link; zero for a folder, whose total comes from the scan.
    public let size: Int64
    /// A file with other hard links: the scan charged it to one folder only, and
    /// removing this name frees nothing while the others remain.
    public let linked: Bool
    /// Kept by a cloud provider and not downloaded: it occupies nothing here, and
    /// removing it removes it from the cloud.
    public let cloudOnly: Bool
    public init(name: String, isDirectory: Bool, size: Int64, linked: Bool = false, cloudOnly: Bool = false) {
        self.name = name; self.isDirectory = isDirectory; self.size = size
        self.linked = linked; self.cloudOnly = cloudOnly
    }
}

/// A line of the browser: a live item joined with what the scan knows about it.
public struct DiskRow: Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    /// `nil` for a folder the scan left out or that appeared after it.
    public let size: Int64?
    public let fileCount: Int?
    public let unreadable: Bool
    public let node: DiskNode?
    public let linked: Bool
    public let cloudOnly: Bool
    /// A folder the scan has no total for: what moving it would do is unknown.
    public var unmeasured: Bool { isDirectory && node == nil }

    public init(name: String, path: String, isDirectory: Bool, size: Int64?, fileCount: Int?,
                unreadable: Bool, node: DiskNode?, linked: Bool = false, cloudOnly: Bool = false) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.size = size
        self.fileCount = fileCount; self.unreadable = unreadable; self.node = node
        self.linked = linked; self.cloudOnly = cloudOnly
    }
}

public enum DiskListing {
    public static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// Reads one folder without descending. Links are reported as files, never followed.
    public static func items(at path: String, fileManager: FileManager = .default) throws -> [DiskItem] {
        try fileManager.contentsOfDirectory(atPath: path).compactMap { name in
            var status = stat()
            guard lstat(join(path, name), &status) == 0 else { return nil }
            let isDirectory = status.st_mode & S_IFMT == S_IFDIR
            return DiskItem(name: name, isDirectory: isDirectory, size: isDirectory ? 0 : Int64(status.st_blocks) * 512,
                            linked: !isDirectory && status.st_nlink > 1,
                            cloudOnly: status.st_flags & UInt32(SF_DATALESS) != 0)
        }
    }

    /// Largest first; folders of unknown size last. Names break ties so the order is stable.
    public static func rows(_ items: [DiskItem], of node: DiskNode, at path: String) -> [DiskRow] {
        let folders = Dictionary(node.children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return items.map { item -> DiskRow in
            let child = item.isDirectory ? folders[item.name] : nil
            return DiskRow(name: item.name, path: join(path, item.name), isDirectory: item.isDirectory,
                           size: item.isDirectory ? child?.size : item.size, fileCount: child?.fileCount,
                           unreadable: child?.unreadable ?? false, node: child,
                           linked: item.linked, cloudOnly: item.cloudOnly)
        }.sorted {
            let first = $0.size ?? -1, second = $1.size ?? -1
            return first != second ? first > second : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

public enum DiskTree {
    /// Takes an item that left the open folder out of that folder's totals and of every
    /// folder above it. `ancestors` runs from the scanned root down to the open folder.
    public static func remove(_ row: DiskRow, from ancestors: [DiskNode]) {
        let bytes: Int64, files: Int
        if let node = row.node {
            ancestors.last?.children.removeAll { $0 === node }
            bytes = node.size; files = node.fileCount
        } else if !row.isDirectory, !row.linked, let size = row.size {
            // A hard-linked file was charged to one of its folders, maybe not this one,
            // and its blocks stay in use through the other names: nothing to subtract.
            bytes = size; files = 1
        } else {
            return
        }
        for ancestor in ancestors {
            ancestor.size = max(0, ancestor.size - bytes)
            ancestor.fileCount = max(0, ancestor.fileCount - files)
        }
    }
}

/// Folders macOS or the account cannot work without. They can be opened and their
/// contents chosen, but they are never offered for the Trash themselves.
public enum DiskSafety {
    private static let dataVolume = DiskScanner.dataVolume
    private static let fixed: Set<String> = [
        "/", "/Applications", "/Library", "/System", "/Users", "/Users/Shared", "/Volumes", "/cores", "/opt",
        "/private", "/private/var", "/private/tmp", "/private/etc", "/etc", "/var", "/tmp",
        "/usr", "/usr/local", "/bin", "/sbin"
    ]
    private static let systemTrees = ["/System", "/bin", "/sbin", "/usr", "/etc", "/private/etc",
                                      "/var/db", "/private/var/db", "/Library/Apple"]
    private static let homeFolders = [
        "Applications", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library",
        "Library/Application Support", "Library/Caches", "Library/CloudStorage", "Library/Containers",
        "Library/Group Containers", "Library/Keychains", "Library/Mobile Documents", "Library/Preferences"
    ]

    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // The startup disk's data volume shows the same folders under a second name.
        if path == dataVolume { return "/" }
        if path.hasPrefix(dataVolume + "/") { path.removeFirst(dataVolume.count) }
        return path
    }

    private static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    public static func isProtected(_ path: String, home: String, volumes: Set<String> = [],
                                   ownBundle: String? = nil) -> Bool {
        let path = normalized(path), home = normalized(home)
        // Anything that is not a plain absolute path is refused rather than guessed at.
        guard path.hasPrefix("/"), !path.components(separatedBy: "/").contains("..") else { return true }
        if fixed.contains(path) { return true }
        // A mounted volume, and every folder it is mounted in: the scan leaves the
        // volume out, so such a folder looks nearly empty, yet moving it takes the
        // whole volume along.
        if volumes.contains(where: { contains(path, normalized($0)) }) { return true }
        if systemTrees.contains(where: { contains($0, path) }) && !path.hasPrefix("/usr/local/") { return true }
        // Every account's home folder, not only this one.
        if path.hasPrefix("/Users/") && !path.dropFirst("/Users/".count).contains("/") { return true }
        if path == home || homeFolders.contains(where: { path == home + "/" + $0 }) { return true }
        // The roots of iCloud Drive and of each cloud provider.
        for cloud in ["Library/Mobile Documents", "Library/CloudStorage"] {
            let folder = home + "/" + cloud + "/"
            if path.hasPrefix(folder), !path.dropFirst(folder.count).contains("/") { return true }
        }
        // Per-user temporary and cache roots that running apps are working in.
        for folders in ["/private/var/folders/", "/var/folders/"] where path.hasPrefix(folders) {
            if path.dropFirst(folders.count).split(separator: "/").count <= 3 { return true }
        }
        // What is already in the Trash cannot be moved there.
        if contains(home + "/.Trash", path) { return true }
        if let ownBundle, contains(normalized(ownBundle), path) { return true }
        return false
    }
}
