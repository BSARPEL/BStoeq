import AppKit
import SwiftUI
import BStoeqCore

struct UninstallView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var uninstaller: AppUninstallManager
    @State private var search = ""
    @State private var limit = UninstallView.pageSize

    static let pageSize = 40
    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    private func items(_ count: Int) -> String { count == 1 ? L("1 öğe") : L("%d öğe", count) }
    private func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private var filtered: [InstalledApp] {
        guard !search.isEmpty else { return uninstaller.apps }
        return uninstaller.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Geride iz bırakmadan kaldır.")).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text(L("Bir uygulamayı, Kitaplık’ta bıraktığı verilerle birlikte Çöp Sepeti’ne taşı."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let report = uninstaller.report { outcome(report) }
            switch uninstaller.phase {
            case .idle, .listing, .list:
                listCard
                note(L("Apple uygulamaları listelenmez. BStoeq hiçbir şeyi kalıcı olarak silmez; kaldırılan uygulama ve verileri Çöp Sepeti’nden geri alınabilir."),
                     icon: "info.circle", color: Palette.accent)
            case .inspecting:
                inspectingCard
            case .review, .removing:
                reviewCard
            }
        }
        .onAppear { uninstaller.refresh() }
        .onChange(of: search) { _, _ in limit = Self.pageSize }
    }

    // MARK: List

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("KURULU UYGULAMALAR")).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                if !uninstaller.apps.isEmpty {
                    Text("\(filtered.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Palette.line, in: Capsule())
                }
                Spacer()
                if uninstaller.phase == .listing { ProgressView().controlSize(.small) }
                Button { uninstaller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Uygulamaları yenile"))
                    .accessibilityLabel(L("Uygulamaları yenile")).disabled(uninstaller.phase == .listing)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(L("Uygulama ara…"), text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("uninstall-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel(L("Kapat"))
                }
            }.font(.system(size: 11)).padding(9).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
            LazyVStack(spacing: 0) {
                if filtered.isEmpty {
                    Text(uninstaller.phase == .list ? L("Bu görünümde uygulama yok") : L("Uygulamalar taranıyor…"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(22)
                }
                ForEach(filtered.prefix(limit)) { app in
                    appRow(app)
                    if app.id != filtered.prefix(limit).last?.id { Divider().padding(.leading, 55).opacity(0.5) }
                }
                if filtered.count > limit {
                    Divider().opacity(0.5)
                    Button(L("Daha fazla göster (%d öğe daha)", filtered.count - limit)) { limit += Self.pageSize }
                        .buttonStyle(.link).font(.system(size: 11)).padding(13)
                }
            }.background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high)
                .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !app.version.isEmpty {
                        Text(verbatim: app.version).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Text(verbatim: short(app.path)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(app.path)
            }
            Spacer(minLength: 8)
            if uninstaller.runningApps.contains(app.path) { runningBadge }
            Button(L("İncele")) { uninstaller.inspect(app) }.controlSize(.small)
                .disabled(uninstaller.phase != .list)
                .accessibilityIdentifier("uninstall-inspect-\(app.bundleIdentifier)")
        }.padding(.horizontal, 14).padding(.vertical, 9)
            .contextMenu {
                Button(L("Finder’da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
            }
    }

    private var runningBadge: some View {
        Text(L("Çalışıyor")).font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.12), in: Capsule())
    }

    // MARK: Review

    private var inspectingCard: some View {
        card(L("İNCELENİYOR")) {
            HStack(spacing: 14) {
                if let app = uninstaller.current {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high)
                        .frame(width: 30, height: 30).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                        Text(L("Uygulama ölçülüyor ve Kitaplık’taki verileri aranıyor…"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Button(L("Vazgeç")) { uninstaller.back() }.controlSize(.small)
                    .accessibilityIdentifier("uninstall-cancel-inspect")
            }.padding(17)
        }
    }

    @ViewBuilder private var reviewCard: some View {
        if let plan = uninstaller.plan {
            let removing = uninstaller.phase == .removing
            VStack(alignment: .leading, spacing: 14) {
                card(L("KALDIRILACAKLAR")) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.square.fill").font(.system(size: 13)).foregroundStyle(.tertiary)
                            .frame(width: 20).help(L("Uygulamanın kendisi her zaman taşınır."))
                        Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.path)).resizable().interpolation(.high)
                            .frame(width: 30, height: 30).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(verbatim: plan.app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if !plan.app.version.isEmpty {
                                    Text(verbatim: plan.app.version).font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                                if uninstaller.isCurrentRunning { runningBadge }
                            }
                            Text(verbatim: short(plan.app.path)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(plan.app.path)
                        }
                        Spacer(minLength: 8)
                        Text(DiskView.bytes(plan.appBytes)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                    ForEach(plan.leftovers) { leftover in
                        Divider().padding(.leading, 46).opacity(0.5)
                        leftoverRow(leftover)
                    }
                    if plan.leftovers.isEmpty {
                        Divider().opacity(0.5)
                        Text(plan.sharesData
                             ? L("Aynı kimliği kullanan başka bir kopya kurulu. Ortak verileri yerinde kalır; yalnızca bu uygulama taşınır.")
                             : L("Kitaplık’ta bu uygulamaya ait veri bulunamadı."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                }.disabled(removing)
                if plan.leftovers.contains(where: \.matchedByName) {
                    note(L("“Ada göre” işaretli klasörler uygulamanın kimliğiyle değil adıyla eşleşti. Başka bir uygulamaya ait olabilir; emin olduğunda işaretle."),
                         icon: "questionmark.circle", color: Palette.accent)
                }
                if uninstaller.isCurrentRunning && !removing {
                    note(L("Uygulama açık. Kaldırmak için önce uygulamadan çık."), icon: "exclamationmark.triangle", color: .orange)
                        .accessibilityIdentifier("uninstall-running")
                }
                HStack(spacing: 12) {
                    if removing {
                        ProgressView(value: Double(uninstaller.removedCount), total: Double(max(1, uninstaller.removeTotal)))
                            .progressViewStyle(.linear).frame(maxWidth: 180).accessibilityLabel(L("Temizlik ilerlemesi"))
                        Text(uninstaller.isStopping ? L("Geçerli öğe tamamlanınca duracak…")
                                                    : L("İşlenen · %d / %d", uninstaller.removedCount, uninstaller.removeTotal))
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 8)
                        Button(L("Durdur")) { uninstaller.stopRemoving() }.disabled(uninstaller.isStopping)
                    } else {
                        Text(L("Seçim · %@", items(1 + uninstaller.selection.count) + " · " + DiskView.bytes(uninstaller.selectedBytes)))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .accessibilityIdentifier("uninstall-selection")
                        Spacer(minLength: 8)
                        Button(L("Vazgeç")) { uninstaller.back() }.accessibilityIdentifier("uninstall-back")
                        Button { confirm(plan) } label: {
                            Label(L("Kaldır…"), systemImage: "trash").font(.system(size: 12, weight: .medium))
                        }.buttonStyle(.borderedProminent).disabled(uninstaller.isCurrentRunning)
                            .accessibilityIdentifier("uninstall-confirm")
                    }
                }
            }
        }
    }

    private func leftoverRow(_ leftover: AppLeftover) -> some View {
        Toggle(isOn: Binding(get: { uninstaller.selection.contains(leftover.id) }, set: { _ in uninstaller.toggle(leftover) })) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L(leftover.kind.titleKey)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if leftover.matchedByName {
                            Text(L("Ada göre")).font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.accent.opacity(0.10), in: Capsule())
                        }
                    }
                    Text(verbatim: short(leftover.path)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(leftover.path)
                }
                Spacer(minLength: 8)
                Text(leftover.bytes.map(DiskView.bytes) ?? "—").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(leftover.bytes == nil ? .tertiary : .primary)
                    .help(leftover.bytes == nil ? L("Okunamadı: erişim izni yok") : "")
            }
        }.toggleStyle(.checkbox).padding(.horizontal, 14).padding(.vertical, 8)
            .contextMenu {
                Button(L("Finder’da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: leftover.path)]) }
            }
            .accessibilityIdentifier("uninstall-leftover-\(leftover.path)")
    }

    private func confirm(_ plan: AppUninstallPlan) {
        guard uninstaller.phase == .review else { return }
        let chosen = plan.leftovers.filter { uninstaller.selection.contains($0.id) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("“%@” kaldırılsın mı?", plan.app.name)
        alert.informativeText = items(1 + chosen.count) + " · " + DiskView.bytes(uninstaller.selectedBytes) + "\n\n"
            + L("Uygulama ve seçtiğin verileri Çöp Sepeti’ne taşınır; oradan geri alabilirsin. macOS yönetici onayı isteyebilir.")
        let details = [plan.app.path] + chosen.map(\.path)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: min(128, 22 * details.count + 8)))
        scroll.hasVerticalScroller = true
        let names = NSTextView(frame: scroll.contentView.bounds)
        names.isEditable = false
        names.font = .systemFont(ofSize: 11)
        names.textContainer?.widthTracksTextView = true
        names.string = details.map(short).joined(separator: "\n")
        scroll.documentView = names
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("Vazgeç"))
        alert.addButton(withTitle: L("Kaldır")).hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { uninstaller.uninstall() }
    }

    // MARK: Outcome

    private func outcome(_ report: AppUninstallSummary) -> some View {
        var lines: [String] = []
        var warning = true
        switch report.outcome {
        case .moved:
            lines.append(L("“%@” kaldırıldı · %@ · %@", report.appName, items(report.movedCount), DiskView.bytes(report.movedBytes)))
            if report.skippedCount > 0 { lines.append(L("İncelemeden sonra değiştiği için atlanan · %@", items(report.skippedCount))) }
            if !report.failedPaths.isEmpty {
                lines.append(L("Taşınamayan · %@", items(report.failedPaths.count)))
                lines.append(contentsOf: report.failedPaths.prefix(4).map(short))
                lines.append(L("Korumalı konumlara erişimi macOS yönetir. Tam Disk Erişimi ayarını değiştirirsen yeniden tara."))
            }
            if report.wasStopped { lines.append(L("Temizlik durduruldu. Kalan öğeleri listeden inceleyebilirsin.")) }
            lines.append(L("Disk alanı Çöp Sepeti boşaltıldığında açılır."))
            warning = report.skippedCount > 0 || !report.failedPaths.isEmpty || report.wasStopped
        case .running:
            lines.append(L("“%@” açık olduğu için kaldırılmadı. Uygulamadan çıkıp yeniden dene.", report.appName))
        case .changed:
            lines.append(L("“%@” incelemeden sonra değişti ya da taşındı; hiçbir şeye dokunulmadı.", report.appName))
        case .failed(let detail):
            lines.append(L("“%@” Çöp Sepeti’ne taşınamadı; verilerine dokunulmadı.", report.appName))
            lines.append(detail)
            lines.append(L("Uygulamayı Finder’dan Çöp Sepeti’ne sürükleyebilir ya da Sistem Ayarları → Gizlilik ve Güvenlik → Uygulama Yönetimi bölümünde BStoeq’e izin verebilirsin."))
        }
        let moved = report.outcome == .moved
        return HStack(spacing: 10) {
            note(lines.joined(separator: "\n"), icon: warning ? "exclamationmark.triangle" : "checkmark.circle",
                 color: warning ? .orange : .green)
                .accessibilityIdentifier("uninstall-outcome")
            if moved {
                Button(L("Çöp Sepeti’ni aç")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true))
                }.controlSize(.small)
            } else if case .failed = report.outcome, let app = uninstaller.current {
                Button(L("Finder’da göster")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                }.controlSize(.small)
            }
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
