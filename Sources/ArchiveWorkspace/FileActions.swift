import AppKit
import ArchiveCore

extension AppModel {
    var clipboardFiles: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func showInFinder() {
        let urls = selectedRows.compactMap(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [archive ?? folder] : urls)
    }

    func copyPaths() {
        let paths = selectedRows.map { row in row.url?.path ?? ((archive?.path ?? "") + "/" + row.id) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.isEmpty ? (archive ?? folder).path : paths.joined(separator: "\n"), forType: .string)
        message = "Paths copied"
    }

    func copySelection() {
        guard !busy, !selectedRows.isEmpty else { return }
        if !isArchive {
            publishClipboard(selectedRows.compactMap(\.url)); return
        }
        guard let archive else { return }
        let paths = selectedRows.map(\.id), pass = password, service = service, session = session
        perform("Copying files") { token, log in
            let out = try await service.extract(archive, to: session, paths: paths, password: pass, control: token, output: log)
            // A selected folder already includes its children. Avoid duplicate paste targets.
            let roots = paths.filter { path in !paths.contains { $0 != path && path.hasPrefix($0 + "/") } }
            self.publishClipboard(roots.map { out.appendingPathComponent($0) })
        } retry: { [weak self] in self?.password = self?.passwordInput ?? ""; self?.copySelection() }
    }

    private func publishClipboard(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        message = "Files copied"
    }

    func pasteFiles() {
        guard !busy else { return }
        let sources = clipboardFiles; guard !sources.isEmpty else { return }
        if isArchive {
            guard canEdit else { return }
            edit(.add(sources)); return
        }
        let destination = folder
        perform("Copying files") { token, _ in
            let result = try await Task.detached { try FileOperations.copy(sources, to: destination, control: token) }.value
            self.busy = false; self.loadFolder(destination, record: false); self.selection = Set(result.map(\.path))
            self.message = "Files copied"
        }
    }

    func newFolder() {
        guard !busy, !isArchive else { return }
        let alert = NSAlert(); alert.messageText = L("New folder")
        let field = NSTextField(string: L("New folder")); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: L("Create")); alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileOperations.validateName(field.stringValue)
            let url = folder.appendingPathComponent(field.stringValue)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError.message("DESTINATION_EXISTS") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            loadFolder(folder, record: false); selection = [url.path]
        } catch { self.error = ArchiveNotice(error.localizedDescription) }
    }

    func trashSelection() {
        guard !busy, !isArchive else { return }
        let urls = selectedRows.compactMap(\.url); guard !urls.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = L("Move selected items to Trash?")
        alert.informativeText = urls.prefix(6).map(\.lastPathComponent).joined(separator: "\n")
        alert.addButton(withTitle: L("Move to Trash")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let destination = folder
        perform("Moving to Trash") { token, _ in
            do {
                try await Task.detached {
                    for url in urls { try token.check(); try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                }.value
            } catch {
                self.busy = false; self.loadFolder(destination, record: false); throw error
            }
            self.busy = false; self.loadFolder(destination, record: false); self.message = "Moved to Trash"
        }
    }

    func showProperties() {
        guard !busy else { return }
        let items = selectedRows
        guard !items.isEmpty else { if isArchive { sheet = .info }; return }
        report = items.map { row in
            var lines = [L("Name") + ": " + row.name, L("File path") + ": " + (row.url?.path ?? row.id),
                         L("Type") + ": " + L(row.kind), L("Modified") + ": " + row.modified]
            if !row.directory { lines.append(L("Size") + ": " + MainView.bytes(row.size, language: language)) }
            if isArchive {
                lines.append(L("Packed") + ": " + MainView.bytes(row.packed, language: language))
                if !row.crc.isEmpty { lines.append("CRC: " + row.crc) }
                if row.encrypted { lines.append(L("Encrypted")) }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        sheet = .report
    }

    func archiveAction(_ action: String, url: URL? = nil) {
        guard !busy else { return }
        if let url {
            open(url, afterOpen: { [weak self] in self?.archiveAction(action) }); return
        }
        guard isArchive else { return }
        switch action {
        case "extract": selection = []; prepareExtract()
        case "quickExtract": selection = []; extractSelected = false; extractParent = folder.path; extract()
        case "test": testArchive()
        case "convert": convert()
        case "info": sheet = .info
        default: break
        }
    }

    func handleFinderService(_ action: String, urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !busy, sheet == nil else { error = "Finish the current operation or close the dialog first."; return }
        if action == "compress" { prepareCreate(urls); return }
        // Open and extract act on one archive so a password dialog has an unambiguous target.
        guard urls.count == 1, let url = urls.first else { error = "Select one archive for this action."; return }
        if action == "open" { open(url) }
        else { archiveAction(action, url: url) }
    }
}
