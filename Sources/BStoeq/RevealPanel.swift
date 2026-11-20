import AppKit
import SwiftUI
import BStoeqCore

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class RevealPanelController: NSObject {
    private var panel: NSPanel?
    private var mode: RevealMode?
    private var anchor: NSPoint?
    private var screenObserver: NSObjectProtocol?
    var onDismiss: (() -> Void)?

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Without an open panel there is nothing to reposition; dismissing anyway
                // would silently end "show all" whenever a display changes.
                MainActor.assumeIsolated { if self?.panel != nil { self?.onDismiss?() } }
            }
    }
    var containsPointer: Bool { panel?.isVisible == true && panel?.frame.contains(NSEvent.mouseLocation) == true }
    func contains(_ event: NSEvent) -> Bool { panel?.isVisible == true && event.window === panel }

    func rememberAnchor(_ point: NSPoint) { anchor = point }

    func sync(model: AppModel) {
        guard model.panelPresented else { close(); return }
        if mode != model.preferences.revealMode { close() }
        let pointer = NSEvent.mouseLocation
        let screen = panel?.screen ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let isBar = model.preferences.revealMode == .bar
        let count = model.panelApps.count
        let barWidth = min(420, max(260, CGFloat(count) * 36 + CGFloat(max(0, count - 1)) * 4 + 20))
        let barHeight: CGFloat = (count == 0 ? 132 : 92) + (model.trusted ? 0 : 28)
        let size = NSSize(width: isBar ? barWidth : 320, height: isBar ? barHeight : 340)
        let x = anchor.flatMap { screen.frame.contains($0) ? $0.x : nil } ?? panel?.frame.midX ?? screen.visibleFrame.maxX - size.width / 2 - 12
        let rect = PanelPlacement.frame(size: size, visibleFrame: screen.visibleFrame, anchorX: x,
            top: screen.frame.maxY - max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) - 8)
        if let panel {
            // Resize in place so lifecycle updates preserve list search and keyboard focus.
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            return
        }
        let window = BarPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = model.L(isBar ? "BStoeq alt çubuğu" : "BStoeq hızlı menüsü")
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: RevealPanelView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity))
        // A SwiftUI scroll view has an unbounded ideal height. Do not let its
        // intrinsic size expand this small floating panel into a full-height window.
        content.sizingOptions = []
        content.frame = NSRect(origin: .zero, size: rect.size)
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        panel = window; mode = model.preferences.revealMode
        window.setFrame(rect, display: true)
        // Hovering is not a request for keyboard focus. A click inside still makes
        // the panel key, so search remains one click away.
        if model.revealedByHover { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }
    }
    func close() {
        panel?.orderOut(nil); panel = nil; mode = nil
    }
    func stop() {
        close()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}

private struct RevealPanelView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var isBar: Bool { model.preferences.revealMode == .bar }
    private func L(_ key: String) -> String { model.L(key) }
    private var apps: [BarApp] {
        model.panelApps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: isBar ? 8 : 10) {
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(Palette.accent)
                Text(L("Gizli uygulamalar")).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("\(model.panelApps.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if isBar {
                    Button { model.revealEverything() } label: { Image(systemName: "eye") }
                        .help(L("Tümünü göster")).accessibilityLabel(L("Tümünü göster"))
                }
                Button { model.hide(); model.selection = "behavior"; model.openWindow?() } label: { Image(systemName: "slider.horizontal.3") }
                    .help(L("Açılma biçimi")).accessibilityLabel(L("Açılma biçimi"))
                Button { model.hide() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(L("Kapat"))
            }.font(.system(size: 11)).buttonStyle(.plain)
            if !isBar {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Uygulama ara…"), text: $search)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityIdentifier("panel-search")
                        .onSubmit { if let app = apps.first { model.selectPanelApp(app) } }
                }.font(.system(size: 12)).padding(9)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            if apps.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 23)).foregroundStyle(Palette.accent)
                    Text(L(search.isEmpty ? "Çalışan gizli uygulama yok" : "Bu görünümde uygulama yok")).font(.system(size: 12, weight: .medium))
                    if search.isEmpty {
                        Button(L("Uygulamaları düzenle")) { model.hide(); model.selection = "menu"; model.openWindow?() }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isBar {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) { ForEach(apps) { app in appButton(app) } }.padding(.vertical, 2)
                }.scrollIndicators(.visible).frame(height: 44)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) { ForEach(apps) { app in appButton(app) } }
                }.frame(maxHeight: .infinity)
            }
            if !isBar {
                Divider()
                HStack(alignment: .center, spacing: 8) {
                    Text(L(model.trusted ? "Sol tık: aç · Sağ tık: uygulamanın seçenekleri" : "Uygulama menülerini açmak için Erişilebilirlik izni gerekir."))
                        .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("Tümünü göster")) { model.revealEverything() }.controlSize(.small)
                }
            }
            if !model.trusted {
                Button(L("Menüleri doğrudan açmak için izin ver")) { model.hide(); model.requestAccessibility() }
                    .font(.system(size: 10)).buttonStyle(.link)
            }
        }.padding(isBar ? 10 : 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.09)))
            .tint(Palette.accent)
            .preferredColorScheme(model.preferences.appearance == "dark" ? .dark : model.preferences.appearance == "light" ? .light : nil)
            .environment(\.locale, Locale(identifier: model.localizer.language.rawValue))
            .onAppear { if !isBar { searchFocused = true } }
            .onExitCommand { model.hide() }
    }

    private func appButton(_ app: BarApp) -> some View {
        Button { model.selectPanelApp(app) } label: {
            Group {
                if isBar {
                    icon(app, size: 24).frame(width: 36, height: 36)
                } else {
                    HStack(spacing: 9) {
                        icon(app, size: 22)
                        Text(app.name).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }.contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(PanelItemStyle())
            .background(SecondaryClickCapture {
                model.selectPanelApp(app, action: .contextMenu)
            })
            .accessibilityLabel(app.name)
            .accessibilityHint(L("Sol tık: aç · Sağ tık: uygulamanın seçenekleri"))
            .accessibilityAction(named: Text(L("Sağ tık menüsünü aç"))) {
                model.selectPanelApp(app, action: .contextMenu)
            }
            .help(app.name)
    }
    private func icon(_ app: BarApp, size: CGFloat) -> some View {
        Group {
            if let icon = app.icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app.dashed").resizable() }
        }.frame(width: size, height: size)
    }
}

private struct PanelItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoveredPanelItem(configuration: configuration)
    }
    private struct HoveredPanelItem: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(Palette.accent.opacity(configuration.isPressed ? 0.22 : hovered ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                .onHover { hovered = $0 }
        }
    }
}
