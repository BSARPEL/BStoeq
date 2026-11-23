import CryptoKit
import Foundation

/// What identified a file when its content was read. Any later write, rename or
/// replacement changes one of these, so an equal stamp means the content compared
/// during the scan is still the content on disk.
fileprivate struct DuplicateStamp: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds, modifiedNanos, changedSeconds, changedNanos: Int

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanos = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanos = status.st_ctimespec.tv_nsec
    }
}

/// One copy of a file whose content the scan read in full.
public struct DuplicateFile: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    /// Allocated bytes: what moving this copy to the Trash would free.
    public let bytes: Int64
    public let modified: Date
    fileprivate let stamp: DuplicateStamp

    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Files with identical content, oldest first.
public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let files: [DuplicateFile]

    /// Space taken by every copy except one.
    public var reclaimable: Int64 { files.dropFirst().reduce(0) { $0 + $1.bytes } }

    /// A group needs two copies to be a group.
    public func keeping(_ isIncluded: (DuplicateFile) -> Bool) -> DuplicateGroup? {
        let rest = files.filter(isIncluded)
        return rest.count > 1 ? DuplicateGroup(id: id, files: rest) : nil
    }
}

public struct DuplicateScanProgress: Equatable, Sendable {
    public enum Stage: Sendable { case listing, comparing }
    public var stage = Stage.listing
    /// Files seen while listing.
    public var files = 0
    /// How far the comparison is, from zero to one.
    public var fraction = 0.0
    public var path = ""
    public init() {}
}

public struct DuplicateScanResult: Sendable {
    public let groups: [DuplicateGroup]
    /// Files examined, whatever their size.
    public let scannedFiles: Int
    /// Folders and files that could not be read.
    public let unreadable: Int
    /// Left out on purpose: other volumes and items kept only in the cloud.
    public let skipped: Int
}

public struct DuplicateTrashResult: Sendable {
    public fileprivate(set) var moved: [DuplicateFile] = []
    /// Changed since the scan, or no unchanged copy would have remained.
    public fileprivate(set) var skipped: [DuplicateFile] = []
    public fileprivate(set) var failed: [DuplicateFile] = []
}

public enum DuplicateFinder {
    /// Files of one length are told apart by their beginning before any is read in full.
    static let headLength = 64 * 1024
    private static let chunkLength = 1024 * 1024

    private struct Candidate {
        let folder: Int32
        let name: String
        let status: stat
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Located {
        let path: String
        let status: stat
    }

