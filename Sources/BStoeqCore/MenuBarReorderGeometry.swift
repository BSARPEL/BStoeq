import CoreGraphics

public enum MenuBarReorderGeometry {
    /// Keep every synthetic drag in the source menu bar. A vertical drag can
    /// remove a system item instead of changing its order.
    public static func destination(source: CGRect, target: CGRect, screen: CGRect, before: Bool) -> CGPoint? {
        guard MenuTargetGeometry.isOnMenuBar(source, screens: [screen]),
              MenuTargetGeometry.isOnMenuBar(target, screens: [screen]),
              source.width >= 4, target.width >= 4,
              abs(source.midY - target.midY) <= 20 else { return nil }
        let x = before ? target.minX + 1 : target.maxX - 1
        guard x.isFinite, screen.minX < x, x < screen.maxX else { return nil }
        return CGPoint(x: x, y: source.midY)
    }

    public static func areAdjacent(sourceID: String, targetID: String, order: [String], before: Bool) -> Bool {
        guard sourceID != targetID, let source = order.firstIndex(of: sourceID),
              let target = order.firstIndex(of: targetID) else { return false }
        return before ? source + 1 == target : source == target + 1
    }

    public static func hasRequestedOrder(source: CGRect, target: CGRect, before: Bool) -> Bool {
        before ? source.maxX <= target.minX + 1 : source.minX >= target.maxX - 1
    }
}
