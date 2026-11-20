import AppKit
import SwiftUI
import BStoeqCore

struct DiskView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var disk: DiskScanManager
    /// Rows drawn for the open folder; a cache folder can hold tens of thousands.
    @State private var limit = DiskView.pageSize

    static let pageSize = 300
    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    /// Digits always: the system formatter otherwise spells an empty size as a word
    /// ("Zero KB") in the system's language, whatever language BStoeq is set to.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        return formatter
    }()
    static func bytes(_ value: Int64) -> String { byteFormatter.string(fromByteCount: value) }
    private func files(_ count: Int) -> String { count == 1 ? L("1 dosya") : L("%d dosya", count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Yer açmak artık kolay.")).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text(L("Diskini tara, en çok yer kaplayanları gör ve gereksizleri Çöp Sepeti’ne taşı."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let problem = disk.problem {
                HStack {
                    note(problem.text(using: model.localizer), icon: "exclamationmark.triangle", color: .orange)
                        .accessibilityIdentifier("disk-problem")
                    Button { disk.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(L("Kapat"))
                }
            }
            switch disk.phase {
            case .idle:
                targetsCard
                note(L("BStoeq hiçbir şeyi kalıcı olarak silmez. Seçtiklerin Çöp Sepeti’ne taşınır ve oradan geri alınabilir."),
                     icon: "info.circle", color: Palette.accent)
            case .scanning:
                scanningCard
            case .finished:
                if disk.trashed > 0 { trashedNote }
                result
                if disk.unreadable > 0 { accessNote }
                if let summary = volumeSummary {
                    Text(summary).font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { disk.refreshTargets() }
        .onChange(of: disk.currentPath) { _, _ in limit = Self.pageSize }
    }

    // MARK: Choosing what to scan

    private var targetsCard: some View {
        card(L("NEREYİ TARAYALIM?")) {
            ForEach(disk.targets) { target in
                targetRow(target, subtitle: capacity(target))
                Divider().padding(.leading, 58)
            }
            targetRow(disk.homeTarget, title: L("Ev klasörü"), subtitle: disk.homeTarget.path)
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
                    .accessibilityIdentifier("disk-choose-folder")
            }.padding(.horizontal, 17).padding(.vertical, 13)
        }
    }

    private func capacity(_ target: DiskTarget) -> String? {
        guard let capacity = target.capacity, let available = target.available else { return nil }
        return L("%@ boş · toplam %@", Self.bytes(available), Self.bytes(capacity))
    }

    private func targetRow(_ target: DiskTarget, title: String? = nil, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target.path)).resizable().interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title ?? target.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let capacity = target.capacity, let used = target.used, capacity > 0 {
                    let fraction = Double(used) / Double(capacity)
                    ProgressView(value: min(1, fraction)).controlSize(.small).frame(maxWidth: 260)
                        .tint(fraction > 0.9 ? .orange : Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
            Button(L("Tara")) { disk.scan(target) }.controlSize(.small)
                .accessibilityIdentifier("disk-scan-\(target.kind == .home ? "home" : target.path)")
        }.padding(.horizontal, 17).padding(.vertical, 13)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.title = L("Taranacak klasörü seç"); panel.prompt = L("Tara")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        disk.scan(DiskTarget(path: url.path, name: FileManager.default.displayName(atPath: url.path), kind: .folder))
    }

    // MARK: Scanning

    private var scanningCard: some View {
        card(L("TARANIYOR")) {
            HStack(spacing: 14) {
                rowIcon("internaldrive")
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(of: disk.target)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                    Text(files(disk.progress.files) + " · " + Self.bytes(disk.progress.bytes))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("disk-progress")
                    // The path changes ten times a second; keep its line from resizing the card.
                    Text(disk.progress.path.isEmpty ? " " : (disk.progress.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(L("Durdur")) { disk.cancelScan() }.controlSize(.small)
                    .accessibilityIdentifier("disk-stop")
            }.padding(17)
        }
    }

    private func title(of target: DiskTarget?) -> String {
        guard let target else { return "" }
        return target.kind == .home ? L("Ev klasörü") : target.name
    }

    // MARK: Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("YER KAPLAYANLAR")).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 14) {
                    if let target = disk.target { Button(L("Yeniden tara")) { disk.scan(target) } }
                    Button(L("Başka bir yer tara")) { disk.close() }.accessibilityIdentifier("disk-close")
                }.buttonStyle(.link).font(.system(size: 10)).disabled(disk.trashing)
            }
            // The header stays in view while a long folder scrolls under it.
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if disk.rows.isEmpty {
                        Text(disk.loading ? L("Klasör okunuyor…") : L("Bu klasör boş."))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(22)
                    }
                    ForEach(disk.rows.prefix(limit)) { row in
                        rowView(row)
                        Divider().padding(.leading, 78).opacity(0.5)
                    }
                    if disk.rows.count > limit {
                        Button(L("Daha fazla göster (%d öğe daha)", disk.rows.count - limit)) { limit += Self.pageSize }
                            .buttonStyle(.link).font(.system(size: 11)).padding(13)
                    }
                } header: {
                    VStack(spacing: 0) {
                        trailBar
                        Divider().opacity(0.6)
                        actionBar
                        Divider().opacity(0.6)
                    }.background(Palette.card)
                }
            }.background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }

    private var trailBar: some View {
        HStack(spacing: 10) {
            Button { disk.goUp(to: disk.trail.count - 2) } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(disk.trail.count > 1 ? Palette.accent : Color.secondary.opacity(0.4))
                .disabled(disk.trail.count < 2 || disk.trashing)
                .help(L("Üst klasöre dön")).accessibilityLabel(L("Üst klasöre dön"))
                .accessibilityIdentifier("disk-up")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(disk.trail.enumerated()), id: \.offset) { depth, node in
                            if depth > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                            Button(depth == 0 ? title(of: disk.target) : node.name) { disk.goUp(to: depth) }
                                .buttonStyle(.plain).lineLimit(1)
                                .font(.system(size: 11, weight: depth == disk.trail.count - 1 ? .semibold : .regular))
                                .foregroundStyle(depth == disk.trail.count - 1 ? Color.primary : Color.secondary)
                                .disabled(disk.trashing)
                                .id(depth)
                        }
                    }
                }
                .onChange(of: disk.trail.count) { _, count in proxy.scrollTo(count - 1, anchor: .trailing) }
            }
            Spacer(minLength: 8)
            Text(Self.bytes(disk.currentSize)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .accessibilityIdentifier("disk-current-size")
        }.padding(.horizontal, 14).frame(height: 40)
    }

    private var actionBar: some View {
        let selected = disk.selectedRows
        return HStack(spacing: 12) {
            if disk.trashing {
                ProgressView().controlSize(.small)
                Text(L("Çöp Sepeti’ne taşınıyor…")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if selected.isEmpty {
                Text(L("Yer açmak için öğeleri işaretle. Klasörlerin içine girmek için satıra tıkla."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                let size = Self.bytes(selected.reduce(0) { $0 + ($1.size ?? 0) })
                Text(selected.count == 1 ? L("1 öğe seçildi · %@", size) : L("%d öğe seçildi · %@", selected.count, size))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .accessibilityIdentifier("disk-selection")
                Button(L("Seçimi temizle")) { disk.selection = [] }.buttonStyle(.link).font(.system(size: 10))
            }
            Spacer(minLength: 8)
            Button { confirmTrash(selected) } label: {
                Label(L("Çöp Sepeti’ne taşı"), systemImage: "trash").font(.system(size: 11, weight: .medium))
            }.controlSize(.small).disabled(selected.isEmpty || disk.trashing)
                .accessibilityIdentifier("disk-trash")
        }.padding(.horizontal, 14).frame(height: 42)
    }

    private func rowView(_ row: DiskRow) -> some View {
        let lock = disk.lock(for: row)
        let protected = lock != nil
        let selected = disk.selection.contains(row.id)
        let fraction = disk.currentSize > 0 ? Double(row.size ?? 0) / Double(disk.currentSize) : 0
        // What an unreadable folder holds is unknown, so neither a size nor a way in is shown.
        let size = row.unreadable ? nil : row.size
        let opens = row.node != nil && !row.unreadable
        return HStack(spacing: 11) {
            Group {
                if protected {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help(L(lock == .unmeasured
                                ? "Ne kadar yer kapladığı bilinmediği için seçilemez. Yeni klasörler için yeniden tara; bulutta duran öğeleri kendi uygulamasından yönet."
                                : "macOS veya hesabın için gerekli ya da içinde başka bir disk bağlı; bu yüzden taşınamaz. İçine girip öğe seçebilirsin."))
                } else {
                    Toggle(row.name, isOn: Binding(get: { selected }, set: { _ in disk.toggle(row) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .accessibilityIdentifier("disk-select-\(row.name)")
                }
            }.frame(width: 20)
            // The rest of the row is one button, apart from the checkbox: a folder opens;
            // a file has nothing to open, so the click ticks it. Being a real button, it
            // is also reachable from the keyboard and by VoiceOver.
            Button { if opens { disk.open(row) } else { disk.toggle(row) } } label: {
                HStack(spacing: 11) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.path)).resizable().interpolation(.high)
                        .frame(width: 24, height: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if let detail = detail(row) {
                            Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 10)
                    GeometryReader { area in
                        Capsule().fill(Palette.line)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Palette.accent.opacity(0.35 + 0.65 * min(1, fraction)))
                                    .frame(width: fraction > 0 ? max(3, area.size.width * min(1, fraction)) : 0)
                            }
                    }.frame(width: 90, height: 5).accessibilityHidden(true)
                    Text(size.map(Self.bytes) ?? "—").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(size == nil ? .tertiary : .primary)
                        .frame(width: 78, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .opacity(opens ? 1 : 0).accessibilityHidden(true)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disk.trashing || (!opens && protected))
                .accessibilityHint(opens ? L("Klasörü aç") : "")
                .accessibilityIdentifier("disk-open-\(row.name)")
        }.padding(.horizontal, 14).padding(.vertical, 9)
            .background(selected ? Palette.accent.opacity(0.07) : .clear)
            .contextMenu {
                if opens { Button(L("Klasörü aç")) { disk.open(row) } }
                Button(L("Finder’da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
                if !protected {
                    Divider()
                    Button(L("Çöp Sepeti’ne taşı")) { confirmTrash([row]) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("disk-row")
    }

    private func detail(_ row: DiskRow) -> String? {
        guard row.isDirectory else {
            if row.cloudOnly { return L("Yalnızca bulutta; bu Mac’te yer kaplamıyor") }
            return row.linked ? L("Başka bir yerde de bağlantısı var; taşımak yer açmayabilir") : nil
        }
        guard let count = row.fileCount else { return L("Taranmadı: başka bir disk, yalnızca bulutta duran veya yeni bir klasör") }
        return row.unreadable ? L("Okunamadı: erişim izni yok") : files(count)
    }

    // MARK: Trash

    private func confirmTrash(_ rows: [DiskRow]) {
        guard !rows.isEmpty, !disk.trashing else { return }
        let size = Self.bytes(rows.reduce(0) { $0 + ($1.size ?? 0) })
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = rows.count == 1 ? L("“%@” Çöp Sepeti’ne taşınsın mı?", rows[0].name)
            : L("%d öğe Çöp Sepeti’ne taşınsın mı?", rows.count)
        alert.informativeText = L("Toplam %@. Öğeler Çöp Sepeti’nden geri alınabilir; disk alanı Çöp Sepeti boşaltıldığında açılır.", size)
        alert.addButton(withTitle: L("Çöp Sepeti’ne taşı"))
        alert.addButton(withTitle: L("Vazgeç"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        disk.trash(rows)
    }

    private var trashedNote: some View {
        HStack(spacing: 10) {
            note(L("%@ Çöp Sepeti’ne taşındı. Disk alanını açmak için Çöp Sepeti’ni boşalt.", Self.bytes(disk.trashed)),
                 icon: "checkmark.circle", color: .green)
                .accessibilityIdentifier("disk-trashed")
            Button(L("Çöp Sepeti’ni aç")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true))
            }.controlSize(.small)
        }
    }

    private var accessNote: some View {
        HStack(spacing: 10) {
            note(L("Erişim izni olmadığı için okunamayan klasörler var (%d). Hepsini görmek için Sistem Ayarları’nda BStoeq’e Tam Disk Erişimi ver ve yeniden tara.", disk.unreadable),
                 icon: "hand.raised", color: Palette.accent)
                .accessibilityIdentifier("disk-unreadable")
            Button(L("Sistem Ayarlarını aç")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }.controlSize(.small)
        }
    }

    /// A disk holds more than its folders show: snapshots, other system volumes and
    /// whatever could not be read. Say so instead of leaving the gap unexplained.
    private var volumeSummary: String? {
        guard let target = disk.target, target.kind == .volume, let used = target.used else { return nil }
        let hidden = used - disk.scannedSize
        guard hidden > 1_000_000_000 else { return nil }
        return L("Diskte kullanılan alan %@. Taramada görünmeyen %@ sistem verileri, anlık görüntüler ve okunamayan klasörlerdir.",
                 Self.bytes(used), Self.bytes(hidden))
    }

    // MARK: Pieces

    private func note(_ message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(12).background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
    }
    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Palette.accent).frame(width: 27, height: 27)
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }
}