    /// Finds files below `root` with the same content.
    ///
    /// Hidden items, packages such as apps and photo libraries, and the home Library
    /// are not entered: copies in there belong to the software that put them there.
    /// Links are not followed, and the several names of one hard-linked file count as
    /// one file. Returns `nil` when cancelled or when `root` is not a readable folder.
    public static func scan(_ root: String, home: String = NSHomeDirectory(), minimumBytes: Int64 = 1_000_000,
                            mountPoints: Set<String> = [], isCancelled: () -> Bool = { false },
                            progress: (DuplicateScanProgress) -> Void = { _ in }) -> DuplicateScanResult? {
        // Reading a cloud-only file would make its provider download it.
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) } }

        var state = DuplicateScanProgress()
        var lastReport = DispatchTime.now().uptimeNanoseconds
        func report(force: Bool = false) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard force || now - lastReport >= 100_000_000 else { return }
            lastReport = now
            progress(state)
        }

        var unreadable = 0, skipped = 0
        var folders: [String] = []
        var bySize: [off_t: [Candidate]] = [:]
        guard list(root, home: home, minimumBytes: max(1, minimumBytes), mountPoints: mountPoints,
                   folders: &folders, bySize: &bySize, unreadable: &unreadable, skipped: &skipped,
                   isCancelled: isCancelled, visit: { path in
                       state.files += 1
                       if state.files & 255 == 0 { state.path = path(); report() }
                   }) else { return nil }

        // Only files that share their length with another can be copies of it.
        let sameLength = bySize.values.filter { $0.count > 1 }.map { group in
            group.map { Located(path: DiskListing.join(folders[Int($0.folder)], $0.name), status: $0.status) }
        }
        bySize = [:]
        state.stage = .comparing
        state.path = ""
        report(force: true)

        // First by their beginning. A short file is read whole here and is settled.
        let headTotal = max(1, sameLength.reduce(0) { $0 + $1.count })
        var headDone = 0
        var settled: [(digest: SHA256.Digest, files: [Located])] = []
        var undecided: [[Located]] = []
        for group in sameLength {
            var byHead: [SHA256.Digest: [Located]] = [:]
            for file in group {
                if isCancelled() { return nil }
                headDone += 1
                state.fraction = 0.15 * Double(headDone) / Double(headTotal)
                state.path = file.path
                report()
                switch digest(of: file, limit: headLength, isCancelled: isCancelled, read: { _ in }) {
                case .digest(let value): byHead[value, default: []].append(file)
                case .unreadable: unreadable += 1
                case .changed, .cancelled: break
                }
            }
            let whole = Int(group[0].status.st_size) <= headLength
            for (head, files) in byHead where files.count > 1 {
                if whole { settled.append((head, files)) } else { undecided.append(files) }
            }
        }

        // Then the rest of the files whose beginnings agree.
        let fullTotal = max(1, undecided.reduce(Int64(0)) { $0 + Int64($1.count) * Int64($1[0].status.st_size) })
        var fullDone: Int64 = 0
        for group in undecided {
            var byContent: [SHA256.Digest: [Located]] = [:]
            for file in group {
                if isCancelled() { return nil }
                state.path = file.path
                let before = fullDone
                let outcome = digest(of: file, limit: nil, isCancelled: isCancelled) { count in
                    fullDone += Int64(count)
                    state.fraction = 0.15 + 0.85 * Double(fullDone) / Double(fullTotal)
                    report()
                }
                // Whatever was read, the whole file is behind us.
                fullDone = before + Int64(file.status.st_size)
                switch outcome {
                case .digest(let value): byContent[value, default: []].append(file)
                case .unreadable: unreadable += 1
                case .changed: break
                case .cancelled: return nil
                }
            }
            for (content, files) in byContent where files.count > 1 { settled.append((content, files)) }
        }
        if isCancelled() { return nil }

        let groups = settled.map { entry -> DuplicateGroup in
            let files = entry.files.map { file in
                DuplicateFile(path: file.path, bytes: Int64(file.status.st_blocks) * 512,
                              modified: Date(timeIntervalSince1970: Double(file.status.st_mtimespec.tv_sec)
                                             + Double(file.status.st_mtimespec.tv_nsec) / 1e9),
                              stamp: DuplicateStamp(file.status))
            }.sorted { $0.modified != $1.modified ? $0.modified < $1.modified : $0.path < $1.path }
            let hex = entry.digest.map { String(format: "%02x", $0) }.joined()
            return DuplicateGroup(id: "\(hex)-\(entry.files[0].status.st_size)", files: files)
        }.sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.id < $1.id }
        state.fraction = 1
        report(force: true)
        return DuplicateScanResult(groups: groups, scannedFiles: state.files, unreadable: unreadable, skipped: skipped)
    }

    private static func list(_ root: String, home: String, minimumBytes: Int64, mountPoints: Set<String>,
                             folders: inout [String], bySize: inout [off_t: [Candidate]],
                             unreadable: inout Int, skipped: inout Int, isCancelled: () -> Bool,
                             visit: (() -> String) -> Void) -> Bool {
        guard let rootPath = strdup(root) else { return false }
        defer { free(rootPath) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        // FTS_NOCHDIR: the working directory belongs to the whole process.
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return false }
        defer { fts_close(stream) }

        // The startup disk and its data volume share a device number, so the path is
        // what tells a mount point apart (see `DiskScanner.scan`).
        let aliasPrefix = DiskScanner.dataVolume + "/"
        var mounts = mountPoints
        for mount in mountPoints {
            mounts.insert(mount.hasPrefix(aliasPrefix) ? String(mount.dropFirst(DiskScanner.dataVolume.count))
                                                       : DiskScanner.dataVolume + mount)
        }
        let mountLengths = Set(mounts.map(\.utf8.count))
        let library = DiskListing.join(DiskScanner.canonicalPath(home) ?? home, "Library")
        // A scan started below the data volume's own name meets the Library under that name.
        let libraryAlias = library.hasPrefix(aliasPrefix) ? String(library.dropFirst(DiskScanner.dataVolume.count))
                                                          : DiskScanner.dataVolume + library
        let entered = 1
        var stack: [Int32] = []
        var linked = Set<FileIdentity>()
        var visited = 0, sawRoot = false

        while let entry = fts_read(stream) {
            visited += 1
            if visited & 1023 == 0, isCancelled() { return false }
            let level = entry.pointee.fts_level
            // A name starting with a dot is hidden by convention; the chosen folder itself is exempt.
            let nameOffset = max(0, Int(entry.pointee.fts_pathlen) - Int(entry.pointee.fts_namelen))
            let hidden = level > 0 && entry.pointee.fts_namelen > 0 && entry.pointee.fts_path[nameOffset] == 0x2E
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                let status = entry.pointee.fts_statp.pointee
                if level > 0 {
                    let path = String(cString: entry.pointee.fts_path)
                    let cloudOnly = status.st_flags & UInt32(SF_DATALESS) != 0
                    let mounted = mountLengths.contains(Int(entry.pointee.fts_pathlen)) && mounts.contains(path)
                    if cloudOnly || mounted { skipped += 1 }
                    if hidden || cloudOnly || mounted || path == library || path == libraryAlias || isPackage(path) {
                        fts_set(stream, entry, FTS_SKIP)
                        continue
                    }
                    folders.append(path)
                } else {
                    sawRoot = true
                    folders.append(root)
                }
                entry.pointee.fts_number = entered
                stack.append(Int32(folders.count - 1))
            case FTS_DP:
                if entry.pointee.fts_number == entered { stack.removeLast() }
            case FTS_DNR, FTS_ERR, FTS_DC:
                unreadable += 1
                if entry.pointee.fts_number == entered { stack.removeLast() }
            case FTS_NS, FTS_NSOK:
                if entry.pointee.fts_errno != ENOENT { unreadable += 1 }
            case FTS_F:
                guard let folder = stack.last else { return false }  // The root is a file.
                if hidden { continue }
                let status = entry.pointee.fts_statp.pointee
                visit { String(cString: entry.pointee.fts_path) }
                if status.st_flags & UInt32(SF_DATALESS) != 0 { skipped += 1; continue }
                guard Int64(status.st_size) >= minimumBytes else { continue }
                // Other names of a file already listed are that same file, not copies of it.
                if status.st_nlink > 1,
                   !linked.insert(FileIdentity(device: status.st_dev, inode: status.st_ino)).inserted { continue }
                let name = String(cString: UnsafePointer(entry.pointee.fts_path.advanced(by: nameOffset)))
                bySize[status.st_size, default: []].append(Candidate(folder: folder, name: name, status: status))
            default:
                continue  // Links and special files are never copies worth removing.
            }
        }
        return sawRoot && !isCancelled()
    }

    /// Only a folder whose name carries an extension can be a package; asking about
    /// every folder would double the cost of the walk.
    private static func isPackage(_ path: String) -> Bool {
        guard !(path as NSString).pathExtension.isEmpty else { return false }
        return (try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    private enum DigestOutcome { case digest(SHA256.Digest), unreadable, changed, cancelled }

    /// Hashes the file the listing saw and nothing else: a path that now leads to
    /// another file, or a file written to while it was read, yields no digest.
    private static func digest(of file: Located, limit: Int?, isCancelled: () -> Bool,
                               read report: (Int) -> Void) -> DigestOutcome {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .changed : .unreadable }
        defer { close(descriptor) }
        let expected = DuplicateStamp(file.status)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              DuplicateStamp(status) == expected else { return .changed }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: min(chunkLength, max(1, remaining)), alignment: 16)
        defer { buffer.deallocate() }
        while remaining > 0 {
            if isCancelled() { return .cancelled }
            let count = Darwin.read(descriptor, buffer.baseAddress, min(buffer.count, remaining))
            if count < 0 {
                if errno == EINTR { continue }
                return .unreadable
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
            remaining -= count
            report(count)
        }
        guard fstat(descriptor, &status) == 0, DuplicateStamp(status) == expected else { return .changed }
        return .digest(hasher.finalize())
    }

    private static func unchanged(_ file: DuplicateFile) -> Bool {
        var status = stat()
        return lstat(file.path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG && DuplicateStamp(status) == file.stamp
    }

    /// Moves the selected copies to the Trash. A copy goes only while it is the file
    /// the scan read and another copy of the same group, not selected and equally
    /// unchanged, stays behind: the last copy of anything is never moved.
    public static func trash(_ groups: [DuplicateGroup], selection: Set<String>, home: String = NSHomeDirectory(),
                             mountPoints: Set<String> = DiskScanner.mountPoints(), ownBundle: String? = nil,
                             isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in },
                             moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> DuplicateTrashResult {
        var result = DuplicateTrashResult()
        var done = 0
        for group in groups {
            let chosen = group.files.filter { selection.contains($0.id) }
            let kept = group.files.filter { !selection.contains($0.id) }
            for file in chosen {
                if isCancelled() { return result }
                defer { done += 1; progress(done) }
                guard kept.contains(where: unchanged), unchanged(file),
                      !DiskSafety.isProtected(file.path, home: home, volumes: mountPoints, ownBundle: ownBundle) else {
                    result.skipped.append(file)
                    continue
                }
                do { try moveToTrash(URL(fileURLWithPath: file.path)); result.moved.append(file) }
                catch { result.failed.append(file) }
            }
        }
        return result
    }
}
