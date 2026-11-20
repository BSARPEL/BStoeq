import Foundation

public struct ArchiveService: Sendable {
    public let tool: URL
    public let rarTool: URL?
    public init(tool: URL, rarTool: URL? = nil) { self.tool = tool; self.rarTool = rarTool }
    private func isCompressedTar(_ archive: URL) -> Bool {
        [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".tbz2", ".txz"].contains { archive.lastPathComponent.lowercased().hasSuffix($0) }
    }
    public func list(_ archive: URL, password: String = "", control: JobControl) async throws -> ArchiveListing {
        if isCompressedTar(archive) {
            let temporary = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let inner = try await unpackTarLayer(archive, at: temporary, control: control)
            var listing = try await rawList(inner, password: password, control: control)
            listing.metadata["Container"] = archive.pathExtension.uppercased()
            return listing
        }
        return try await rawList(archive, password: password, control: control)
    }
    private func rawList(_ archive: URL, password: String = "", control: JobControl) async throws -> ArchiveListing {
        // Switches must precede --, which makes archive names literal even when they start with '-'.
        let args = ["l", "-slt", "-sccUTF-8", "--", archive.path]
        let result = try await ProcessRunner.run(tool: tool, arguments: args, password: password, control: control)
        return try ListingParser.parse(result)
    }
    public func test(_ archive: URL, password: String = "", control: JobControl,
                     output: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        if isCompressedTar(archive) {
            let temporary = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let inner = try await unpackTarLayer(archive, at: temporary, control: control)
            return try await test(inner, password: password, control: control, output: output)
        }
        return try await ProcessRunner.run(tool: tool, arguments: ["t", "-sccUTF-8", "-bsp1", "--", archive.path], password: password, control: control, output: output)
    }

