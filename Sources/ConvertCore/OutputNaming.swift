import Foundation

/// Names for results, and the one way a result reaches a folder of the user's.
public enum OutputNaming {
    /// Numbers tried after the plain name before giving up on a readable one.
    private static let lastNumber = 9999

    /// Moves `item`, a file or a folder of the caller's own, into `folder` under the first free name of
    /// "base.ext", "base 2.ext", "base 3.ext"… and returns where it went. Nothing that exists is ever
    /// replaced, also when other threads, jobs or apps write the same name at the same moment: the name
    /// is taken by an exclusive rename, never by looking first and moving afterwards. Errors carry the
    /// POSIX code of what refused.
    public static func publish(_ item: URL, named base: String, extension ext: String?, in folder: URL) throws -> URL {
        try publish(item, named: base, extension: ext, in: folder) { renamex_np($0, $1, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
    }

    /// `exclusive` renames without replacing and answers 0 or an errno; tests use it to stand in for
    /// volumes that behave differently.
    static func publish(_ item: URL, named base: String, extension ext: String?, in folder: URL,
                        exclusive: (String, String) -> Int32) throws -> URL {
        var source = item
        // Another volume: the content is copied under a hidden name first, so the visible name appears complete.
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        var number = 1
        while number <= lastNumber + 1 {
            let candidate = folder.appendingPathComponent(name(base, number, ext), isDirectory: false)
            switch exclusive(source.path, candidate.path) {
            case 0:
                if staged != nil { try? FileManager.default.removeItem(at: item) }
                return candidate
            case EEXIST:
                number += 1
            case ENOTSUP:
                // exFAT and others cannot rename exclusively. Creating is exclusive everywhere: take the
                // name with an empty item of our own, then rename over that claim.
                let directory = isDirectory(source.path)
                let claimed = claim(candidate.path, directory: directory)
                if claimed == EEXIST { number += 1; continue }
                guard claimed == 0 else { throw failure(claimed, candidate) }
                guard rename(source.path, candidate.path) == 0 else {
                    let code = errno
                    release(candidate.path, directory: directory)
                    throw failure(code, candidate)
                }
                if staged != nil { try? FileManager.default.removeItem(at: item) }
                return candidate
            case EXDEV where staged == nil:
                let copy = folder.appendingPathComponent(".bstoeq-convert-\(UUID().uuidString)", isDirectory: false)
                staged = copy
                try FileManager.default.copyItem(at: item, to: copy)
                source = copy
            case let code:
                throw failure(code, candidate)
            }
        }
        throw failure(EEXIST, folder.appendingPathComponent(name(base, 1, ext), isDirectory: false))
    }

    /// The first of "base.ext", "base 2.ext"… that is free at this moment. A hint for tools that insist on
    /// creating their own output: only `publish` takes a name safely.
    public static func available(named base: String, extension ext: String?, in folder: URL) -> URL {
        for number in 1...lastNumber + 1 {
            let candidate = folder.appendingPathComponent(name(base, number, ext), isDirectory: false)
            var status = stat()
            if lstat(candidate.path, &status) != 0 { return candidate }
        }
        return folder.appendingPathComponent(name(base, lastNumber + 1, ext), isDirectory: false)
    }

    /// The file's name without the extension its format was recognised by: "a.tar.gz" gives "a".
    /// A folder keeps its whole name. Without a format, the last extension goes.
    public static func baseName(of url: URL, format: FileFormat?) -> String {
        let name = url.lastPathComponent
        guard let format else { return (name as NSString).deletingPathExtension }
        for spelling in format.extensions.sorted(by: { $0.count > $1.count })
        where name.count > spelling.count + 1 && name.suffix(spelling.count + 1).lowercased() == "." + spelling {
            return String(name.dropLast(spelling.count + 1))
        }
        return format.family == .folder ? name : (name as NSString).deletingPathExtension
    }

    /// `/` cannot be in a name and `:` is how Finder shows one: both become `-`.
    public static func cleaned(_ name: String) -> String {
        String(name.map { $0 == "/" || $0 == ":" ? "-" : $0 })
    }

    /// At most `limit` UTF-8 bytes of `name`, cut between characters, without a space left at the cut.
    public static func shortened(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        var cut = "", bytes = 0
        for character in name {
            let width = character.utf8.count
            guard bytes + width <= limit else { break }
            cut.append(character)
            bytes += width
        }
        if cut.isEmpty {
            // One character longer than the whole limit (a long emoji sequence): cut inside it rather than return nothing.
            var scalars = String.UnicodeScalarView()
            for scalar in name.unicodeScalars {
                let width = String(scalar).utf8.count
                guard bytes + width <= limit else { break }
                scalars.append(scalar)
                bytes += width
            }
            return String(scalars)
        }
        var trimmed = cut
        while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
        return trimmed.isEmpty ? cut : trimmed
    }

    private static func name(_ base: String, _ number: Int, _ ext: String?) -> String {
        let stem = number == 1 ? base : number <= lastNumber ? "\(base) \(number)" : "\(base) \(UUID().uuidString)"
        guard let ext, !ext.isEmpty else { return stem }
        return "\(stem).\(ext)"
    }

    private static func isDirectory(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// Takes a name with an empty item that a plain rename of the same kind may replace. Answers 0 or an errno.
    private static func claim(_ path: String, directory: Bool) -> Int32 {
        if directory { return mkdir(path, 0o755) == 0 ? 0 : errno }
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return errno }
        close(descriptor)
        return 0
    }

    /// Gives a claim back, and only a claim: a folder goes only while empty, a file only while it has no content.
    private static func release(_ path: String, directory: Bool) {
        if directory { rmdir(path); return }
        var status = stat()
        if lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size == 0 { unlink(path) }
    }

    private static func failure(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
