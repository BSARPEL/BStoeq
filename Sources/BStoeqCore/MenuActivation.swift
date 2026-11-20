import Foundation
import CoreGraphics

public enum MenuActivation: Equatable, Sendable {
    case primary, contextMenu

    /// Right-click must never silently become a left-click; apps can attach
    /// entirely different actions to those gestures.
    public var accessibilityAction: String {
        self == .contextMenu ? "AXShowMenu" : "AXPress"
    }

    public func supports(_ actions: [String]) -> Bool { actions.contains(accessibilityAction) }
}

public enum MenuTargetGeometry {
    /// Accessibility coordinates: screen origins are at the top-left. Reject
    /// offscreen, missing and non-menu targets before forwarding a mouse click.
    public static func isOnMenuBar(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, frame.height <= 80 else { return false }
        return screens.contains { screen in
            screen.contains(frame) && frame.minY >= screen.minY && frame.maxY <= screen.minY + 80
        }
    }
}
