import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

enum Theme {
    static let teal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.27, green: 0.68, blue: 0.66, alpha: 1) : NSColor(red: 0.10, green: 0.48, blue: 0.48, alpha: 1)
    })
    static let blue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.43, green: 0.60, blue: 0.89, alpha: 1) : NSColor(red: 0.24, green: 0.42, blue: 0.76, alpha: 1)
    })
    static let amber = Color(red: 0.77, green: 0.43, blue: 0.16)
    static let line = Color.primary.opacity(0.09)
    static let surface = Color(nsColor: .controlBackgroundColor)
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var dropTarget = false
    @State private var showLog = false
    @State private var columnSort: [KeyPathComparator<FileRow>] = []
    private func L(_ text: String) -> String { model.L(text) }
    var body: some View {
        VStack(spacing: 0) {
            masthead
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 196)
                Divider()
                VStack(spacing: 0) {
                    navigation
                    if model.rows.isEmpty { emptyState } else { fileTable }
                    if model.isArchive { archiveSummary }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.teal)
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.teal, lineWidth: 3).padding(5).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            guard !model.busy else { return false }
            let group = DispatchGroup(); let box = DropURLs()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { box.append(url) }; group.leave()
                }
            }
            group.notify(queue: .main) { model.receive(box.urls) }
            return true
        }
        .sheet(item: $model.sheet) { value in AppSheetView(model: model, kind: value) }
        .alert(L("Could not complete the operation"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK")) { model.error = nil }
        } message: { Text(model.error?.text(using: model.L) ?? "") }
        .overlay(alignment: .bottomTrailing) {
            if model.busy { progressCard.padding(20).padding(.bottom, 32) }
        }
        .environment(\.locale, Locale(identifier: model.language.rawValue))
        .onChange(of: model.sortKey) { _, _ in columnSort = [] }
        .onChange(of: model.ascending) { _, _ in columnSort = [] }
        .onChange(of: model.search) { _, _ in model.selection = [] }
    }
    private var masthead: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.teal.gradient).frame(width: 38, height: 38)
                Image(systemName: "archivebox.fill").font(.system(size: 20)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("BStoeq").font(.system(size: 24, weight: .bold, design: .rounded))
                Text(L("Archive manager")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isArchive {
                Image(systemName: model.listing.encrypted ? "lock.shield" : "shippingbox").foregroundStyle(Theme.teal)
                Text(model.archive?.lastPathComponent ?? "").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(model.listing.format.uppercased()).font(.system(size: 9, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.teal.opacity(0.12), in: Capsule())
            } else { Text(L("Your archive workspace")).font(.system(size: 12)).foregroundStyle(.secondary) }
            Divider().frame(height: 24).padding(.horizontal, 10)
            Button { model.sheet = .settings } label: { Image(systemName: "gearshape").font(.system(size: 16)) }
                .buttonStyle(.plain).help(L("Settings…")).accessibilityLabel(L("Settings…")).disabled(model.busy)
        }.padding(.horizontal, 23).padding(.vertical, 16)
    }
    private var toolbar: some View {
        HStack(spacing: 5) {
            tool("New", icon: "plus.rectangle.on.folder.fill", color: Theme.teal, enabled: true) { model.prepareCreate() }
            tool("Open", icon: "folder.fill", color: Theme.amber, enabled: true) { model.openDialog() }
            tool("Extract", icon: "arrow.up.bin.fill", color: Theme.blue, enabled: model.isArchive) { model.prepareExtract() }
            tool("Add files", icon: "doc.badge.plus", color: Theme.teal, enabled: model.canEdit) { model.addFiles() }
            Divider().frame(height: 38).padding(.horizontal, 8)
            tool("Test", icon: "checkmark.shield.fill", color: Theme.teal, enabled: model.isArchive) { model.testArchive() }
            tool("View", icon: "doc.text.magnifyingglass", color: Theme.blue, enabled: model.selectedRows.count == 1 && model.selectedRows.first?.directory == false) { model.viewSelection() }
            tool("Delete", icon: "trash.fill", color: .red, enabled: model.canEdit && !model.selection.isEmpty) { model.deleteSelection() }
            tool("Convert", icon: "arrow.triangle.2.circlepath", color: Theme.amber, enabled: model.isArchive) { model.convert() }
            tool("Info", icon: "info.circle.fill", color: Theme.blue, enabled: model.isArchive) { model.sheet = .info }
            Spacer(minLength: 4)
        }.padding(.horizontal, 15).padding(.top, 4).padding(.bottom, 14)
    }
    private func tool(_ title: String, icon: String, color: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).symbolRenderingMode(.hierarchical).font(.system(size: 25, weight: .medium))
                    .foregroundStyle(enabled && !model.busy ? color : .secondary.opacity(0.4)).frame(height: 29)
                Text(L(title)).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }.frame(width: 73, height: 61).contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(ToolButtonStyle()).disabled(!enabled || model.busy).accessibilityLabel(L(title))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("LOCATIONS")).font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary).padding(.horizontal, 19).padding(.top, 20).padding(.bottom, 10)
            place("Home", icon: "house", url: FileManager.default.homeDirectoryForCurrentUser)
            place("Desktop", icon: "desktopcomputer", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
            place("Documents", icon: "doc.text", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
            place("Downloads", icon: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
            HStack {
                Text(L("FAVORITES")).font(.system(size: 9, weight: .semibold)).tracking(1.6)
                Spacer()
                Button { model.addFavorite() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(L("Add current location"))
            }.foregroundStyle(.secondary).padding(.horizontal, 19).padding(.top, 27).padding(.bottom, 10)
            if model.favorites.isEmpty { Text(L("Pin a folder or archive")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 19).padding(.bottom, 8) }
            ForEach(model.favorites, id: \.self) { path in
                place(URL(fileURLWithPath: path).lastPathComponent, icon: "star", url: URL(fileURLWithPath: path), translate: false)
                    .contextMenu { Button(L("Remove favorite")) { model.favorites.removeAll { $0 == path } } }
            }
            Text(L("RECENT ARCHIVES")).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary).padding(.horizontal, 19).padding(.top, 27).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.recent, id: \.self) { path in place(URL(fileURLWithPath: path).lastPathComponent, icon: "archivebox", url: URL(fileURLWithPath: path), translate: false) }
                }
            }
            Spacer(minLength: 15)
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(Theme.teal).font(.system(size: 20))
                Text(L("Local. Private. Yours.")).font(.system(size: 11, weight: .semibold))
                Text(L("Your files stay on your Mac.")).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 10)).padding(12)
        }.background(Color.primary.opacity(0.025)).disabled(model.busy)
    }
    private func place(_ title: String, icon: String, url: URL, translate: Bool = true) -> some View {
        Button { model.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 17).foregroundStyle(Theme.teal)
                Text(translate ? L(title) : title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .background((model.archive ?? model.folder) == url ? Theme.teal.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).padding(.horizontal, 7).help(url.path)
    }
    private var navigation: some View {
        HStack(spacing: 9) {
            Button { model.back() } label: { Image(systemName: "chevron.left") }.help(L("Back"))
            Button { model.up() } label: { Image(systemName: "arrow.up") }.help(L("Parent folder"))
            HStack(spacing: 7) {
                Image(systemName: model.isArchive ? "archivebox" : "folder").foregroundStyle(Theme.teal)
                Text((model.archive?.path ?? model.folder.path) + (model.archiveFolder.isEmpty ? "" : "/" + model.archiveFolder))
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help(L("Refresh"))
            }.padding(9).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Find files…"), text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
                    .accessibilityIdentifier("archive-search")
                if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(9).frame(width: 164).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            Menu {
                Picker(L("Sort by"), selection: $model.sortKey) { Text(L("Name")).tag("name"); Text(L("Size")).tag("size"); Text(L("Type")).tag("kind"); Text(L("Modified")).tag("modified") }
                Toggle(L("Ascending"), isOn: $model.ascending)
                if !model.isArchive { Toggle(L("Show hidden files"), isOn: $model.showHidden).onChange(of: model.showHidden) { _, _ in model.refresh() } }
            } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).frame(width: 21)
        }.buttonStyle(.plain).padding(13).background(Color.primary.opacity(0.02)).disabled(model.busy)
    }
    private var fileTable: some View {
        Table(model.rows.sorted(using: columnSort), selection: $model.selection, sortOrder: $columnSort) {
            TableColumn(L("Name"), value: \.name) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.directory ? "folder.fill" : Self.symbol(row.name)).foregroundStyle(row.directory ? Theme.amber : Theme.blue).frame(width: 18)
                    Text(row.name).lineLimit(1)
                    if row.encrypted { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.teal) }
                }.font(.system(size: 12)).padding(.vertical, 4)
                    
            }.width(min: 220, ideal: 380)
            TableColumn(L("Size"), value: \.size) { row in Text(row.directory ? "—" : Self.bytes(row.size, language: model.language)).monospacedDigit().foregroundStyle(.secondary) }.width(85)
            TableColumn(L("Packed"), value: \.packed) { row in Text(model.isArchive && !row.directory && (row.packed > 0 || row.size == 0) ? Self.bytes(row.packed, language: model.language) : "—").monospacedDigit().foregroundStyle(.secondary) }.width(85)
            TableColumn(L("Type"), value: \.kind) { row in Text(L(row.kind)).foregroundStyle(.secondary) }.width(68)
            TableColumn(L("Modified"), value: \.modified) { row in Text(String(row.modified.prefix(16))).monospacedDigit().foregroundStyle(.secondary) }.width(126)
        }
        .font(.system(size: 11)).alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: String.self) { ids in
            fileContextMenu(ids)
        } primaryAction: { ids in model.selection = ids; if let row = model.selectedRows.first { model.enter(row) } }
        .onKeyPress(.return) { if let row = model.selectedRows.first { model.enter(row) }; return .handled }
        .onKeyPress(.space) { model.viewSelection(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "cva")) { key in
            guard key.modifiers.contains(.command) else { return .ignored }
            switch key.characters.lowercased() {
            case "c": model.copySelection()
            case "v": model.pasteFiles()
            case "a": model.selection = Set(model.rows.map(\.id))
            default: return .ignored
            }
            return .handled
        }
        .disabled(model.busy)
    }
    @ViewBuilder private func fileContextMenu(_ ids: Set<String>) -> some View {
        let selected = model.rows.filter { ids.contains($0.id) }
        let single = selected.count == 1 ? selected.first : nil
        let selectedArchive = single?.url.flatMap { AppModel.archiveExtensions.contains($0.pathExtension.lowercased()) ? $0 : nil }
        if !ids.isEmpty {
            Button(L("Open / View")) { context(ids) { if let row = model.selectedRows.first { model.enter(row) } } }.disabled(single == nil)
            Button(L("Quick Look")) { context(ids, model.viewSelection) }.disabled(single == nil || single?.directory == true)
            if model.isArchive {
                Button(L("Extract selected…")) { context(ids, model.prepareExtract) }
            } else if let selectedArchive {
                Button(L("Extract…")) { model.archiveAction("extract", url: selectedArchive) }
                Button(L("Extract to a new folder here")) { model.archiveAction("quickExtract", url: selectedArchive) }
                Button(L("Test archive")) { model.archiveAction("test", url: selectedArchive) }
                Button(L("Convert…")) { model.archiveAction("convert", url: selectedArchive) }
            }
            if !model.isArchive { Button(L("Create archive…")) { context(ids) { model.prepareCreate() } } }
            Divider()
            Button(L("Copy files")) { context(ids, model.copySelection) }
            Button(L("Copy path")) { context(ids, model.copyPaths) }
            Button(L("Rename…")) { context(ids, model.prepareRename) }.disabled(single == nil || (model.isArchive && !model.canEdit))
            if model.isArchive {
                Button(L("Delete from archive…"), role: .destructive) { context(ids, model.deleteSelection) }.disabled(!model.canEdit)
            } else {
                Button(L("Move to Trash…"), role: .destructive) { context(ids, model.trashSelection) }
            }
            Divider()
            Button(L("Properties…")) { context(ids, model.showProperties) }
            Button(L("Show in Finder")) { context(ids, model.showInFinder) }
            if !model.isArchive { Button("SHA-256") { context(ids, model.hashSelection) } }
            Divider()
        }
        if model.isArchive {
            Menu(L("Archive actions")) {
                Button(L("Extract all…")) { model.archiveAction("extract") }
                Button(L("Extract to a new folder here")) { model.archiveAction("quickExtract") }
                Button(L("Add files to archive root…")) { model.addFiles() }.disabled(!model.canEdit)
                Button(L("Paste into archive root")) { model.pasteFiles() }.disabled(!model.canEdit || model.clipboardFiles.isEmpty)
                Divider()
                Button(L("Test archive")) { model.testArchive() }
                Button(L("Convert…")) { model.convert() }
                Button(L("Archive information")) { model.sheet = .info }
                if model.listing.format.lowercased().contains("rar") {
                    Button(L("Repair RAR archive…")) { model.repair() }
                }
                Button(L("Show archive in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.archive!]) }
                Button(L("Close archive")) { model.loadFolder(model.folder) }
            }
        } else {
            Button(L("Paste files")) { model.pasteFiles() }.disabled(model.clipboardFiles.isEmpty)
            Button(L("New folder…")) { model.newFolder() }
            if ids.isEmpty { Button(L("New archive…")) { model.prepareCreate([]) } }
        }
        Menu(L("Selection")) {
            Button(L("Select all")) { model.selection = Set(model.rows.map(\.id)) }
            Button(L("Invert selection")) { model.selection = Set(model.rows.map(\.id)).subtracting(ids) }
            Button(L("Clear selection")) { model.selection = [] }
        }
        Divider()
        Button(L("Refresh")) { model.refresh() }
        Button(L("Parent folder")) { model.up() }
        if ids.isEmpty {
            Button(L("Show in Finder")) { context([], model.showInFinder) }
            Button(L("Copy path")) { context([], model.copyPaths) }
        }
    }
    private func context(_ ids: Set<String>, _ action: () -> Void) { model.selection = ids; action() }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.search.isEmpty ? "archivebox" : "magnifyingglass").font(.system(size: 43, weight: .light)).foregroundStyle(Theme.teal.opacity(0.65))
            Text(L(model.search.isEmpty ? "A little order. A lot of space." : "No matching files")).font(.system(size: 19, weight: .semibold))
            Text(L("Drop files to create an archive, or open ZIP, RAR, 7z and more.")).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 10) { Button(L("Open archive…")) { model.openDialog() }; Button(L("New archive…")) { model.prepareCreate() }.buttonStyle(.borderedProminent) }.padding(.top, 5)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).contextMenu { fileContextMenu([]) }.disabled(model.busy)
    }
    private var archiveSummary: some View {
        HStack(spacing: 18) {
            Label(L("Archive contents"), systemImage: "shippingbox").font(.system(size: 10, weight: .medium))
            Text("\(model.listing.entries.filter { !$0.isDirectory }.count) " + L("files"))
            Text(Self.bytes(model.listing.totalSize, language: model.language))
            if model.listing.encrypted { Label(L("Encrypted"), systemImage: "lock.shield") }
            Spacer()
            if !model.canEdit { Text(L("Read & extract")).foregroundStyle(.secondary) }
        }.font(.system(size: 10)).foregroundStyle(Theme.teal).padding(.horizontal, 17).padding(.vertical, 12).background(Theme.teal.opacity(0.06))
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.busy ? Theme.amber : Theme.teal).frame(width: 6, height: 6)
            Text(model.busy ? L(model.operation) : model.message?.text(using: model.L, separator: " · ") ?? L("Ready")).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(model.rows.count) " + L("items"))
            if !model.selection.isEmpty { Text("· \(model.selection.count) " + L("selected")) }
            Text("  BStoeq " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).foregroundStyle(.tertiary)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 32)
    }
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L(model.operation)).font(.system(size: 13, weight: .semibold)); Spacer(); Button(L("Cancel")) { model.cancel() }.controlSize(.small) }
            if let progress = model.progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
            DisclosureGroup(L("Details"), isExpanded: $showLog) {
                ScrollView { Text(model.log).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 140)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 385).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.line)).shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }
    static func bytes(_ value: Int64, language: AppLanguage = .turkish) -> String {
        let units = [Localizer(language: language).text("bytes"), "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = Double(value); var unit = 0
        while amount >= 1000 && unit < units.count - 1 { amount /= 1000; unit += 1 }
        let number = NumberFormatter(); number.locale = Locale(identifier: language.rawValue)
        number.numberStyle = .decimal; number.maximumFractionDigits = unit == 0 ? 0 : 1
        return (number.string(from: NSNumber(value: amount)) ?? "0") + " " + units[unit]
    }
    static func symbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if AppModel.archiveExtensions.contains(ext) { return "archivebox.fill" }
        if ["jpg", "png", "jpeg", "heic", "svg"].contains(ext) { return "photo" }
        if ["mp4", "mov", "mkv"].contains(ext) { return "film" }
        return "doc.text"
    }
}

private struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.teal.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
private final class DropURLs: @unchecked Sendable {
    private let lock = NSLock(); private var values: [URL] = []
    func append(_ value: URL) { lock.lock(); values.append(value); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
}
