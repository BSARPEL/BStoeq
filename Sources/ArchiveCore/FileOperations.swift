import Foundation
import Darwin

/// File-browser operations never replace existing items and keep unfinished copies hidden.
public enum FileOperations {
    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ArchiveError.message("INVALID_FILE_NAME")
        }
    }

    public static func rename(_ source: URL, to name: String) throws -> URL {
        try validateName(name)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        if source.lastPathComponent == name { return source }
        if itemExists(destination) {
            // A case-only rename addresses the same entry on most Mac volumes.
            // Confirm its identity so a different file can never be replaced.
            var before = stat(), after = stat()
            let sameEntry = source.withUnsafeFileSystemRepresentation { sourcePath in
                destination.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath,
                          lstat(sourcePath, &before) == 0, lstat(destinationPath, &after) == 0 else { return false }
                    return before.st_dev == after.st_dev && before.st_ino == after.st_ino
                }
            }
            let caseSensitive = try source.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            guard sameEntry, caseSensitive == false,
                  source.lastPathComponent.compare(name, options: .caseInsensitive) == .orderedSame else {
                throw ArchiveError.message("DESTINATION_EXISTS")
            }
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    public static func copy(_ sources: [URL], to folder: URL, control: JobControl) throws -> [URL] {
        let fm = FileManager.default
        try control.check()
        guard !sources.isEmpty else { return [] }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        for source in sources {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            if values.isDirectory == true && values.isSymbolicLink != true &&
                root.pathComponents.starts(with: resolved.pathComponents) {
                throw ArchiveError.message("CANNOT_COPY_INTO_SELF")
            }
        }
        let stage = folder.appendingPathComponent(".bstoeq-archive-copy-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        var published: [URL] = []
        do {
            for (index, source) in sources.enumerated() {
                try control.check()
                let temporary = stage.appendingPathComponent(String(index))
                try fm.copyItem(at: source, to: temporary)
                try control.check()
                let isDirectory = try temporary.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let destination = uniqueDestination(folder.appendingPathComponent(source.lastPathComponent), isDirectory: isDirectory)
                try fm.moveItem(at: temporary, to: destination)
                published.append(destination)
            }
            return published
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
    }

    private static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
    }

    private static func uniqueDestination(_ url: URL, isDirectory: Bool) -> URL {
        guard itemExists(url) else { return url }
        let ext = isDirectory ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        func candidate(_ suffix: String) -> URL {
            url.deletingLastPathComponent().appendingPathComponent(base + " (" + suffix + ")" + (ext.isEmpty ? "" : "." + ext))
        }
        for index in 2...100_000 {
            let next = candidate(String(index))
            if !itemExists(next) { return next }
        }
        return candidate(UUID().uuidString)
    }

}
