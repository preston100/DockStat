// Draws DockStat's app icon at every size macOS wants and packs it into AppIcon.icns.
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draws the icon on a 1024×1024 canvas (scaled for smaller sizes).
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: 824×824 body centred on 1024, ~185 corner radius, soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x0b0c10).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Deep night gradient with a faint blue glow from the top.
    NSGradient(colors: [color(0x23293a), color(0x0d0f16)])!.draw(in: shape, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x4f8cff, 0.35), color(0x4f8cff, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 980), radius: 0, toCenter: NSPoint(x: 512, y: 980), radius: 620, options: [])

    // A miniature "screen bottom": [panel] [dock] [panel], the app's whole idea.
    let barY: CGFloat = 250, barH: CGFloat = 150
    func glass(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r, xRadius: r.height * 0.36, yRadius: r.height * 0.36)
        color(0xffffff, 0.10).setFill(); p.fill()
        color(0xffffff, 0.22).setStroke(); p.lineWidth = 4; p.stroke()
    }
    let leftPanel = NSRect(x: 150, y: barY, width: 200, height: barH)
    let dock = NSRect(x: 370, y: barY, width: 284, height: barH)
    let rightPanel = NSRect(x: 674, y: barY, width: 200, height: barH)
    glass(leftPanel); glass(dock); glass(rightPanel)

    // Dock "apps".
    let appColors: [UInt32] = [0x3d8bff, 0x34d17a, 0xff9f2e]
    for (i, c) in appColors.enumerated() {
        let r = NSRect(x: dock.minX + 26 + CGFloat(i) * 84, y: barY + 39, width: 72, height: 72)
        let p = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
        NSGradient(colors: [color(c), color(c, 0.75)])!.draw(in: p, angle: -90)
    }

    // Left panel: a ring gauge.
    func ring(center: NSPoint, radius: CGFloat, fraction: CGFloat, c: UInt32) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 18; color(0xffffff, 0.15).setStroke(); track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = 18; arc.lineCapStyle = .round; color(c).setStroke(); arc.stroke()
    }
    ring(center: NSPoint(x: leftPanel.midX, y: leftPanel.midY), radius: 46, fraction: 0.68, c: 0x34d17a)

    // Right panel: two level bars.
    for (i, (f, c)) in [(0.8, 0xffc533), (0.5, 0x4f8cff)].enumerated() {
        let y = rightPanel.minY + 92 - CGFloat(i) * 48
        let track = NSRect(x: rightPanel.minX + 32, y: y, width: 136, height: 20)
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill(with: color(0xffffff, 0.15))
        var fill = track; fill.size.width *= CGFloat(f)
        NSBezierPath(roundedRect: fill, xRadius: 10, yRadius: 10).fill(with: color(UInt32(c)))
    }

    // A big live-looking CPU graph above the bar.
    let graph = NSBezierPath()
    let pts: [CGFloat] = [0.30, 0.42, 0.35, 0.55, 0.48, 0.70, 0.52, 0.62, 0.86, 0.66, 0.74]
    let gx: CGFloat = 170, gw: CGFloat = 684, gy: CGFloat = 470, gh: CGFloat = 330
    for (i, v) in pts.enumerated() {
        let p = NSPoint(x: gx + gw * CGFloat(i) / CGFloat(pts.count - 1), y: gy + gh * v)
        i == 0 ? graph.move(to: p) : graph.line(to: p)
    }
    let area = graph.copy() as! NSBezierPath
    area.line(to: NSPoint(x: gx + gw, y: gy)); area.line(to: NSPoint(x: gx, y: gy)); area.close()
    NSGradient(colors: [color(0x34d17a, 0.45), color(0x34d17a, 0.0)])!.draw(in: area, angle: -90)
    graph.lineWidth = 16; graph.lineJoinStyle = .round; graph.lineCapStyle = .round
    color(0x5ef0a0).setStroke(); graph.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Rim highlight.
    color(0xffffff, 0.10).setStroke()
    shape.lineWidth = 3
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

extension NSBezierPath {
    func fill(with c: NSColor) { c.setFill(); fill() }
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DockStat.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: px).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
// Also keep a 1024 PNG for the README.
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out)" : "iconutil failed")
