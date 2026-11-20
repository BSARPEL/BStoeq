import AppKit
import SwiftUI

/// Observe secondary clicks only inside this tile, leaving normal SwiftUI button
/// activation, scrolling, drag tracking and keyboard accessibility intact.
struct SecondaryClickCapture: NSViewRepresentable {
    var enabled: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) {
        view.enabled = enabled; view.action = action
    }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.stop() }

    final class CaptureView: NSView {
        var enabled = true
        var action: (() -> Void)?
        private var monitor: Any?
        private var secondaryDown = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self, self.enabled, let window = self.window, event.window === window else { return event }
                let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                    self.secondaryDown = inside
                    return inside ? nil : event
                }
                if self.secondaryDown && (event.type == .rightMouseUp || event.type == .leftMouseUp) {
                    self.secondaryDown = false
                    if inside { self.action?() }
                    return nil
                }
                return event
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; secondaryDown = false
        }
    }
}
