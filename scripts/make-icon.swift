// Draws the Clipline app icon: a screenshot and a note in crisp glass, held
// together at the top by a silver paperclip, over a warm gradient.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func shadow(_ alpha: CGFloat, blur: CGFloat, y: CGFloat) {
    let s = NSShadow()
    s.shadowColor = color(60, 20, 30, alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
}

// Body, following the macOS icon grid: 824pt square, 100pt margin.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
shadow(0.30, blur: 26, y: -12)
color(255, 160, 130).setFill()
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
NSGradient(colors: [color(255, 176, 112), color(252, 128, 124), color(240, 92, 136)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -90)
// Soft light from the top left.
NSGradient(colors: [color(255, 255, 255, 0.32), color(255, 255, 255, 0)])!
    .draw(fromCenter: NSPoint(x: 400, y: 800), radius: 0, toCenter: NSPoint(x: 400, y: 800), radius: 620, options: [])

/// A glass card: frosted white, a soft shadow, a top-lit edge, and what it
/// holds inside.
func glassCard(_ r: NSRect, radius: CGFloat, fill: NSColor, _ content: (NSRect) -> Void) {
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    shadow(0.32, blur: 34, y: -18)
    fill.setFill()
    path.fill()
    ctx.restoreGState()
    let inset: CGFloat = 18
    let inner = r.insetBy(dx: inset, dy: inset)
    ctx.saveGState()
    NSBezierPath(roundedRect: inner, xRadius: radius - inset, yRadius: radius - inset).addClip()
    content(inner)
    ctx.restoreGState()
    ctx.saveGState()
    let ring = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    ring.append(NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: radius - 4, yRadius: radius - 4))
    ring.windingRule = .evenOdd
    ring.addClip()
    NSGradient(colors: [color(255, 255, 255, 0.95), color(255, 255, 255, 0.3)])!.draw(in: r, angle: -90)
    ctx.restoreGState()
}

// Behind: a note of copied text.
ctx.saveGState()
ctx.translateBy(x: 640, y: 760)
ctx.rotate(by: -8 * .pi / 180)
glassCard(NSRect(x: -330, y: -470, width: 420, height: 470), radius: 56, fill: color(255, 255, 255, 0.6)) { r in
    color(255, 255, 255, 0.35).setFill(); r.fill()
    color(110, 60, 80, 0.42).setFill()
    for (i, f) in [CGFloat(0.8), 0.62, 0.72, 0.5].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: r.minX + 40, y: r.maxY - 70 - CGFloat(i) * 52, width: (r.width - 80) * f, height: 22),
                     xRadius: 11, yRadius: 11).fill()
    }
}
ctx.restoreGState()

// In front: a screenshot of a sunset.
ctx.saveGState()
ctx.translateBy(x: 470, y: 640)
ctx.rotate(by: 6 * .pi / 180)
glassCard(NSRect(x: -230, y: -400, width: 440, height: 340), radius: 50, fill: color(255, 255, 255, 0.55)) { r in
    NSGradient(colors: [color(255, 168, 96), color(255, 110, 140), color(120, 90, 210)])!.draw(in: r, angle: 90)
    color(255, 234, 170).setFill()
    let s = r.height * 0.28
    NSBezierPath(ovalIn: NSRect(x: r.midX - s / 2 + r.width * 0.12, y: r.minY + r.height * 0.32, width: s, height: s)).fill()
    let hills = NSBezierPath()
    hills.move(to: NSPoint(x: r.minX, y: r.minY + r.height * 0.34))
    hills.curve(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.22),
                controlPoint1: NSPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.6),
                controlPoint2: NSPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.05))
    hills.line(to: NSPoint(x: r.maxX, y: r.minY)); hills.line(to: NSPoint(x: r.minX, y: r.minY)); hills.close()
    color(70, 50, 140).setFill(); hills.fill()
}
ctx.restoreGState()

// The paperclip over both top corners: silver wire with a bright edge.
let clip = NSBezierPath()
let unit: CGFloat = 13, origin = NSPoint(x: 556, y: 800)
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * unit, y: origin.y - y * unit) }
clip.move(to: pt(3.9, 13))
clip.line(to: pt(3.9, 26))
clip.curve(to: pt(7.1, 26), controlPoint1: pt(3.9, 28.2), controlPoint2: pt(7.1, 28.2))
clip.line(to: pt(7.1, 4.6))
clip.curve(to: pt(1.2, 4.6), controlPoint1: pt(7.1, 0.6), controlPoint2: pt(1.2, 0.6))
clip.line(to: pt(1.2, 27.5))
clip.curve(to: pt(9.8, 27.5), controlPoint1: pt(1.2, 33), controlPoint2: pt(9.8, 33))
clip.line(to: pt(9.8, 9))
clip.lineWidth = 18
clip.lineCapStyle = .round
clip.lineJoinStyle = .round
ctx.saveGState()
shadow(0.4, blur: 10, y: -6)
color(232, 233, 238).setStroke()
clip.stroke()
ctx.restoreGState()
clip.lineWidth = 6
color(255, 255, 255, 0.8).setStroke()
clip.stroke()
ctx.restoreGState()

// Top-lit rim on the icon body.
ctx.saveGState()
let rim = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
rim.append(NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182))
rim.windingRule = .evenOdd
rim.addClip()
NSGradient(colors: [color(255, 255, 255, 0.55), color(255, 255, 255, 0.05)])!.draw(in: body, angle: -90)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
