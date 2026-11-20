import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BStoeqCore

/// The strip mirrors accessibility frames from the real menu bar. Its order is
/// never changed optimistically: the controller refreshes it after macOS moves.
struct MenuBarEditorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: MenuBarLayoutController
    @State private var dropTarget: String?

    private let dragPrefix = "barlet-menu-layout:"
    private var busy: Bool { layout.moving || layout.refreshing }
    private var screenIndices: [Int] { Array(Set(layout.items.map(\.screenIndex))).sorted() }
    private func L(_ key: String, _ arguments: CVarArg...) -> String {
        model.localizer.text(key, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.trusted {
                permissionNotice
            } else if layout.items.isEmpty {
                HStack(spacing: 9) {
                    if layout.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "menubar.rectangle").foregroundStyle(.secondary) }
                    Text(L(layout.refreshing ? "Menü çubuğu okunuyor…" : "Görünür menü çubuğu simgesi bulunamadı. Yenilemeyi deneyebilirsin."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(screenIndices, id: \.self) { screen in
                        screenRow(screen)
                    }
                }
            }
            // Without the permission the notice above already says what is missing.
            if model.trusted, let error = layout.error {
                Label(error.text(using: model.localizer), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menu-layout-error")
            }
            instructions
        }
        .padding(18)
        .background(LinearGradient(colors: [Palette.accent.opacity(0.07), Palette.accent.opacity(0.025)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(0.13)))
        .onAppear { layout.start() }
        .onDisappear {
            if model.inlineMenuBarArrangement { model.finishMenuBarArrangement() }
            layout.stop()
        }
        .onChange(of: model.arrangingMenuBar) { _, _ in
            dropTarget = nil
            refreshAfterLayoutChange()
        }
        .onChange(of: model.preferences.assignments) { _, _ in refreshAfterLayoutChange() }
        .onChange(of: model.trusted) { _, _ in layout.refresh() }
    }

    private func refreshAfterLayoutChange() {
        layout.refresh()
        let arranging = model.arrangingMenuBar
        // Menu-bar leases change asynchronously. Read again after both revealing
        // and hiding so icons do not linger after Done or a visibility choice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard model.arrangingMenuBar == arranging else { return }
            layout.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label(L("MENÜ ÇUBUĞUN"), systemImage: "menubar.rectangle")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(Palette.accent)
                Text(L(model.arrangingMenuBar ? "Düzenleme açık · gizleme duraklatıldı" : "Üst çubuğun gerçek sırası"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L(layout.moving ? "Sıra güncelleniyor…" : "Menü çubuğu okunuyor…"))
            } else {
                Button { layout.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Menü çubuğunu yenile"))
                    .accessibilityLabel(L("Menü çubuğunu yenile"))
                    .accessibilityIdentifier("menu-layout-refresh")
            }
            Button {
                if model.arrangingMenuBar { model.finishMenuBarArrangement() }
                else { model.beginMenuBarArrangement(showGuide: false) }
            } label: {
                Label(L(model.arrangingMenuBar ? "Bitti" : "Düzenle"),
                      systemImage: model.arrangingMenuBar ? "checkmark" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(layout.moving)
                .accessibilityIdentifier("menu-bar-arrangement")
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised").foregroundStyle(Palette.accent)
            Text(L("Simgeleri burada göstermek ve taşımak için Erişilebilirlik izni gerekiyor."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("İzin ver")) { model.requestAccessibility() }.controlSize(.small)
        }.padding(.vertical, 7)
    }

    private func screenItems(_ screen: Int) -> [MenuBarLayoutItem] {
        layout.items.filter { $0.screenIndex == screen }.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func screenRow(_ screen: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if screenIndices.count > 1 {
                Label(L("Ekran %d", screen + 1), systemImage: "display")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(screenItems(screen)) { item in
                        itemTarget(item)
                    }
                }.padding(.horizontal, 10).padding(.vertical, 9)
            }
            .scrollIndicators(.visible)
            .frame(height: 58)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line))
        }
    }

    @ViewBuilder
    private func itemTarget(_ item: MenuBarLayoutItem) -> some View {
        if model.arrangingMenuBar && model.trusted && !layout.moving {
            draggableItem(item)
                .onDrop(of: [UTType.text], isTargeted: Binding(
                    get: { dropTarget == item.id },
                    set: { targeted in
                        if targeted { dropTarget = item.id }
                        else if dropTarget == item.id { dropTarget = nil }
                    }
                )) { providers, location in
                    acceptDrop(providers, on: item, after: location.x >= 18)
                }
        } else {
            itemControl(item)
        }
    }

    @ViewBuilder
    private func draggableItem(_ item: MenuBarLayoutItem) -> some View {
        if item.movable {
            itemControl(item).onDrag {
                NSItemProvider(object: (dragPrefix + item.id) as NSString)
            }
        } else {
            itemControl(item)
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider], on target: MenuBarLayoutItem, after: Bool) -> Bool {
        dropTarget = nil
        guard model.arrangingMenuBar, model.trusted, !layout.moving,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? String, value.hasPrefix(dragPrefix) else { return }
            let sourceID = String(value.dropFirst(dragPrefix.count))
            DispatchQueue.main.async {
                dropTarget = nil
                guard model.arrangingMenuBar, model.trusted, !layout.moving, sourceID != target.id,
                      let source = layout.items.first(where: { $0.id == sourceID }),
                      source.movable, source.screenIndex == target.screenIndex else { return }
                if after { layout.moveAfter(sourceID, targetID: target.id) }
                else { layout.move(sourceID, before: target.id) }
            }
        }
        return true
    }

    private func itemControl(_ item: MenuBarLayoutItem) -> some View {
        Group {
            if let kind = settingsKind(item) {
                Button { openSettings(kind) } label: { itemImage(item) }
                    .buttonStyle(.plain)
            } else {
                Menu { actions(for: item) } label: { itemImage(item) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .frame(width: 36, height: 36)
        .background(dropTarget == item.id ? Palette.accent.opacity(0.19) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(dropTarget == item.id ? Palette.accent : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .contextMenu { actions(for: item) }
        .help(itemHelp(item))
        .accessibilityLabel(L(item.name))
        .accessibilityValue(accessibilityState(item))
        .accessibilityIdentifier("menu-layout-item-\(item.id)")
        .disabled(layout.moving)
    }

    private func itemImage(_ item: MenuBarLayoutItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if item.bundleID == AppModel.bundleID {
                    Image(systemName: model.preferences.icon).font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Palette.accent)
                } else if let symbol = systemSymbol(item) {
                    Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.primary)
                } else if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 23, height: 23)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 21)).foregroundStyle(.secondary)
                }
            }.frame(width: 32, height: 32)
            if let app = editableApp(item), model.visibility(app.id) != .visible {
                Image(systemName: model.visibility(app.id).symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(3).background(Palette.card, in: Circle())
            }
        }.frame(width: 36, height: 36)
    }

    @ViewBuilder
    private func actions(for item: MenuBarLayoutItem) -> some View {
        Text(L(item.name))
        if let app = editableApp(item) {
            Divider()
            ForEach(ItemVisibility.allCases, id: \.self) { visibility in
                Button { model.assign(app.id, to: visibility) } label: {
                    Label(L(visibility.title), systemImage: model.visibility(app.id) == visibility ? "checkmark" : visibility.symbol)
                }
            }
        }
        if item.bundleID == AppModel.bundleID {
            Menu(L("Menü çubuğu simgesi")) {
                ForEach(Preferences.icons, id: \.self) { icon in
                    Button { model.update { $0.icon = icon } } label: {
                        Label(L(Preferences.iconNames[icon] ?? icon), systemImage: icon)
                    }
                }
            }
        }
        if let kind = settingsKind(item) {
            Button(L("Sistem ayarlarını aç…")) { openSettings(kind) }
        }
        Divider()
        if model.arrangingMenuBar {
            Button { moveOne(item, direction: -1) } label: {
                Label(L("Sola taşı"), systemImage: "arrow.left")
            }.disabled(!canMove(item, direction: -1))
            Button { moveOne(item, direction: 1) } label: {
                Label(L("Sağa taşı"), systemImage: "arrow.right")
            }.disabled(!canMove(item, direction: 1))
        } else {
            Button(L("Düzenlemeyi başlat")) { model.beginMenuBarArrangement(showGuide: false) }
        }
        if !item.movable { Text(L("Bu simgenin konumunu macOS yönetir.")) }
    }

    private func editableApp(_ item: MenuBarLayoutItem) -> BarApp? {
        model.apps.first { $0.id == item.bundleID && !$0.protected && $0.running }
    }

    private func neighbor(_ item: MenuBarLayoutItem, direction: Int) -> MenuBarLayoutItem? {
        let row = screenItems(item.screenIndex)
        guard let index = row.firstIndex(where: { $0.id == item.id }), row.indices.contains(index + direction) else { return nil }
        return row[index + direction]
    }

    private func canMove(_ item: MenuBarLayoutItem, direction: Int) -> Bool {
        model.arrangingMenuBar && model.trusted && !layout.moving && item.movable && neighbor(item, direction: direction) != nil
    }

    private func moveOne(_ item: MenuBarLayoutItem, direction: Int) {
        guard canMove(item, direction: direction), let target = neighbor(item, direction: direction) else { return }
        if direction < 0 { layout.move(item.id, before: target.id) }
        else { layout.moveAfter(item.id, targetID: target.id) }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: model.arrangingMenuBar ? "cursorarrow.motionlines" : "cursorarrow.click")
                    .foregroundStyle(Palette.accent)
                Text(L(model.arrangingMenuBar
                       ? "Sıralamak için sürükle; gizlemek için simgeye tıkla veya sağ tıkla. Bitti’ye basınca gizleme geri açılır."
                       : "Düzenle ile tüm simgeleri aç ve sırala. Gizlemek için simgeye tıkla veya sağ tıkla."))
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Text(L("Wi-Fi, pil ve saat simgeleri kendi macOS ayarlarını açar."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    if model.arrangingMenuBar { model.finishMenuBarArrangement() }
                    model.beginMenuBarArrangement()
                } label: {
                    Label(L("⌘ sürükleme rehberi"), systemImage: "arrow.up.right")
                        .font(.system(size: 10))
                }.buttonStyle(.link).disabled(layout.moving)
                    .accessibilityIdentifier("menu-layout-native-guide")
            }
        }
    }

    private func itemHelp(_ item: MenuBarLayoutItem) -> String {
        if let app = editableApp(item) { return "\(L(item.name)) · \(L(model.visibility(app.id).title))" }
        return L(item.name)
    }

    private func accessibilityState(_ item: MenuBarLayoutItem) -> String {
        if let app = editableApp(item) { return L(model.visibility(app.id).title) }
        return item.movable ? "" : L("Sistem yönetir")
    }

    private func settingsKind(_ item: MenuBarLayoutItem) -> SystemMenuSettings.Kind? {
        SystemMenuSettings.kind(identifier: item.systemIdentifier, name: item.name, bundleID: item.bundleID)
    }

    private func systemSymbol(_ item: MenuBarLayoutItem) -> String? {
        switch settingsKind(item) {
        case .wifi: return "wifi"
        case .battery: return "battery.100percent"
        case .clock: return "clock"
        case nil:
            guard item.bundleID.hasPrefix("com.apple.") else { return nil }
            let identifier = (item.systemIdentifier ?? "").lowercased()
            if identifier.contains("controlcenter") { return "switch.2" }
            if identifier.contains("spotlight") { return "magnifyingglass" }
            if identifier.contains("bluetooth") { return "antenna.radiowaves.left.and.right" }
            if identifier.contains("volume") || identifier.contains("sound") { return "speaker.wave.2" }
            if identifier.contains("focus") || identifier.contains("donotdisturb") { return "moon" }
            return "menubar.rectangle"
        }
    }

    private func openSettings(_ kind: SystemMenuSettings.Kind) {
        guard SystemMenuSettings.open(kind) else {
            model.error = UserMessage("Sistem Ayarları açılamadı. Uygulamalar klasöründen açıp Menü Çubuğu bölümüne gidebilirsin.")
            return
        }
    }
}
