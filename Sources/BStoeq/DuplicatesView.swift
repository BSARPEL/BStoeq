import AppKit
import SwiftUI
import BStoeqCore

struct DuplicatesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var finder: DuplicateFinderManager
    /// Groups drawn; a large folder can hold thousands.
    @State private var limit = DuplicatesView.pageSize

    static let pageSize = 30
    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    private func files(_ count: Int) -> String { count == 1 ? L("1 dosya") : L("%d dosya", count) }
    private func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    private var busy: Bool { finder.phase != .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Aynı dosyadan bir tane yeter.")).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text(L("Bir klasörü tara, içeriği birebir aynı olan dosyaları bul ve fazla kopyaları Çöp Sepeti’ne taşı."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let problem = finder.problem {
                HStack {
                    note(problem.text(using: model.localizer), icon: "exclamationmark.triangle", color: .orange)
                        .accessibilityIdentifier("duplicates-problem")
                    Button { finder.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(L("Kapat"))
                }
            }
            switch finder.phase {
            case .idle:
                targetsCard
                note(L("Gizli öğeler, Kitaplık klasörü ve uygulama ya da fotoğraf arşivi gibi paketler taranmaz. Her kopya grubundan en az bir dosya yerinde kalır; taşınanlar Çöp Sepeti’nden geri alınabilir."),
                     icon: "info.circle", color: Palette.accent)
            case .scanning:
                scanningCard
            case .ready, .trashing:
                if let report = finder.report { outcome(report) }
                result
                if finder.unreadable > 0 { accessNote }
            }
        }
        .onChange(of: finder.phase) { _, phase in if phase == .scanning { limit = Self.pageSize } }
    }

    // MARK: Choosing what to scan

    private var targetsCard: some View {
        card(L("NEREYİ TARAYALIM?")) {
            targetRow(L("Ev klasörü"), path: finder.home, identifier: "home")
            Divider().padding(.leading, 58)
            let downloads = DiskListing.join(finder.home, "Downloads")
            targetRow(L("İndirilenler"), path: downloads, identifier: "downloads")
            Divider().padding(.leading, 58)
            HStack(spacing: 14) {
                Image(systemName: "folder.badge.plus").font(.system(size: 18)).foregroundStyle(Palette.accent)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Başka bir klasör")).font(.system(size: 12, weight: .medium))
                    Text(L("Yalnızca seçtiğin klasör ve içindekiler taranır."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Klasör seç…")) { chooseFolder() }.controlSize(.small)
                    .accessibilityIdentifier("duplicates-choose-folder")
            }.padding(.horizontal, 17).padding(.vertical, 13)
            Divider().padding(.leading, 58)
            HStack(spacing: 14) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 18)).foregroundStyle(Palette.accent)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("En küçük dosya boyutu")).font(.system(size: 12, weight: .medium))
                    Text(L("Daha küçük dosyalar karşılaştırılmaz; tarama daha hızlı biter."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("En küçük dosya boyutu"), selection: Binding(get: { finder.minimumBytes },
                                                                     set: { finder.setMinimumBytes($0) })) {
                    ForEach(DuplicateFinderManager.sizeOptions, id: \.self) { size in
                        Text(size <= 1 ? L("Tüm boyutlar") : DiskView.bytes(size)).tag(size)
                    }
                }.labelsHidden().frame(width: 140).controlSize(.small)
                    .accessibilityIdentifier("duplicates-minimum-size")
            }.padding(.horizontal, 17).padding(.vertical, 13)
        }
    }

    private func targetRow(_ title: String, path: String, identifier: String) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(verbatim: path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(L("Tara")) { finder.scan(path) }.controlSize(.small)
                .accessibilityIdentifier("duplicates-scan-\(identifier)")
        }.padding(.horizontal, 17).padding(.vertical, 13)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L("Taranacak klasörü seç"); panel.prompt = L("Tara")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        finder.scan(url.path)
    }

    // MARK: Scanning

    private var scanningCard: some View {
        let comparing = finder.progress.stage == .comparing
        return card(L("TARANIYOR")) {
            HStack(spacing: 14) {
                Image(systemName: "doc.on.doc").font(.system(size: 16)).foregroundStyle(Palette.accent)
                    .frame(width: 27, height: 27)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: short(finder.folder ?? "")).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if comparing {
                        ProgressView(value: min(1, max(0, finder.progress.fraction))).progressViewStyle(.linear).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    Text(comparing ? L("Aynı boyuttaki dosyaların içeriği karşılaştırılıyor…")
                                   : L("Dosyalar listeleniyor · %@", files(finder.progress.files)))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("duplicates-progress")
                    // The path changes ten times a second; keep its line from resizing the card.
                    Text(verbatim: finder.progress.path.isEmpty ? " " : short(finder.progress.path))
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(L("Durdur")) { finder.cancelScan() }.controlSize(.small)
                    .accessibilityIdentifier("duplicates-stop")
            }.padding(17)
        }
    }

    // MARK: Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("KOPYA DOSYALAR")).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 14) {
                    if let folder = finder.folder { Button(L("Yeniden tara")) { finder.scan(folder) } }
                    Button(L("Başka bir yer tara")) { finder.close() }.accessibilityIdentifier("duplicates-close")
                }.buttonStyle(.link).font(.system(size: 10)).disabled(busy)
            }
            Text(verbatim: short(finder.folder ?? "") + " · " + L("İncelenen · %@", files(finder.scannedFiles)))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if finder.groups.isEmpty {
                Text(L("Bu klasörde içeriği aynı olan dosya bulunamadı."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
                    .accessibilityIdentifier("duplicates-empty")
            } else {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(finder.groups.prefix(limit)) { group in
                            groupView(group)
                            Divider().opacity(0.6)
                        }
                        if finder.groups.count > limit {
                            Button(L("Daha fazla göster (%d öğe daha)", finder.groups.count - limit)) { limit += Self.pageSize }
                                .buttonStyle(.link).font(.system(size: 11)).padding(13)
                        }
                    } header: {
                        VStack(spacing: 0) {
                            actionBar
                            Divider().opacity(0.6)
                            bulkBar
                            Divider().opacity(0.6)
                        }.background(Palette.card)
                    }
                }.background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if finder.phase == .trashing {
                ProgressView(value: Double(finder.trashedCount), total: Double(max(1, finder.trashTotal)))
                    .progressViewStyle(.linear).frame(maxWidth: 180).accessibilityLabel(L("Temizlik ilerlemesi"))
                Text(finder.isStopping ? L("Geçerli öğe tamamlanınca duracak…")
                                       : L("İşlenen · %d / %d", finder.trashedCount, finder.trashTotal))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
                Button(L("Durdur")) { finder.stopTrashing() }.controlSize(.small).disabled(finder.isStopping)
                    .accessibilityIdentifier("duplicates-stop-moving")
            } else {
                Text(finder.selectedCount == 0 ? L("Seçim yapılmadı")
                     : L("Seçim · %@", files(finder.selectedCount) + " · " + DiskView.bytes(finder.selectedBytes)))
                    .font(.system(size: 11, weight: finder.selectedCount == 0 ? .regular : .medium))
                    .foregroundStyle(finder.selectedCount == 0 ? .secondary : .primary).monospacedDigit()
                    .accessibilityIdentifier("duplicates-selection")
                Spacer(minLength: 8)
                Button { confirmTrash() } label: {
                    Label(L("Çöp Sepeti’ne taşı"), systemImage: "trash").font(.system(size: 11, weight: .medium))
                }.controlSize(.small).disabled(finder.selectedCount == 0)
                    .accessibilityIdentifier("duplicates-trash")
            }
        }.padding(.horizontal, 14).frame(height: 42)
    }

    private var bulkBar: some View {
        HStack(spacing: 14) {
            Text(finder.groups.count == 1 ? L("1 grup · %@ yer açılabilir", DiskView.bytes(finder.reclaimable))
                 : L("%d grup · %@ yer açılabilir", finder.groups.count, DiskView.bytes(finder.reclaimable)))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityIdentifier("duplicates-summary")
            Spacer(minLength: 8)
            Button(L("Her grupta en eskisini tut, diğerlerini seç")) { finder.selectAllButOldest() }
                .accessibilityIdentifier("duplicates-select-all")
            if finder.selectedCount > 0 { Button(L("Seçimi temizle")) { finder.clearSelection() } }
        }.buttonStyle(.link).font(.system(size: 11)).disabled(busy)
            .padding(.horizontal, 14).frame(height: 36)
    }

    private func groupView(_ group: DuplicateGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[0].path)).resizable().interpolation(.high)
                    .frame(width: 22, height: 22).accessibilityHidden(true)
                Text(verbatim: group.files[0].name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(L("%d kopya · her biri %@", group.files.count, DiskView.bytes(group.files[0].bytes)))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 5)
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                fileRow(file, in: group, oldest: index == 0)
            }
        }.padding(.bottom, 6)
    }

    private func fileRow(_ file: DuplicateFile, in group: DuplicateGroup, oldest: Bool) -> some View {
        let selected = finder.selection.contains(file.id)
        let last = finder.isLastKept(file, in: group)
        let date = file.modified.formatted(.dateTime.year().month(.abbreviated).day()
            .locale(Locale(identifier: model.localizer.language.rawValue)))
        return Toggle(isOn: Binding(get: { selected }, set: { _ in finder.toggle(file, in: group) })) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: short(file.folder)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(file.path)
                }
                Spacer(minLength: 8)
                if oldest {
                    Text(L("En eski")).font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.accent.opacity(0.10), in: Capsule())
                }
                Text(date).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 82, alignment: .trailing)
            }
        }.toggleStyle(.checkbox).disabled(busy || last)
            .help(last ? L("Her gruptan en az bir kopya yerinde kalır.") : "")
            .padding(.leading, 46).padding(.trailing, 14).padding(.vertical, 5)
            .background(selected ? Palette.accent.opacity(0.07) : .clear)
            .contextMenu {
                Button(L("Finder’da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
            }
            .accessibilityIdentifier("duplicates-file-\(file.path)")
    }

    // MARK: Trash

    private func confirmTrash() {
        guard finder.phase == .ready, finder.selectedCount > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Seçili kopyalar Çöp Sepeti’ne taşınsın mı?")
        alert.informativeText = files(finder.selectedCount) + " · " + DiskView.bytes(finder.selectedBytes) + "\n\n"
            + L("Her grupta işaretlemediğin en az bir kopya yerinde kalır. Seçtiklerini Çöp Sepeti’nden geri alabilirsin.")
        alert.addButton(withTitle: L("Vazgeç"))
        alert.addButton(withTitle: L("Çöp Sepeti’ne taşı")).hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { finder.trashSelection() }
    }

    private func outcome(_ report: DuplicateTrashSummary) -> some View {
        var lines = [L("Çöp Sepeti’ne taşınan · %@ · %@", files(report.movedCount), DiskView.bytes(report.movedBytes))]
        if report.skippedCount > 0 { lines.append(L("Taramadan sonra değiştiği için atlanan · %@", files(report.skippedCount))) }
        if report.failedCount > 0 { lines.append(L("Taşınamayan · %@", files(report.failedCount))) }
        if report.wasStopped { lines.append(L("Temizlik durduruldu. Kalan öğeleri listeden inceleyebilirsin.")) }
        if report.movedCount > 0 { lines.append(L("Disk alanı Çöp Sepeti boşaltıldığında açılır.")) }
        let warning = report.wasStopped || report.skippedCount > 0 || report.failedCount > 0
        return HStack(spacing: 10) {
            note(lines.joined(separator: "\n"), icon: warning ? "exclamationmark.triangle" : "checkmark.circle",
                 color: warning ? .orange : .green)
                .accessibilityIdentifier("duplicates-outcome")
            if report.movedCount > 0 {
                Button(L("Çöp Sepeti’ni aç")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true))
                }.controlSize(.small)
            }
        }
    }

    private var accessNote: some View {
        HStack(spacing: 10) {
            note(L("Okunamayan öğeler (%d) tarama sonucuna dahil edilmedi.", finder.unreadable)
                 + " " + L("Korumalı konumlara erişimi macOS yönetir. Tam Disk Erişimi ayarını değiştirirsen yeniden tara."),
                 icon: "hand.raised", color: Palette.accent)
                .accessibilityIdentifier("duplicates-unreadable")
            Button(L("Tam Disk Erişimi…")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }.controlSize(.small)
        }
    }

    // MARK: Pieces

    private func note(_ message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(12).background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }
}
