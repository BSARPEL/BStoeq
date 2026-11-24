import AppKit
import SwiftUI
import BStoeqCore
import ConvertCore

/// The converter page's card of watched folders: every new file that lands in one is converted to the
/// rule's format, into a results folder inside it.
struct WatchFoldersView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var watch: WatchFolderManager
    @ObservedObject var converter: ConverterManager
    /// A folder chosen with "Klasör ekle…" that still waits for its format.
    @State private var picked: String?
    /// The formats offered for it, worked out once when it was chosen, not on every redraw.
    @State private var choices: [[Choice]] = []
    @State private var problem: String?

    init(model: AppModel, watch: WatchFolderManager, converter: ConverterManager) {
        self.model = model; self.watch = watch; self.converter = converter
    }

    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    private func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    private var rules: [WatchRule] { model.preferences.converter.watch }

    var body: some View {
        card(L("İZLENEN KLASÖRLER")) {
            if rules.isEmpty && picked == nil {
                Text(L("Bir klasör eklersen içine gelen her yeni dosya seçtiğin biçime dönüştürülür. Klasörde zaten olan dosyalara dokunulmaz."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(17)
                Divider().padding(.leading, 17)
            }
            ForEach(rules) { rule in
                row(rule)
                Divider().padding(.leading, 58)
            }
            if let picked { pickedRow(picked); Divider().padding(.leading, 58) }
            footer
        }
    }

    // MARK: Rows

    private func row(_ rule: WatchRule) -> some View {
        let reason = rule.enabled ? watch.states[rule.id].flatMap(reason) : nil
        return HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.folder)).resizable().interpolation(.high)
                .frame(width: 27, height: 27).opacity(rule.enabled ? 1 : 0.5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: short(rule.folder)).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(rule.folder)
                Text(verbatim: "→ " + title(of: rule.targetID)).font(.system(size: 10)).foregroundStyle(.secondary)
                if let reason {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("convert-watch-reason-\(rule.id.uuidString)")
                }
            }
            Spacer(minLength: 8)
            Toggle(short(rule.folder), isOn: Binding(get: { rule.enabled }, set: { value in edit(rule.id) { $0.enabled = value } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("convert-watch-toggle-\(rule.id.uuidString)")
            Button { remove(rule.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Kaldır")).accessibilityLabel(L("Kaldır"))
                .accessibilityIdentifier("convert-watch-remove-\(rule.id.uuidString)")
        }.padding(.horizontal, 17).padding(.vertical, 12)
            .contextMenu {
                Button(L("Finder’da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rule.folder)]) }
            }
    }

    private func pickedRow(_ folder: String) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder)).resizable().interpolation(.high)
                .frame(width: 27, height: 27).accessibilityHidden(true)
            Text(verbatim: short(folder)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Menu(L("Biçim seç")) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.target.id) { choice in
                        Button(choice.title) { add(folder, target: choice.target) }
                    }
                }
            }.fixedSize().controlSize(.small).accessibilityIdentifier("convert-watch-target")
            Button(L("İptal et")) { picked = nil; choices = [] }.controlSize(.small)
                .accessibilityIdentifier("convert-watch-cancel")
        }.padding(.horizontal, 17).padding(.vertical, 12)
    }

    private var footer: some View {
        let full = rules.count >= ConverterSettings.watchLimit
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Sonuçlar klasörün içindeki “%@” klasörüne kaydedilir.", resultsFolder))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("convert-watch-problem")
                }
            }
            Spacer(minLength: 8)
            Button(L("Klasör ekle…")) { chooseFolder() }.controlSize(.small).disabled(full || picked != nil)
                .help(full ? L("En fazla %d klasör izlenebilir.", ConverterSettings.watchLimit) : "")
                .accessibilityIdentifier("convert-watch-add")
        }.padding(.horizontal, 17).padding(.vertical, 12)
    }

    // MARK: Words

    /// Rules made in another language keep their own name; only when they all share one is it the right one to show.
    private var resultsFolder: String {
        let names = Set(rules.map(\.outputFolder))
        return names.count == 1 ? names.first ?? L("Dönüştürülenler") : L("Dönüştürülenler")
    }

    private func reason(_ state: WatchFolderManager.State) -> String? {
        switch state {
        case .watching: nil
        case .folderMissing: L("Klasör bulunamadı.")
        case .unavailable(let tool?): L("Bu dönüştürme için %@ gerekli.", tool)
        case .unavailable(nil): L("Bu dönüştürme bu Mac’te yapılamıyor.")
        }
    }

    private func title(of targetID: String) -> String {
        guard let target = TargetCatalog.target(id: targetID) else { return targetID.uppercased() }
        return target.titleIsKey ? L(target.title) : target.title
    }

    /// One entry of the format menu. A format that needs a missing tool can still be chosen: its row then
    /// says what to install.
    private struct Choice {
        let target: ConversionTarget
        let title: String
    }

    // MARK: Changes

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = L("İzlenecek klasörü seç"); panel.prompt = L("Seç")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard !rules.contains(where: { URL(fileURLWithPath: $0.folder).standardizedFileURL.path == path }) else {
            problem = L("Bu klasör zaten izleniyor.")
            return
        }
        problem = nil
        // The formats a watched file can become here: plain conversions, grouped by what they make.
        let engine = converter.engine
        var groups: [FileFamily: [Choice]] = [:], order: [FileFamily] = []
        for target in TargetCatalog.all where target.kind == .convert {
            let availability = engine.availability(of: target)
            guard availability != .unsupported else { continue }
            let family = FormatRegistry.format(id: target.format)?.family ?? .other
            if groups[family] == nil { order.append(family) }
            var title = target.titleIsKey ? L(target.title) : target.title
            if case .needs(let tool) = availability { title += " (\(tool))" }
            groups[family, default: []].append(Choice(target: target, title: title))
        }
        choices = order.compactMap { groups[$0] }
        picked = path
    }

    private func add(_ folder: String, target: ConversionTarget) {
        // Fixed now, in the language of the moment, so a later language change does not split the results.
        let rule = WatchRule(folder: folder, targetID: target.id, outputFolder: L("Dönüştürülenler"))
        model.update { $0.converter.watch.append(rule) }
        picked = nil; choices = []
        if !rules.contains(where: { $0.id == rule.id }) { problem = L("Bu klasör zaten izleniyor.") }
        watch.apply(rules)
    }

    private func edit(_ id: UUID, _ change: (inout WatchRule) -> Void) {
        model.update { preferences in
            if let index = preferences.converter.watch.firstIndex(where: { $0.id == id }) { change(&preferences.converter.watch[index]) }
        }
        watch.apply(rules)
    }

    private func remove(_ id: UUID) {
        model.update { $0.converter.watch.removeAll { $0.id == id } }
        watch.apply(rules)
    }

    // MARK: Pieces

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }
}
