import AppKit
import SwiftUI
import BStoeqCore

struct CacheCleanupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var cache: CacheCleanupManager
    @State private var showsScope = false
    @State private var expandedSources = Set<CacheSource>()
    @State private var fileLimits: [CacheSource: Int] = [:]
    @State private var appLimit = pageSize
    @State private var showsUnknownApps = false
    @State private var unknownLimit = pageSize

    private static let pageSize = 30
    private func L(_ key: String, _ arguments: CVarArg...) -> String {
        model.localizer.text(key, arguments: arguments)
    }
    private func files(_ count: Int) -> String { count == 1 ? L("1 dosya") : L("%d dosya", count) }
    private func apps(_ count: Int) -> String { count == 1 ? L("1 uygulama") : L("%d uygulama", count) }
    private func total(_ count: String, _ bytes: Int64) -> String { count + " · " + DiskView.bytes(bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Eski dosyalar ve uygulamalar"))
                    .font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text(L("Mac’ini tara ve Çöp Sepeti’ne taşımak istediklerini sonuçlardan seç."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            scanControls
            if let report = cache.report { outcome(report) }
            if cache.phase == .ready || cache.phase == .cleaning
                || (cache.phase == .idle && (cache.scanFailed || cache.appsScanFailed)) {
                fileSection
                appSection
            } else if cache.phase == .scanning && !cache.groups.isEmpty {
                fileSection
            }
            Button { model.selection = "disk" } label: {
                Label(L("Disk alanında başka bir klasörü incele"), systemImage: "externaldrive")
            }.buttonStyle(.link).font(.system(size: 11))
        }
        .onChange(of: cache.phase) { _, phase in
            if phase == .scanning {
                if cache.groups.isEmpty {
                    expandedSources.removeAll()
                    fileLimits.removeAll()
                }
                appLimit = Self.pageSize
                showsUnknownApps = false
                unknownLimit = Self.pageSize
            }
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Temizlik taraması")).font(.system(size: 13, weight: .medium))
                    Group {
                        switch cache.phase {
                        case .scanning: Text(L(cache.scanStep))
                        case .cleaning:
                            Text(cache.isStopping ? L("Geçerli öğe tamamlanınca duracak…") : L("Çöp Sepeti’ne taşınıyor…"))
                        case .idle, .ready:
                            Text(L("Önbellekler, günlükler, geliştirici dosyaları, yükleyiciler ve uygulamalar"))
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if cache.phase == .scanning {
                    ProgressView().controlSize(.small)
                    Button(L("Durdur")) { cache.cancelScan() }.accessibilityIdentifier("cache-stop")
                } else if cache.phase == .cleaning {
                    Button(L("Durdur")) { cache.stopCleaning() }.disabled(cache.isStopping)
                        .accessibilityIdentifier("cleanup-stop-moving")
                } else {
                    Button(cache.phase == .idle && !cache.scanFailed ? L("Taramayı başlat") : L("Yeniden tara")) {
                        cache.scan()
                    }.disabled(cache.phase == .cleaning).accessibilityIdentifier("cache-scan")
                }
            }
            if cache.phase == .cleaning {
                HStack(spacing: 10) {
                    ProgressView(value: Double(cache.cleanedCount), total: Double(max(1, cache.cleanupTotal)))
                        .progressViewStyle(.linear).accessibilityLabel(L("Temizlik ilerlemesi"))
                    Text(L("İşlenen · %d / %d", cache.cleanedCount, cache.cleanupTotal))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                Text(L("Uygulamalar için kullanım eşiği")).font(.system(size: 11)).foregroundStyle(.secondary)
                Picker(L("Uygulamalar için kullanım eşiği"), selection: Binding(
                    get: { cache.appAgeDays }, set: { cache.setAppAgeDays($0) })) {
                    ForEach([30, 90, 180], id: \.self) { days in Text(L("%d gün", days)).tag(days) }
                }.labelsHidden().fixedSize().disabled(cache.phase == .scanning || cache.phase == .cleaning)
                    .accessibilityIdentifier("cleanup-app-age")
            }
            DisclosureGroup(L("Taranan konumlar"), isExpanded: $showsScope) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(CacheSource.allCases, id: \.self) { source in
                        let report = cache.sourceReports.first { $0.source == source }
                        scopeRow(L(source.titleKey), path: paths(for: source), status: report.map(sourceStatus),
                                 warning: (report?.unreadable ?? 0) > 0)
                    }
                    scopeRow(L("Uygulamalar"), path: "/Applications\n~/Applications")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
            }.font(.system(size: 11))
        }.controlSize(.small).padding(17).modifier(CleanupCard())
    }

    private func paths(for source: CacheSource) -> String {
        switch source {
        case .userCaches: "~/Library/Caches"
        case .containerCaches: "~/Library/Containers/*/Data/Library/Caches"
        case .groupContainerCaches: "~/Library/Group Containers/*/Library/Caches"
        case .browserCaches:
            "~/Library/Application Support/…/Cache/Cache_Data\n~/Library/Application Support/…/GPUCache\n~/Library/Application Support/…/Code Cache/{js, wasm}"
        case .logs: "~/Library/Logs"
        case .xcode: "~/Library/Developer/Xcode/DerivedData"
        case .developerCaches: "~/.npm/_cacache/tmp\n~/.cache/pip/wheels\n~/.gradle/caches/build-cache-1"
        case .installers: "~/Downloads  (.dmg, .pkg, .mpkg, .xip)"
        }
    }

    private func sourceStatus(_ report: CacheSourceReport) -> String {
        guard report.scannedRoots > 0 else {
            return report.unreadable > 0 ? L("Erişilemedi") : L("Konum bulunamadı")
        }
        let scanned = report.scannedRoots == 1 ? L("1 konum tarandı") : L("%d konum tarandı", report.scannedRoots)
        guard report.unreadable > 0 else { return scanned }
        return scanned + " · " + L("Okunamayan öğe sayısı %d", report.unreadable)
    }

    private func scopeRow(_ title: String, path: String, status: String? = nil, warning: Bool = false) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.secondary)
                if let status {
                    Text(status).font(.system(size: 10)).foregroundStyle(warning ? Color.orange : Color.secondary)
                }
            }
            Text(verbatim: path).font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var fileSection: some View {
        let grouped = Dictionary(grouping: cache.groups, by: \.source)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(L("Eski dosyalar"))
                Spacer()
                if !cache.groups.isEmpty {
                    let count = cache.groups.reduce(0) { $0 + $1.fileCount }
                    let size = cache.groups.reduce(Int64(0)) { $0 + $1.bytes }
                    Text(total(files(count), size)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(L("Son erişimi ve değişikliği en az 30 gün önce olan dosyalar."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if cache.scanFailed {
                notice(L("Dosya taraması tamamlanamadı. Yeniden deneyebilirsin."), warning: true)
            } else {
                if cache.unreadable > 0 {
                    HStack(spacing: 10) {
                        notice(L("Okunamayan öğeler (%d) tarama sonucuna dahil edilmedi.", cache.unreadable)
                               + " " + L("Korumalı konumlara erişimi macOS yönetir. Tam Disk Erişimi ayarını değiştirirsen yeniden tara."),
                               warning: true)
                        Button(L("Tam Disk Erişimi…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }.controlSize(.small)
                    }
                }
                if cache.groups.isEmpty {
                    emptyMessage(L("Taranan konumlarda temizlenecek eski dosya bulunamadı."))
                } else {
                    VStack(spacing: 0) {
                        actionBar(summary: total(files(cache.selectedCount), cache.selectedBytes),
                                  selected: !cache.selection.isEmpty, title: L("Dosyaları taşı…"),
                                  identifier: "cache-trash", action: confirmFiles)
                        if cache.hasBulkSelectableGroups {
                            Divider()
                            HStack {
                                Button(cache.allCacheGroupsSelected ? L("Önbellek ve günlük seçimini kaldır") : L("Tüm önbellek ve günlükleri seç")) {
                                    cache.toggleAll()
                                }.buttonStyle(.link).font(.system(size: 11)).accessibilityIdentifier("cache-select-all")
                                Spacer()
                            }.padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        ForEach(CacheSource.allCases, id: \.self) { source in
                            if let groups = grouped[source] { sourceRows(source, groups: groups) }
                        }
                    }.modifier(CleanupCard()).disabled(cache.phase != .ready)
                }
            }
        }
    }

    private func sourceRows(_ source: CacheSource, groups: [CacheGroup]) -> some View {
        let expanded = expandedSources.contains(source)
        let limit = fileLimits[source] ?? Self.pageSize
        let size = groups.reduce(Int64(0)) { $0 + $1.bytes }
        let count = groups.reduce(0) { $0 + $1.fileCount }
        let selected = groups.filter { cache.selection.contains($0.id) }.count
        return VStack(spacing: 0) {
            Divider()
            Button {
                if expanded { expandedSources.remove(source) } else { expandedSources.insert(source) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(L(source.titleKey)).font(.system(size: 12, weight: .medium))
                    if selected > 0 {
                        Image(systemName: selected == groups.count ? "checkmark.circle.fill" : "minus.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Palette.accent)
                            .accessibilityLabel(selected == groups.count ? L("Tümü seçildi") : L("Kısmen seçildi"))
                    }
                    Spacer(minLength: 8)
                    Text(total(files(count), size)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }.contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 11)
            }.buttonStyle(.plain)
                .accessibilityValue(expanded ? L("Genişletilmiş") : L("Daraltılmış"))
            if expanded {
                if source == .installers {
                    Text(L("İndirilenler’deki disk görüntülerini ve yükleyicileri tek tek seç."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 36).padding(.bottom, 6)
                }
                LazyVStack(spacing: 0) {
                    ForEach(groups.prefix(limit)) { group in
                        Divider().padding(.leading, 36)
                        fileRow(group)
                    }
                    if groups.count > limit {
                        moreButton(remaining: groups.count - limit) { fileLimits[source] = limit + Self.pageSize }
                    }
                }
            }
        }
    }

    private func fileRow(_ group: CacheGroup) -> some View {
        let name = group.name.isEmpty ? L("Ana klasördeki dosyalar") : group.name
        return Toggle(isOn: Binding(get: { cache.selection.contains(group.id) }, set: { _ in cache.toggle(group) })) {
            HStack(spacing: 12) {
                Text(name).lineLimit(1).truncationMode(.middle).help(name)
                Spacer(minLength: 8)
                Text(files(group.fileCount)).foregroundStyle(.secondary).fixedSize()
                Text(DiskView.bytes(group.bytes)).frame(minWidth: 70, alignment: .trailing)
            }.font(.system(size: 11)).monospacedDigit()
        }.toggleStyle(.checkbox).padding(.leading, 36).padding(.trailing, 14).padding(.vertical, 8)
            .accessibilityIdentifier("cache-group-\(group.id)")
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(L("Uzun süredir kullanılmayan uygulamalar"))
                Spacer()
                if !cache.apps.isEmpty {
                    Text(total(apps(cache.apps.count), cache.apps.reduce(0) { $0 + $1.bytes }))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(L("Son kullanım kaydı en az %d gün öncesine ait uygulamalar. Taşınacak uygulamaları tek tek seç.", cache.appAgeDays))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if cache.appsScanFailed {
                notice(L("Uygulama taraması tamamlanamadı. Yeniden deneyebilirsin."), warning: true)
            } else {
                if cache.appUnreadable > 0 { notice(L("Okunamayan uygulama veya klasör sayısı · %d", cache.appUnreadable), warning: true) }
                if cache.apps.isEmpty {
                    emptyMessage(L("İncelenen uygulamalar arasında bu ölçüte uyan uygulama bulunamadı."))
                } else {
                    LazyVStack(spacing: 0) {
                        actionBar(summary: total(apps(cache.appSelection.count), cache.selectedAppBytes),
                                  selected: !cache.appSelection.isEmpty, title: L("Uygulamaları taşı…"),
                                  identifier: "cleanup-app-trash", action: confirmApps)
                        ForEach(cache.apps.prefix(appLimit), id: \.path) { app in
                            Divider()
                            appRow(app)
                        }
                        if cache.apps.count > appLimit {
                            moreButton(remaining: cache.apps.count - appLimit) { appLimit += Self.pageSize }
                        }
                    }.modifier(CleanupCard()).disabled(cache.phase != .ready)
                }
                if cache.unassessableApps > 0 { unknownApps }
            }
        }
    }

    private var unknownApps: some View {
        DisclosureGroup(L("Son kullanım kaydı bulunmayan uygulamalar (%d)", cache.unassessableApps),
                        isExpanded: $showsUnknownApps) {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(L("Bu uygulamaları Finder’da inceleyebilirsin."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8)
                ForEach(cache.unknownUsageApps.prefix(unknownLimit), id: \.path) { app in
                    Divider()
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.system(size: 11, weight: .medium))
                            Text(verbatim: app.path).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(app.path)
                        }
                        Spacer(minLength: 8)
                        Button(L("Finder’da göster")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                        }.controlSize(.small)
                    }.padding(.vertical, 7)
                }
                if cache.unknownUsageApps.count > unknownLimit {
                    moreButton(remaining: cache.unknownUsageApps.count - unknownLimit) { unknownLimit += Self.pageSize }
                }
            }
        }.font(.system(size: 11)).padding(14).modifier(CleanupCard())
    }

    private func appRow(_ app: UnusedApp) -> some View {
        let date = app.lastUsed.formatted(.dateTime.year().month(.abbreviated).day()
            .locale(Locale(identifier: model.localizer.language.rawValue)))
        return Toggle(isOn: Binding(get: { cache.appSelection.contains(app.id) }, set: { _ in cache.toggleApp(app) })) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(verbatim: app.path).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(app.path)
                }
                Spacer(minLength: 6)
                Text(L("Son kullanım · %@", date)).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(DiskView.bytes(app.bytes)).font(.system(size: 11)).monospacedDigit()
                    .frame(minWidth: 68, alignment: .trailing)
            }
        }.toggleStyle(.checkbox).padding(.horizontal, 14).padding(.vertical, 10)
            .accessibilityIdentifier("cleanup-app-\(app.id)")
    }

    private func actionBar(summary: String, selected: Bool, title: String,
                           identifier: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(selected ? L("Seçim · %@", summary) : L("Seçim yapılmadı"))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 6)
            Button(action: action) { Label(title, systemImage: "trash") }
                .controlSize(.small).disabled(!selected).accessibilityIdentifier(identifier)
        }.padding(.horizontal, 14).frame(minHeight: 42)
    }

    private func confirmFiles() {
        guard cache.phase == .ready, cache.selectedCount > 0 else { return }
        let installers = cache.groups.filter { $0.source == .installers && cache.selection.contains($0.id) }
        confirm(title: L("Seçili dosyalar Çöp Sepeti’ne taşınsın mı?"),
                summary: total(files(cache.selectedCount), cache.selectedBytes),
                details: installers.flatMap { $0.files.map(\.path) },
                action: cache.cleanSelection)
    }

    private func confirmApps() {
        guard cache.phase == .ready, !cache.appSelection.isEmpty else { return }
        let selected = cache.apps.filter { cache.appSelection.contains($0.id) }
        confirm(title: L("Seçili uygulamalar Çöp Sepeti’ne taşınsın mı?"),
                summary: total(apps(selected.count), cache.selectedAppBytes),
                details: selected.map { $0.name + " — " + $0.path },
                action: cache.cleanSelectedApps)
    }

    private func confirm(title: String, summary: String, details: [String], action: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = summary + "\n\n" + L("Seçtiklerini Çöp Sepeti’nden geri alabilirsin. Disk alanı Çöp Sepeti boşaltıldığında açılır.")
        if !details.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(128, 36 * details.count)))
            scroll.hasVerticalScroller = true
            let names = NSTextView(frame: scroll.contentView.bounds)
            names.isEditable = false
            names.font = .systemFont(ofSize: 11)
            names.textContainer?.widthTracksTextView = true
            names.string = details.joined(separator: "\n")
            scroll.documentView = names
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: L("Vazgeç"))
        alert.addButton(withTitle: L("Çöp Sepeti’ne taşı")).hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { action() }
    }

    private func outcome(_ report: CacheCleanupSummary) -> some View {
        let format = report.isApps ? apps : files
        var lines = [L("Çöp Sepeti’ne taşınan · %@ · %@", format(report.movedCount), DiskView.bytes(report.movedBytes))]
        if report.skippedCount > 0 { lines.append(L("Artık uygun olmadığı için atlanan · %@", format(report.skippedCount))) }
        if report.failedCount > 0 { lines.append(L("Taşınamayan · %@", format(report.failedCount))) }
        if report.wasStopped { lines.append(L("Temizlik durduruldu. Kalan öğeleri listeden inceleyebilirsin.")) }
        if report.movedCount > 0 { lines.append(L("Disk alanı Çöp Sepeti boşaltıldığında açılır.")) }
        return notice(lines.joined(separator: "\n"), warning: report.wasStopped || report.skippedCount > 0 || report.failedCount > 0)
            .accessibilityIdentifier("cache-outcome")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).textCase(.uppercase).font(.system(size: 9, weight: .semibold))
            .tracking(1.2).foregroundStyle(.secondary)
    }

    private func moreButton(remaining: Int, action: @escaping () -> Void) -> some View {
        Button(L("Daha fazla göster (%d öğe daha)", remaining), action: action)
            .buttonStyle(.link).font(.system(size: 11)).padding(10)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).modifier(CleanupCard())
    }

    private func notice(_ message: String, warning: Bool) -> some View {
        let color: Color = warning ? .orange : .green
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: warning ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(color).accessibilityHidden(true)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(12).background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct CleanupCard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }
}
