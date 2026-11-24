import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BStoeqCore
import ConvertCore

/// The converter page: files waiting for a target, recent conversions with undo and retry, the ring's
/// settings and the stored output settings. `watchFolders` is drawn between the ring's card and the
/// output settings: the watched-folders card belongs there.
struct ConvertView<WatchFolders: View>: View {
    @ObservedObject var model: AppModel
    @ObservedObject var converter: ConverterManager
    private let watchFolders: WatchFolders
    @State private var dropTargeted = false
    @State private var copiedTool: String?
    /// Tools whose absence keeps some target from this Mac; asking the engine is not done in `body`.
    @State private var missingTools: [String] = []
    @State private var expanded = Set<UUID>()
    @State private var showsOutput = false
    @State private var historyLimit = 10
    /// Records that can be undone or retried right now. Both read the disk, so neither is asked in `body`.
    @State private var undoable = Set<UUID>()
    @State private var retryable = Set<UUID>()

    init(model: AppModel, converter: ConverterManager, @ViewBuilder watchFolders: () -> WatchFolders) {
        _model = ObservedObject(wrappedValue: model)
        _converter = ObservedObject(wrappedValue: converter)
        self.watchFolders = watchFolders()
    }

    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    private func files(_ count: Int) -> String { count == 1 ? L("1 dosya") : L("%d dosya", count) }
    private var locale: Locale { Locale(identifier: model.localizer.language.rawValue) }
    private var options: ConversionOptions { model.preferences.converter.options }
    private var chosenOffer: TargetOffer? { converter.pendingOffers.first { $0.id == converter.targetID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Dosyaları olduğu yerde dönüştür.")).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text(L("Görüntü, PDF, belge, ses ve video. Her şey bu Mac’te kalır."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let problem = converter.problem {
                HStack {
                    note(problem.text(using: model.localizer), icon: "exclamationmark.triangle", color: .orange)
                        .accessibilityIdentifier("convert-problem")
                    Button { converter.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(L("Kapat"))
                }
            }
            if converter.toolsChecked && !missingTools.isEmpty { toolsCard }
            newConversion
            recent
            dragCard
            watchFolders
            outputCard
        }
        .onAppear { refreshMissingTools(); refreshRecords() }
        .onChange(of: converter.environment) { _, _ in refreshMissingTools() }
        .onChange(of: converter.history) { _, _ in refreshRecords() }
    }

