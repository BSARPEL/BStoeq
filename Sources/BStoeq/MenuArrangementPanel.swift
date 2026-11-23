import AppKit
import SwiftUI

private final class ArrangementPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A guide for macOS's native Command-drag gesture. It never moves other apps' windows.
@MainActor final class MenuArrangementPanelController {
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?

    func show(model: AppModel) {
        guard model.arrangingMenuBar else { return }
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = ArrangementPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = model.L("Menü çubuğunu düzenle")
        panel.identifier = NSUserInterfaceItemIdentifier("Barlet.MenuArrangement")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        let view = NSHostingView(rootView: MenuArrangementGuide(model: model))
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.panel = panel
        positionPanel(on: NSScreen.containing(NSEvent.mouseLocation))
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionPanel() }
            }
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionPanel(on preferredScreen: NSScreen? = nil) {
        guard let panel, let screen = preferredScreen ?? panel.screen ?? NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main else { return }
        let usable = screen.visibleFrame
        let width = min(484, max(300, usable.width - 32))
        // Keep the guide away from the actual menu-bar drag targets.
        let frame = NSRect(x: usable.midX - width / 2, y: usable.minY + 28, width: width, height: 282)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    func close() {
        panel?.orderOut(nil); panel = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}

private struct MenuArrangementGuide: View {
    @ObservedObject var model: AppModel
    private func L(_ key: String) -> String { model.L(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.left.and.right").foregroundStyle(Palette.accent)
                Text(L("Menü çubuğunu düzenle")).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("⌘").font(.system(size: 21, weight: .medium)).foregroundStyle(Palette.accent)
            }
            Text(L("⌘ tuşunu basılı tutup üst çubuktaki simgeleri sağa veya sola sürükle."))
                .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(L("BStoeq simgesini istediğin konuma sürükleyebilirsin."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("Düzenleme sırasında gizleme duraklatılır. Bitti’ye basınca önceki görünürlük düzenin geri gelir."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 12) {
                Text(L("Bazı macOS simgelerinin konumu sabittir."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L("Bitti")) { model.finishMenuBarArrangement() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("menu-arrangement-done")
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.line))
        .tint(Palette.accent)
        .environment(\.locale, Locale(identifier: model.localizer.language.rawValue))
    }
}
