import AppKit
let destination = CommandLine.arguments[1] + "/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let s = CGFloat(pixels)
        let rect = NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
        let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
        NSGradient(starting: NSColor(red: 0.42, green: 0.31, blue: 0.8, alpha: 1), ending: NSColor(red: 0.66, green: 0.52, blue: 1, alpha: 1))!.draw(in: path, angle: 75)
        for (index, height) in [0.31, 0.50, 0.23].enumerated() {
            NSColor.white.withAlphaComponent(index == 2 ? 0.6 : 1).setFill()
            let w = s * 0.1, h = s * height
            NSBezierPath(roundedRect: NSRect(x: s * (0.29 + Double(index) * 0.16), y: (s - h) / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination + "/icon_\(size)x\(size)\(suffix).png"))
    }
}
