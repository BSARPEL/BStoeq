import Foundation
import CoreGraphics

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
