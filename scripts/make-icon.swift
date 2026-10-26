// Draws Corral's app icon at every size macOS wants and writes AppIcon.icns directly (the
// format is a list of PNGs, so no iconutil): an ember squircle, the Connect-style fan of lines,
// and the corral (a ring of posts around a sparkle) that the menu bar item also uses.
// Usage: make-icon <AppIcon.icns> [preview.png]
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func sparkle(center c: NSPoint, radius r: CGFloat, waist: CGFloat = 0.16) -> NSBezierPath {
    let path = NSBezierPath()
    func quad(to end: NSPoint, control: NSPoint) {
        let start = path.currentPoint
        path.curve(
            to: end,
            controlPoint1: NSPoint(x: start.x + 2 / 3 * (control.x - start.x), y: start.y + 2 / 3 * (control.y - start.y)),
            controlPoint2: NSPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
        )
    }
    path.move(to: NSPoint(x: c.x, y: c.y + r))
    quad(to: NSPoint(x: c.x + r, y: c.y), control: NSPoint(x: c.x + r * waist, y: c.y + r * waist))
    quad(to: NSPoint(x: c.x, y: c.y - r), control: NSPoint(x: c.x + r * waist, y: c.y - r * waist))
    quad(to: NSPoint(x: c.x - r, y: c.y), control: NSPoint(x: c.x - r * waist, y: c.y - r * waist))
    quad(to: NSPoint(x: c.x, y: c.y + r), control: NSPoint(x: c.x - r * waist, y: c.y + r * waist))
    path.close()
    return path
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // The macOS icon grid: an 824-point body with continuous-looking corners.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186 * s, yRadius: 186 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    color(0xF24A0C).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [color(0xFF7A3D), color(0xFF5214), color(0xE8400A)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -60)

    // The fan: lines gathered at the left, opening to the right with one shared wave.
    if size >= 64 {
        let count = 26
        for index in 0..<count {
            let t = CGFloat(index) / CGFloat(count - 1)
            let path = NSBezierPath()
            for step in 0...80 {
                let u = CGFloat(step) / 80
                let spread = 0.10 + 0.95 * pow(u, 1.3)
                let wave = sin((u * 1.6 - 0.2) * .pi) * 0.12
                let y = body.minY + body.height * (0.66 + (t - 0.5) * spread * 0.9 + wave)
                let point = NSPoint(x: body.minX + body.width * u, y: y)
                step == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.lineWidth = max(1, 2.2 * s)
            let emphasis = 1 - min(1, abs(t - 0.45) / 0.55)
            NSColor.white.withAlphaComponent(0.06 + 0.16 * emphasis).setStroke()
            path.stroke()
        }
    }
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The corral: ten posts in a ring around a sparkle.
    let center = NSPoint(x: body.midX, y: body.midY - 24 * s)
    let radius = 232 * s
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    let circumference = 2 * CGFloat.pi * radius
    let post = circumference / 10
    ring.lineWidth = 40 * s
    ring.lineCapStyle = .round
    ring.setLineDash([post * 0.42, post * 0.58], count: 2, phase: post * 0.21)
    NSColor.white.setStroke()
    ring.stroke()
    NSColor.white.setFill()
    sparkle(center: center, radius: 128 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ICNS entry types for PNG payloads, by pixel size (the @2x variants have their own codes).
let entries: [(String, CGFloat)] = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
    ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
]
func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
var body = Data()
var rendered: [CGFloat: Data] = [:]
for (type, size) in entries {
    let png = rendered[size] ?? drawIcon(size: size).representation(using: .png, properties: [:])!
    rendered[size] = png
    body += Data(type.utf8) + bigEndian(UInt32(png.count + 8)) + png
}
let icns = Data("icns".utf8) + bigEndian(UInt32(body.count + 8)) + body
try! icns.write(to: output)
if CommandLine.arguments.count > 2, let preview = rendered[1024] {
    try! preview.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("wrote \(output.path)")