    // MARK: Tools

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(missingTools, id: \.self) { tool in
                let command = ConversionEnvironment.installCommand(for: tool) ?? ""
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle").foregroundStyle(Palette.accent).accessibilityHidden(true)
                    Text(tool == "ffmpeg" ? L("MP3, Opus, WebM ve MKV için ffmpeg gerekir.") : L("WebP için cwebp gerekir."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text(verbatim: command)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Palette.line, in: RoundedRectangle(cornerRadius: 7))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedTool = tool
                    } label: {
                        Label(L("Komutu kopyala"), systemImage: copiedTool == tool ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                    }.controlSize(.small).accessibilityIdentifier("convert-copy-\(tool)")
                    if tool == missingTools.last {
                        Button(L("Yeniden denetle")) { converter.refreshTools(); copiedTool = nil }
                            .controlSize(.small).accessibilityIdentifier("convert-tools-recheck")
                    }
                }.padding(.leading, 24)
            }
        }.padding(14).background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 11))
    }

    /// Only tools that would unlock a target here: with no converter that uses cwebp, cwebp is not missing.
    private func refreshMissingTools() {
        let engine = converter.engine
        Task {
            let tools = await Task.detached(priority: .userInitiated) {
                ["ffmpeg", "cwebp"].filter { tool in TargetCatalog.all.contains { engine.availability(of: $0) == .needs(tool) } }
            }.value
            if tools != missingTools { missingTools = tools }
        }
    }

    // MARK: New conversion

    private var newConversion: some View {
        card(L("YENİ DÖNÜŞTÜRME")) {
            dropZone.padding(17)
            if !converter.pending.isEmpty {
                Divider()
                ForEach(Array(converter.pending.enumerated()), id: \.element) { index, url in
                    if index > 0 { Divider().padding(.leading, 58).opacity(0.5) }
                    pendingRow(url, index: index)
                }
                Divider()
                targetRow
                if let target = chosenOffer?.target { draftRows(for: target) }
                Divider().padding(.leading, 52)
                HStack(spacing: 12) {
                    if chosenOffer?.target.combines == true {
                        Text(L("Birleştirmede bu sıra kullanılır.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { converter.startPending() } label: {
                        Label(L("Dönüştür"), systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.borderedProminent).disabled(chosenOffer?.isUsable != true)
                        .accessibilityIdentifier("convert-start")
                }.padding(17)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in receive(providers) }
    }

    private var dropZone: some View {
        VStack(spacing: 9) {
            Image(systemName: "arrow.down.doc").font(.system(size: 22)).foregroundStyle(Palette.accent).accessibilityHidden(true)
            Text(L("Dosyaları buraya bırak")).font(.system(size: 12, weight: .medium))
            Button(L("Dosya seç…")) { chooseFiles() }.controlSize(.small).accessibilityIdentifier("convert-choose-files")
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
            .background(Palette.accent.opacity(dropTargeted ? 0.19 : 0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.accent.opacity(dropTargeted ? 1 : 0.35),
                                                                     style: StrokeStyle(lineWidth: dropTargeted ? 1.5 : 1, dash: dropTargeted ? [] : [5, 4])))
            .accessibilityElement(children: .contain).accessibilityIdentifier("convert-drop")
    }

    private func pendingRow(_ url: URL, index: Int) -> some View {
        let count = converter.pending.count
        return HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
                .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: url.lastPathComponent).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(url.path)
                Text(verbatim: details(of: url)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if count > 1 {
                iconButton("arrow.up.circle", L("Yukarı taşı")) { move(index, by: -1) }.disabled(index == 0)
                iconButton("arrow.down.circle", L("Aşağı taşı")) { move(index, by: 1) }.disabled(index == count - 1)
            }
            iconButton("minus.circle", L("Listeden kaldır")) { converter.pending.removeAll { $0 == url } }
        }.padding(.horizontal, 17).padding(.vertical, 9)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("convert-pending-item")
    }

    /// "PNG · 2,4 MB": the format as the converter sees it and the size on disk.
    private func details(of url: URL) -> String {
        var parts: [String] = []
        if let format = FormatRegistry.format(of: url) { parts.append(format.family == .folder ? L("Klasör") : format.label) }
        var status = stat()
        if lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG { parts.append(DiskView.bytes(Int64(status.st_size))) }
        return parts.joined(separator: " · ")
    }

    private func move(_ index: Int, by offset: Int) {
        guard converter.pending.indices.contains(index), converter.pending.indices.contains(index + offset) else { return }
        converter.pending.swapAt(index, index + offset)
    }

    private var targetRow: some View {
        let offer = chosenOffer
        let offers = converter.pendingOffers
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                rowIcon(offer?.target.symbol ?? "arrow.triangle.2.circlepath")
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Hedef")).font(.system(size: 12, weight: .medium))
                    if let offer, offer.availability == .available, offer.fitting < offer.total {
                        Text(L("Uygun dosyalar: %@", "\(offer.fitting) / \(offer.total)"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Menu {
                    Section(L("Biçimler")) {
                        ForEach(offers.filter { $0.target.kind == .convert }) { offerItem($0) }
                    }
                    Section(L("Araçlar")) {
                        ForEach(offers.filter { $0.target.kind == .tool }) { offerItem($0) }
                    }
                } label: {
                    Text(offer.map { title(of: $0.target) } ?? L("Hedef seç")).font(.system(size: 12))
                }.fixedSize().disabled(offers.isEmpty).accessibilityIdentifier("convert-target")
            }
            if let offer, let reason = reason(offer) {
                Text(reason).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 41)
            } else if let note = offer?.noteKey {
                Text(L(note)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 41)
                    .accessibilityIdentifier("convert-target-note")
            } else if offers.isEmpty {
                Text(L("Bu dosya bu biçime dönüştürülemiyor.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.leading, 41)
            }
        }.padding(17)
    }

    /// A checkmark item, greyed with its reason as a second line when it cannot start.
    private func offerItem(_ offer: TargetOffer) -> some View {
        Toggle(isOn: Binding(get: { converter.targetID == offer.id }, set: { if $0 { converter.targetID = offer.id } })) {
            Text(title(of: offer.target))
            if let reason = reason(offer) { Text(reason) }
        }.disabled(!offer.isUsable)
    }

    private func reason(_ offer: TargetOffer) -> String? {
        if case .needs(let tool) = offer.availability { return L("Bu dönüştürme için %@ gerekli.", tool) }
        if offer.availability == .unsupported { return L("Bu dosya bu biçime dönüştürülemiyor.") }
        if offer.fitting < max(1, offer.target.minimumInputs) { return L("Birleştirmek için en az iki dosya gerekir.") }
        return nil
    }

    private func title(of target: ConversionTarget) -> String { target.titleIsKey ? L(target.title) : target.title }

    /// The per-job choices this target uses: one it fixes itself ("MP4 720p", "Sessiz") is not offered.
    @ViewBuilder private func draftRows(for target: ConversionTarget) -> some View {
        let families: Set<FileFamily> = target.format == "*"
            ? Set(converter.pending.compactMap { FormatRegistry.format(of: $0)?.family })
            : Set([FormatRegistry.format(id: target.format)?.family].compactMap { $0 })
        if families.contains(.image) && target.overrides.imageResize == nil {
            Divider().padding(.leading, 52)
            row(L("Boyut"), L("Görüntü hiçbir zaman büyütülmez."), symbol: "arrow.up.left.and.arrow.down.right") {
                Picker(L("Boyut"), selection: $converter.draftResize) {
                    ForEach(ImageResize.presets, id: \.self) { Text(resizeTitle($0)).tag($0) }
                }.labelsHidden().frame(width: 170).accessibilityIdentifier("convert-resize")
            }
        }
        if families.contains(.video) && target.overrides.videoMaxHeight == nil {
            Divider().padding(.leading, 52)
            row(L("En fazla yükseklik"), symbol: "arrow.up.and.down") {
                Picker(L("En fazla yükseklik"), selection: $converter.draftMaxHeight) {
                    ForEach(ConversionOptions.videoHeights, id: \.self) { height in
                        Text(height == 0 ? L("Özgün çözünürlük") : "\(height)p").tag(height)
                    }
                }.labelsHidden().frame(width: 170).accessibilityIdentifier("convert-max-height")
            }
        }
        if families.contains(.video) && target.overrides.removeAudio == nil {
            Divider().padding(.leading, 52)
            row(L("Sesi kaldır"), symbol: "speaker.slash") {
                Toggle(L("Sesi kaldır"), isOn: $converter.draftRemoveAudio).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityIdentifier("convert-remove-audio")
            }
        }
    }

    private func resizeTitle(_ resize: ImageResize) -> String {
        switch resize.mode {
        case .original: L("Özgün boyut")
        case .percent: (Double(resize.value) / 100).formatted(.percent.locale(locale))
        case .longEdge: L("Uzun kenar %@", "\(resize.value) px")
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = L("Dönüştürülecek dosyaları seç"); panel.prompt = L("Seç")
        guard panel.runModal() == .OK else { return }
        converter.add(panel.urls)
    }

    /// Kept in the order they were dropped, which is the merge order, whatever order they load in.
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(), box = DroppedURLs()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.put(url, at: index) }
                group.leave()
            }
        }
        let converter = converter
        group.notify(queue: .main) { MainActor.assumeIsolated { converter.add(box.urls) } }
        return true
    }

    private final class DroppedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: URL] = [:]
        func put(_ url: URL, at index: Int) { lock.lock(); values[index] = url; lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values.keys.sorted().compactMap { values[$0] } }
    }

    // MARK: Recent conversions

    private var recent: some View {
        let running = converter.activities.filter { $0.phase != .finished }
        let records = converter.history
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("SON DÖNÜŞTÜRMELER")).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                if !records.isEmpty {
                    Button(L("Geçmişi temizle")) { converter.clearHistory() }
                        .buttonStyle(.link).font(.system(size: 10)).accessibilityIdentifier("convert-clear-history")
                }
            }
            LazyVStack(spacing: 0) {
                if running.isEmpty && records.isEmpty {
                    Text(L("Henüz dönüştürme yok.")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(22)
                }
                ForEach(running) { activity in
                    if activity.id != running.first?.id { Divider().padding(.leading, 58).opacity(0.5) }
                    activityRow(activity)
                }
                ForEach(records.prefix(historyLimit)) { record in
                    if !running.isEmpty || record.id != records.first?.id { Divider().padding(.leading, 58).opacity(0.5) }
                    recordRow(record)
                }
                if records.count > historyLimit {
                    Divider().opacity(0.5)
                    Button(L("Daha fazla göster (%d öğe daha)", records.count - historyLimit)) { historyLimit += 10 }
                        .buttonStyle(.link).font(.system(size: 11)).padding(13)
                }
            }.background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }

    private func activityRow(_ activity: ConversionActivity) -> some View {
        let target = activity.titleIsKey ? L(activity.targetTitle) : activity.targetTitle
        return HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 18)).foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(verbatim: files(activity.count) + " → " + target).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if activity.origin == .watch { badge(L("İzlenen klasör")) }
                }
                if activity.phase == .waiting {
                    Text(L("Sırada bekliyor")).font(.system(size: 10)).foregroundStyle(.secondary)
                } else if let fraction = activity.fraction {
                    ProgressView(value: min(1, max(0, fraction))).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
            Spacer(minLength: 8)
            iconButton("xmark.circle", L("İptal et")) { converter.cancel(activity.id) }
        }.padding(.horizontal, 17).padding(.vertical, 13)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("convert-activity")
    }

    private func recordRow(_ record: ConversionRecord) -> some View {
        let open = expanded.contains(record.id)
        let detailed = !record.problems.isEmpty || !record.notices.isEmpty
        return HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: record.outputs.first?.path ?? record.sources.first ?? "/"))
                .resizable().interpolation(.high).frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: title(of: record)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .help(record.sources.joined(separator: "\n"))
                    if record.origin == .watch { badge(L("İzlenen klasör")) }
                }
                let summary = Text(verbatim: ([record.date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale))] + counts(of: record))
                    .joined(separator: " · ")).font(.system(size: 10)).monospacedDigit()
                if detailed {
                    Button {
                        if open { expanded.remove(record.id) } else { expanded.insert(record.id) }
                    } label: {
                        HStack(spacing: 5) {
                            summary
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                                .accessibilityHidden(true)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityValue(open ? L("Genişletilmiş") : L("Daraltılmış"))
                } else {
                    summary.foregroundStyle(.secondary)
                }
                if open { problemLines(of: record).padding(.top, 2) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if !record.outputs.isEmpty {
                    iconButton("magnifyingglass.circle", L("Finder’da göster")) {
                        converter.reveal(record.outputs.map { URL(fileURLWithPath: $0.path) })
                    }
                }
                if retryable.contains(record.id) {
                    iconButton("arrow.clockwise.circle", L("Yeniden dene")) { converter.retry(record) }
                        .accessibilityIdentifier("convert-retry")
                }
                if !record.outputs.isEmpty {
                    iconButton("arrow.uturn.backward.circle", L("Geri al")) { confirmUndo(record) }
                        .disabled(!undoable.contains(record.id)).accessibilityIdentifier("convert-undo")
                }
            }.frame(height: 30)
        }.padding(.horizontal, 17).padding(.vertical, 13)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("convert-record")
    }

    /// "foto.heic → PNG" for one file, "3 dosya → PNG" for several.
    private func title(of record: ConversionRecord) -> String {
        let target = record.titleIsKey ? L(record.targetTitle) : record.targetTitle
        let what = record.sources.count == 1 ? (record.sources[0] as NSString).lastPathComponent : files(record.sources.count)
        return what + " → " + target
    }

    private func counts(of record: ConversionRecord) -> [String] {
        var parts: [String] = []
        if record.converted > 0 { parts.append(L("%d dönüştürüldü", record.converted)) }
        if record.failures > 0 { parts.append(L("%d başarısız", record.failures)) }
        if record.skipped > 0 { parts.append(L("%d atlandı", record.skipped)) }
        if record.wasCancelled { parts.append(L("İptal edildi")) }
        return parts
    }

    private func problemLines(of record: ConversionRecord) -> some View {
        let rest = record.failures + record.skipped - record.problems.count
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(record.problems.enumerated()), id: \.offset) { _, problem in
                Text(verbatim: (problem.source as NSString).lastPathComponent + " — "
                     + UserMessage(problem.key, detail: problem.detail).text(using: model.localizer))
                    .foregroundStyle(problem.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rest > 0 { Text(L("%d tane daha", rest)).foregroundStyle(.secondary) }
            ForEach(record.notices, id: \.self) { notice in
                Text(L(notice)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 10)).accessibilityIdentifier("convert-record-problems")
    }

    private func confirmUndo(_ record: ConversionRecord) {
        // What was undoable when the list was drawn may have changed in Finder since.
        let items = record.unchangedOutputs()
        guard !items.isEmpty else { refreshRecords(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Bu dönüştürme geri alınsın mı?")
        var text = items.count == 1 ? L("1 öğe Çöp Sepeti’ne taşınır.") : L("%d öğe Çöp Sepeti’ne taşınır.", items.count)
        if record.originalsTrashed { text += "\n\n" + L("Özgün dosyalar da Çöp Sepeti’nde; oradan geri alabilirsin.") }
        alert.informativeText = text
        alert.addButton(withTitle: L("Vazgeç"))
        alert.addButton(withTitle: L("Geri al")).hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { converter.undo(record) }
    }

    /// Off the main thread: a folder output is compared file by file.
    private func refreshRecords() {
        let records = converter.history
        Task {
            let (undo, retry) = await Task.detached(priority: .utility) {
                (Set(records.filter { !$0.unchangedOutputs().isEmpty }.map(\.id)), Set(records.filter { !$0.retryable().isEmpty }.map(\.id)))
            }.value
            // A newer history has its own refresh on the way.
            guard converter.history.map(\.id) == records.map(\.id) else { return }
            if undo != undoable { undoable = undo }
            if retry != retryable { retryable = retry }
        }
    }

    // MARK: The ring

    private var dragCard: some View {
        let settings = model.preferences.converter
        return card(L("SÜRÜKLERKEN DÖNÜŞTÜR")) {
            row(L("Sürüklerken dönüştür"), L("Dosya sürüklerken tuşa basınca dönüştürme halkası açılır."), symbol: "cursorarrow.motionlines") {
                Toggle(L("Sürüklerken dönüştür"), isOn: binding(\.converter.donutEnabled)).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityIdentifier("convert-donut-enabled")
            }
            Divider().padding(.leading, 52)
            Group {
                row(L("Tuş"), symbol: "keyboard") {
                    Picker(L("Tuş"), selection: binding(\.converter.trigger)) {
                        ForEach(DonutTrigger.allCases, id: \.self) { Text(verbatim: $0.glyph + " " + L($0.titleKey)).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("convert-trigger")
                }
                Divider().padding(.leading, 52)
                row(L("Yalnızca Finder’dan sürüklerken"), L("Kapalıyken her uygulamadan sürüklenen dosyalarda açılır."), symbol: "macwindow") {
                    Toggle(L("Yalnızca Finder’dan sürüklerken"), isOn: binding(\.converter.finderOnly)).toggleStyle(.switch)
                        .controlSize(.small).labelsHidden().accessibilityIdentifier("convert-finder-only")
                }
            }.disabled(!settings.donutEnabled)
            Divider().padding(.leading, 52)
            VStack(alignment: .leading, spacing: 9) {
                step(1, L("Dosyayı sürüklemeye başla, sonra %@ tuşuna bas.", settings.trigger.glyph))
                step(2, L("Açılan halkada bir dilime bırak."))
                step(3, L("Sonuç özgün dosyanın yanına kaydedilir; vazgeçmek için ortaya bırak."))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(17).padding(.leading, 41)
                .opacity(settings.donutEnabled ? 1 : 0.5)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(verbatim: "\(number)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 16, height: 16).background(Palette.accent.opacity(0.10), in: Circle()).accessibilityHidden(true)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Output settings

    private enum Place: Hashable { case beside, subfolder, folder }

    private var place: Place {
        switch options.location {
        case .besideSource: .beside
        case .subfolder: .subfolder
        case .folder: .folder
        }
    }

    private var placeTitle: String {
        switch options.location {
        case .besideSource: L("Özgün dosyanın yanına")
        case .subfolder(let name): L("Yanındaki “%@” klasörüne", name)
        case .folder(let path): (path as NSString).abbreviatingWithTildeInPath
        }
    }

    private var outputCard: some View {
        card(L("ÇIKTI AYARLARI")) {
            Button { showsOutput.toggle() } label: {
                HStack(spacing: 14) {
                    rowIcon("slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Kalite, çözünürlük ve kayıt yeri")).font(.system(size: 12, weight: .medium))
                        Text(verbatim: placeTitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: showsOutput ? "chevron.down" : "chevron.right").frame(width: 12)
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                }.contentShape(Rectangle()).padding(17)
            }.buttonStyle(.plain)
                .accessibilityValue(showsOutput ? L("Genişletilmiş") : L("Daraltılmış"))
                .accessibilityIdentifier("convert-output-settings")
            if showsOutput { outputRows }
        }
    }

    @ViewBuilder private var outputRows: some View {
        Divider()
        row(L("Görüntü kalitesi"), L("Otomatik: her biçim için önerilen değer."), symbol: "photo") {
            Picker(L("Görüntü kalitesi"), selection: binding(\.converter.options.imageQuality)) {
                Text(L("Otomatik")).tag(Double?.none)
                ForEach(qualitySteps, id: \.self) { value in
                    Text(verbatim: value.formatted(.percent.precision(.fractionLength(0)).locale(locale))).tag(Double?.some(value))
                }
            }.labelsHidden().frame(width: 140).accessibilityIdentifier("convert-image-quality")
        }
        Divider().padding(.leading, 52)
        row(L("Meta verileri koru"), L("Tarih, konum ve kamera bilgisi sonuca aktarılır."), symbol: "info.circle") {
            Toggle(L("Meta verileri koru"), isOn: binding(\.converter.options.keepMetadata)).toggleStyle(.switch)
                .controlSize(.small).labelsHidden().accessibilityIdentifier("convert-keep-metadata")
        }
        Divider().padding(.leading, 52)
        row(L("PDF çözünürlüğü"), L("PDF sayfalarından görüntü oluştururken."), symbol: "doc.richtext") {
            Picker(L("PDF çözünürlüğü"), selection: binding(\.converter.options.pdfDPI)) {
                ForEach(steps([72, 150, 300], keeping: options.pdfDPI), id: \.self) { Text(verbatim: "\($0) dpi").tag($0) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("convert-pdf-dpi")
        }
        Divider().padding(.leading, 52)
        row(L("PDF sıkıştırma"), L("Sıkıştır aracı PDF’lerde bu düzeyi kullanır."), symbol: "rectangle.compress.vertical") {
            Picker(L("PDF sıkıştırma"), selection: binding(\.converter.options.pdfCompression)) {
                ForEach(CompressionLevel.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("convert-pdf-compression")
        }
        Divider().padding(.leading, 52)
        row(L("Kağıt boyutu"), L("Belgeden ve görüntüden PDF oluştururken."), symbol: "doc") {
            Picker(L("Kağıt boyutu"), selection: binding(\.converter.options.paper)) {
                ForEach(PaperSize.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("convert-paper")
        }
        Divider().padding(.leading, 52)
        row(L("Video kalitesi"), symbol: "film") {
            Picker(L("Video kalitesi"), selection: binding(\.converter.options.videoQuality)) {
                ForEach(ConversionQuality.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("convert-video-quality")
        }
        Divider().padding(.leading, 52)
        row(L("Video kodeği"), L("HEVC daha küçük dosya verir; eski cihazlarda açılmayabilir."), symbol: "film.stack") {
            Picker(L("Video kodeği"), selection: binding(\.converter.options.videoCodec)) {
                ForEach(ConversionVideoCodec.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("convert-video-codec")
        }
        Divider().padding(.leading, 52)
        row(L("Ses bit hızı"), symbol: "music.note") {
            Picker(L("Ses bit hızı"), selection: binding(\.converter.options.audioBitrate)) {
                ForEach(steps([64, 96, 128, 160, 192, 256, 320], keeping: options.audioBitrate), id: \.self) { Text(verbatim: "\($0) kbps").tag($0) }
            }.labelsHidden().frame(width: 140).accessibilityIdentifier("convert-audio-bitrate")
        }
        Divider().padding(.leading, 52)
        locationRow
        Divider().padding(.leading, 52)
        row(L("Biçim dönüştürmelerinden sonra özgün dosyayı Çöp Sepeti’ne taşı"),
            L("Araçlar ve başka türe dönüştürmeler özgün dosyaya dokunmaz."), symbol: "trash") {
            Toggle(L("Biçim dönüştürmelerinden sonra özgün dosyayı Çöp Sepeti’ne taşı"), isOn: binding(\.converter.options.trashOriginals))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityIdentifier("convert-trash-originals")
        }
    }

    private var locationRow: some View {
        let subfolder: String = if case .subfolder(let name) = options.location { name } else { L("Dönüştürülenler") }
        let folder: String? = if case .folder(let path) = options.location { path } else { nil }
        return HStack(spacing: 14) {
            rowIcon("folder")
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Kayıt klasörü")).font(.system(size: 12, weight: .medium))
                if let folder {
                    Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(folder)
                }
            }
            Spacer()
            if folder != nil {
                Button(L("Değiştir…")) { chooseOutputFolder() }.controlSize(.small).accessibilityIdentifier("convert-output-folder")
            }
            Picker(L("Kayıt klasörü"), selection: Binding(get: { place }, set: { choose($0) })) {
                Text(L("Özgün dosyanın yanına")).tag(Place.beside)
                Text(L("Yanındaki “%@” klasörüne", subfolder)).tag(Place.subfolder)
                Text(L("Seçtiğin klasöre")).tag(Place.folder)
            }.labelsHidden().frame(width: 230).accessibilityIdentifier("convert-location")
        }.padding(17)
    }

    private func choose(_ choice: Place) {
        guard choice != place else { return }
        switch choice {
        case .beside: model.update { $0.converter.options.location = .besideSource }
        // The name is fixed in the current language now: a later language change must not split results.
        case .subfolder: model.update { $0.converter.options.location = .subfolder(L("Dönüştürülenler")) }
        // A modal panel cannot open in the middle of the picker's own update.
        case .folder: DispatchQueue.main.async { chooseOutputFolder() }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        if case .folder(let path) = options.location { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.title = L("Sonuçların kaydedileceği klasörü seç"); panel.prompt = L("Seç")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update { $0.converter.options.location = .folder(url.path) }
    }

    /// 100 % down to 10 %, and a stored value between them (from an imported file) as it is.
    private var qualitySteps: [Double] {
        var values = stride(from: 100, through: 10, by: -10).map { Double($0) / 100 }
        if let current = options.imageQuality, !values.contains(current) { values.append(current); values.sort(by: >) }
        return values
    }

    private func steps(_ values: [Int], keeping current: Int) -> [Int] {
        values.contains(current) ? values : (values + [current]).sorted()
    }

    // MARK: Pieces

    private func row<Control: View>(_ title: String, _ subtitle: String? = nil, symbol: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            rowIcon(symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control()
        }.padding(17)
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.accent)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.accent.opacity(0.10), in: Capsule())
    }
    private func binding<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { model.preferences[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }
    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Palette.accent).frame(width: 27, height: 27)
    }
    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }
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

extension ConvertView where WatchFolders == EmptyView {
    /// The page without the watched-folders card.
    init(model: AppModel, converter: ConverterManager) {
        self.init(model: model, converter: converter) { EmptyView() }
    }
}