    public func extract(_ archive: URL, to parent: URL, paths: [String] = [], password: String = "",
                        control: JobControl, output: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        if isCompressedTar(archive) {
            let temporary = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let inner = try await unpackTarLayer(archive, at: temporary, control: control)
            return try await extract(inner, to: parent, paths: paths, password: password, control: control, output: output)
        }
        let listing = try await list(archive, password: password, control: control)
        try ArchiveSafety.validate(listing.entries)
        for path in paths { try ArchiveSafety.validatePath(path) }
        let selectedEntries = paths.isEmpty ? listing.entries : listing.entries.filter { entry in
            paths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
        }
        guard paths.isEmpty || !selectedEntries.isEmpty else { throw ArchiveError.message("NO_SELECTION") }
        let fm = FileManager.default
        let volume = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeSupportsCaseSensitiveNamesKey])
        try ArchiveSafety.validateDestinations(selectedEntries, caseSensitive: volume.volumeSupportsCaseSensitiveNames == true)
        let selectedSize = ArchiveListing(entries: selectedEntries).totalSize
        if let free = volume.volumeAvailableCapacityForImportantUsage, selectedSize > free { throw ArchiveError.message("NOT_ENOUGH_SPACE") }
        let stage = parent.appendingPathComponent(".bstoeq-archive-extract-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let content = stage.appendingPathComponent("content")
        try fm.createDirectory(at: content, withIntermediateDirectories: false)
        var args = ["x", "-y", "-sccUTF-8", "-bsp1", "-spd", "-o" + content.path]
        if !paths.isEmpty {
            let selections = selectedEntries.map(\.path)
            let file = stage.appendingPathComponent("selections.txt")
            try selections.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            args += ["-scsUTF-8", "-i@" + file.path]
        }
        args += ["--", archive.path]
        _ = try await ProcessRunner.run(tool: tool, arguments: args, password: password, control: control, output: output)
        try control.check()
        try validateExtractedTree(content)
        // 7-Zip can return success with zero files when a displayed, sanitized name
        // does not match the actual archive entry. Never publish that as extraction success.
        for entry in selectedEntries {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: content.appendingPathComponent(entry.path).path, isDirectory: &isDirectory),
                  isDirectory.boolValue == entry.isDirectory else { throw ArchiveError.message("INVALID_ARCHIVE_LIST") }
        }
        var name = archive.lastPathComponent
        for suffix in [".001", ".tar.gz", ".tar.bz2", ".tar.xz", ".7z", ".zip", ".rar", ".tar", ".gz", ".bz2", ".xz"] {
            if name.lowercased().hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        if name.isEmpty { name = "Archive" }
        let destination = ArchiveSafety.uniqueDestination(parent.appendingPathComponent(name))
        try fm.moveItem(at: content, to: destination)
        return destination
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bstoeq-archive-tar-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func unpackTarLayer(_ archive: URL, at temporary: URL, control: JobControl) async throws -> URL {
        let outer = try await rawList(archive, control: control)
        try ArchiveSafety.validate(outer.entries)
        guard outer.entries.count == 1, let entry = outer.entries.first, !entry.isDirectory else { throw ArchiveError.message("INVALID_ARCHIVE_LIST") }
        let free = try temporary.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let free, entry.size > free { throw ArchiveError.message("NOT_ENOUGH_SPACE") }
        _ = try await ProcessRunner.run(tool: tool, arguments: ["x", "-y", "-o" + temporary.path, "--", archive.path], control: control)
        try validateExtractedTree(temporary)
        // Streams without an embedded filename use extension-specific names when
        // extracting (.tbz/.txz become .tar), which can differ from the listing fallback.
        let extractedFiles = try FileManager.default.subpathsOfDirectory(atPath: temporary.path).map {
            temporary.appendingPathComponent($0)
        }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        guard extractedFiles.count == 1, let extracted = extractedFiles.first else { throw ArchiveError.message("INVALID_ARCHIVE_LIST") }
        var name = archive.deletingPathExtension().lastPathComponent
        if !name.lowercased().hasSuffix(".tar") { name += ".tar" }
        let inner = temporary.appendingPathComponent(name)
        if inner.standardizedFileURL != extracted.standardizedFileURL { try FileManager.default.moveItem(at: extracted, to: inner) }
        return inner
    }

    private func validateExtractedTree(_ content: URL) throws {
        let fm = FileManager.default
        // Do not publish an unexpected link or device produced by an unsupported archive encoding.
        if let enumerator = fm.enumerator(at: content, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) {
            for case let url as URL in enumerator {
                try ArchiveSafety.validatePath(String(url.path.dropFirst(content.path.count + 1)))
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                if values.isSymbolicLink == true || (values.isRegularFile != true && values.isDirectory != true) {
                    throw ArchiveError.linksUnsupported(url.lastPathComponent)
                }
            }
        }
    }

    private func validateDestinationOutsideSources(_ destination: URL, files: [URL]) throws {
        let targetPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else { throw ArchiveError.message("SOURCE_MISSING: " + file.lastPathComponent) }
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                let sourcePath = file.resolvingSymlinksInPath().standardizedFileURL.path
                let prefix = sourcePath == "/" ? "/" : sourcePath + "/"
                if targetPath == sourcePath || targetPath.hasPrefix(prefix) {
                    throw ArchiveError.message("DESTINATION_INSIDE_SOURCE")
                }
            }
        }
    }

    private func validateSources(_ files: [URL], control: JobControl) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func validate(_ url: URL) throws -> Bool {
            try control.check()
            try ArchiveSafety.validatePath(url.lastPathComponent)
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw ArchiveError.linksUnsupported(url.lastPathComponent)
            }
            return values.isDirectory == true
        }
        for file in files {
            guard fm.fileExists(atPath: file.path) else { throw ArchiveError.message("SOURCE_MISSING: " + file.lastPathComponent) }
            if try validate(file) {
                var readError: Error?
                guard let enumerator = fm.enumerator(at: file, includingPropertiesForKeys: keys, errorHandler: { _, error in
                    readError = error; return false
                }) else { throw ArchiveError.message("SOURCE_MISSING: " + file.lastPathComponent) }
                for case let child as URL in enumerator { _ = try validate(child) }
                if let readError { throw readError }
            }
        }
    }

    public func create(files: [URL], at destination: URL, options: ArchiveOptions, password: String = "",
                       control: JobControl, output: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [URL] {
        guard !files.isEmpty else { throw ArchiveError.message("NO_SELECTION") }
        guard (0...9).contains(options.level), options.volumeMB >= 0, options.volumeMB <= 1_000_000,
              (0...100).contains(options.recoveryPercent) else { throw ArchiveError.message("INVALID_OPTIONS") }
        if !password.isEmpty && (!options.format.supportsPassword || password.contains("\n") || password.contains("\r")) {
            throw ArchiveError.message("INVALID_PASSWORD")
        }
        let fm = FileManager.default
        let target = destination.standardizedFileURL
        guard !fm.fileExists(atPath: target.path) else { throw ArchiveError.message("DESTINATION_EXISTS") }
        try validateDestinationOutsideSources(target, files: files)
        try validateSources(files, control: control)
        if options.volumeMB > 0 && options.format.supportsVolumes {
            let siblings = try fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            let prefix = target.lastPathComponent + "."
            if siblings.contains(where: { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix) else { return false }
                let suffix = name.dropFirst(prefix.count)
                return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
            }) { throw ArchiveError.message("DESTINATION_EXISTS") }
        }
        var root = files[0].deletingLastPathComponent().standardizedFileURL
        while !files.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") }) {
            root.deleteLastPathComponent()
        }
        let names = try files.map { file -> String in
            let relative = String(file.standardizedFileURL.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
            try ArchiveSafety.validatePath(relative)
            return "./" + relative
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".bstoeq-archive-create-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let outputFolder = stage.appendingPathComponent("output")
        try fm.createDirectory(at: outputFolder, withIntermediateDirectories: false)
        let result = outputFolder.appendingPathComponent(target.lastPathComponent)
        let inputList = stage.appendingPathComponent("inputs.txt")
        try names.joined(separator: "\n").write(to: inputList, atomically: true, encoding: .utf8)
        let inputArgs = ["-scsUTF-8", "-spd", "-i@" + inputList.path]
        if options.format == .rar {
            guard let rarTool else { throw ArchiveError.message("RAR_ENGINE_REQUIRED") }
            // The optional RAR binary is user supplied and remains outside the app bundle.
            var args = ["a", "-r", "-y", "-m\(min(options.level, 5))"]
            if options.solid { args += ["-s"] }
            if options.volumeMB > 0 { args += ["-v\(options.volumeMB)m"] }
            if options.recoveryPercent > 0 { args += ["-rr\(options.recoveryPercent)p"] }
            if !password.isEmpty { args += [options.encryptNames ? "-hp" : "-p"] }
            args += ["--", result.path] + names
            _ = try await ProcessRunner.run(tool: rarTool, arguments: args, directory: root, password: password, control: control, output: output)
        } else if [.tarGzip, .tarBzip, .tarXZ].contains(options.format) {
            let intermediate = stage.appendingPathComponent("payload.tar")
            _ = try await ProcessRunner.run(tool: tool, arguments: ["a", "-ttar", "-sccUTF-8", "-bsp1"] + inputArgs +
                ["--", intermediate.path], directory: root, control: control, output: output)
            let format = options.format == .tarGzip ? "gzip" : options.format == .tarBzip ? "bzip2" : "xz"
            _ = try await ProcessRunner.run(tool: tool, arguments: ["a", "-t" + format, "-mx=\(options.level)", "-bsp1", "--", result.path, intermediate.path], control: control, output: output)
        } else {
            var args = ["a", "-t" + options.format.rawValue, "-mx=\(options.level)", "-sccUTF-8", "-bsp1"]
            if options.format == .sevenZip { args += ["-ms=" + (options.solid ? "on" : "off")] }
            if options.volumeMB > 0 && options.format.supportsVolumes { args += ["-v\(options.volumeMB)m"] }
            if !password.isEmpty {
                args += ["-p"]
                if options.format == .zip { args += ["-mem=AES256"] }
                if options.format == .sevenZip && options.encryptNames { args += ["-mhe=on"] }
            }
            args += inputArgs + ["--", result.path]
            _ = try await ProcessRunner.run(tool: tool, arguments: args, directory: root, password: password, control: control, output: output)
        }
        try control.check()
        let outputs = try fm.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent == target.lastPathComponent || $0.lastPathComponent.hasPrefix(target.lastPathComponent + ".") ||
            (options.format == .rar && $0.pathExtension == "rar")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !outputs.isEmpty else { throw ArchiveError.message("NO_OUTPUT") }
        let targets = outputs.map { target.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent) }
        guard !targets.contains(where: { fm.fileExists(atPath: $0.path) }) else { throw ArchiveError.message("DESTINATION_EXISTS") }
        var published: [URL] = []
        do {
            for (source, destination) in zip(outputs, targets) { try fm.moveItem(at: source, to: destination); published.append(destination) }
        } catch {
            for url in published { try? fm.moveItem(at: url, to: stage.appendingPathComponent(url.lastPathComponent)) }
            throw error
        }
        return targets
    }

    public enum Edit: Sendable { case add([URL]), delete([String]), rename(String, String) }
    public func edit(_ archive: URL, operation: Edit, password: String = "", control: JobControl,
                     output: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let listing = try await list(archive, password: password, control: control)
        guard ["7z", "zip", "tar"].contains(listing.format.lowercased()), !listing.isMultiVolume, !listing.encrypted,
              listing.metadata["Container"] == nil else {
            throw ArchiveError.message("READ_ONLY_FORMAT")
        }
        let fm = FileManager.default
        let stage = archive.deletingLastPathComponent().appendingPathComponent(".bstoeq-archive-edit-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let copy = stage.appendingPathComponent(archive.lastPathComponent)
        let oldAttributes = try fm.attributesOfItem(atPath: archive.path)
        try fm.copyItem(at: archive, to: copy)
        var args: [String]
        var cwd: URL?
        switch operation {
        case .add(let files):
            guard !files.isEmpty else { throw ArchiveError.message("NO_SELECTION") }
            let parent = files[0].deletingLastPathComponent()
            guard files.allSatisfy({ $0.deletingLastPathComponent() == parent }) else { throw ArchiveError.message("SAME_FOLDER_REQUIRED") }
            try validateDestinationOutsideSources(archive, files: files)
            try validateSources(files, control: control)
            cwd = parent
            args = ["a", "-spd", "-sccUTF-8", "-bsp1", "-y"] + (password.isEmpty ? [] : ["-p"]) + ["--", copy.path] + files.map { "./" + $0.lastPathComponent }
        case .delete(let paths):
            guard !paths.isEmpty else { throw ArchiveError.message("NO_SELECTION") }
            for path in paths { try ArchiveSafety.validatePath(path) }
            args = ["d", "-spd", "-sccUTF-8"] + (password.isEmpty ? [] : ["-p"]) + ["--", copy.path] + paths
        case .rename(let old, let new):
            try ArchiveSafety.validatePath(old); try ArchiveSafety.validatePath(new)
            let moved = listing.entries.filter { $0.path == old || $0.path.hasPrefix(old + "/") }
            guard !moved.isEmpty else { throw ArchiveError.message("NO_SELECTION") }
            guard old != new, !new.hasPrefix(old + "/"), !listing.entries.contains(where: { $0.path == new || $0.path.hasPrefix(new + "/") }) else { throw ArchiveError.message("DESTINATION_EXISTS") }
            let renamed = listing.entries.map { entry -> ArchiveEntry in
                guard entry.path == old || entry.path.hasPrefix(old + "/") else { return entry }
                return ArchiveEntry(path: new + entry.path.dropFirst(old.count), isDirectory: entry.isDirectory)
            }
            try ArchiveSafety.validateDestinations(renamed, caseSensitive: true)
            args = ["rn", "-spd", "-sccUTF-8"] + (password.isEmpty ? [] : ["-p"]) + ["--", copy.path, old, new]
        }
        _ = try await ProcessRunner.run(tool: tool, arguments: args, directory: cwd, password: password, control: control, output: output)
        _ = try await test(copy, password: password, control: control)
        try control.check()
        let now = try fm.attributesOfItem(atPath: archive.path)
        guard now[.modificationDate] as? Date == oldAttributes[.modificationDate] as? Date,
              now[.size] as? Int64 == oldAttributes[.size] as? Int64 else { throw ArchiveError.message("ARCHIVE_CHANGED") }
        // Keep a discoverable original; edits can be undone in Finder without trusting an in-memory cache.
        let backup = ArchiveSafety.uniqueDestination(archive.appendingPathExtension("backup"))
        try fm.copyItem(at: archive, to: backup)
        _ = try fm.replaceItemAt(archive, withItemAt: copy)
    }

    public func repairRAR(_ archive: URL, control: JobControl, output: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard let rarTool else { throw ArchiveError.message("RAR_ENGINE_REQUIRED") }
        let fm = FileManager.default
        let destination = ArchiveSafety.uniqueDestination(archive.deletingLastPathComponent().appendingPathComponent(archive.lastPathComponent + "-repaired"))
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            _ = try await ProcessRunner.run(tool: rarTool, arguments: ["r", "-y", "--", archive.path, destination.path + "/"], control: control, output: output)
            return destination
        } catch { try? fm.removeItem(at: destination); throw error }
    }
}
