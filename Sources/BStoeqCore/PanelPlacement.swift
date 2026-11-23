import Foundation
import CoreGraphics

public enum ScreenGeometry {
    /// Cocoa coordinates. A pointer on the top row of a screen is reported at
    /// `frame.maxY`, which `CGRect.contains` leaves out, so a pointer pushed against
    /// the top of the menu bar would belong to no screen. Same rule as `NSMouseInRect`.
    public static func contains(_ frame: CGRect, pointer: CGPoint) -> Bool {
        pointer.x >= frame.minX && pointer.x < frame.maxX && pointer.y > frame.minY && pointer.y <= frame.maxY
    }

    /// The pointer is on this screen and inside its menu bar.
    public static func isInMenuBar(_ pointer: CGPoint, frame: CGRect, topInset: CGFloat) -> Bool {
        contains(frame, pointer: pointer) && pointer.y >= frame.maxY - max(28, topInset)
    }
}

public enum PanelPlacement {
    /// Cocoa coordinates. Keep the entire panel inside the selected screen's work area,
    /// including negative origins for secondary displays and narrow scaled displays.
    public static func frame(size: CGSize, visibleFrame: CGRect, anchorX: CGFloat, top: CGFloat) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(size.width, max(1, bounds.width))
        let height = min(size.height, max(1, bounds.height))
        return CGRect(x: min(max(anchorX - width / 2, bounds.minX), bounds.maxX - width),
                      y: min(max(top - height, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }
}
