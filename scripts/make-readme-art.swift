// Renders every image in the README, in light and dark:
//   hero-*.png   headline and the line hanging under the menu bar, each
//                photo with its source tag, and the note clip at the end
//   demo-*.gif   the reveal: pointer to the middle of the menu bar, line
//                slides down, a click copies, the pointer leaves and the
//                line tucks away
//   bento-*.png  six gestures as tiles, each with a glass badge
//   capture-*.gif  the screenshot tool: windows, then a button, light up
//                under the pointer, a drag selects, Done hangs it
//   markup-*.gif   marking a selection: a thicker box, an arrow, and text
//                in two colors
//   notes-*.gif    the clip of copied text: open it, search, pick with the
//                keyboard
// Usage: swift scripts/make-readme-art.swift [language] [folder]
// English goes to docs/images, any other language to docs/images/<language>.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let language = CommandLine.arguments.dropFirst().first ?? "en"
let outDir = CommandLine.arguments.dropFirst(2).first ?? (language == "en" ? "docs/images" : "docs/images/\(language)")
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: Words

// The words drawn into the images, keyed by the English text.
let translations: [String: [String: String]] = [
    "zh-Hans": [
        "Screenshots and snippets, all on one line.": "截图和文字，一根绳上全挂着。",
        "Copied": "已复制",
        "Photos": "照片",
        "Click to copy.": "单击复制。",
        "Paste it anywhere, instantly.": "随处粘贴，即刻可用。",
        "Hold to mark up.": "长按标注。",
        "Arrows, text, mosaic. In place.": "箭头、文字、马赛克，原地完成。",
        "Drag to share.": "拖出分享。",
        "In an app, it leaves the line.": "拖进 App，绳上随即收走。",
        "Drop to hang.": "拖入悬挂。",
        "Any image can join the line.": "任何图片，拖上绳就挂好。",
        "\u{2303}\u{2325}A to capture.": "\u{2303}\u{2325}A 截图。",
        "Windows and buttons light up.": "窗口和按钮，自动识别。",
        "Let it go.": "松手放下。",
        "The cross or the Trash. That\u{2019}s it.": "点叉或拖进废纸篓，就这么简单。",
        "Download": "下载",
        "button": "按钮",
        "Charts": "图表",
        "Peak": "峰值",
        "Search copied text": "搜索复制过的文字",
        "%d items": "%d 条",
        "Clear": "清空",
        "Terminal": "终端",
        "Messages": "信息",
        "Mail": "邮件",
        "1 min. ago": "1分钟前",
        "4 min. ago": "4分钟前",
        "12 min. ago": "12分钟前",
        "1 hr. ago": "1小时前",
        "2 hr. ago": "2小时前",
        "Meeting moved to 3:30, same room.": "会议改到 3:30，还是那间会议室。",
        "Thanks! I\u{2019}ll send the deck tonight.": "谢谢！我今晚把演示文稿发你。",
    ],
]

func T(_ english: String) -> String {
    if language == "en" { return english }
    guard let words = translations[language] else { fatalError("No words for \(language)") }
    guard let word = words[english] else { fatalError("No \(language) for \"\(english)\"") }
    return word
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// MARK: Themes

struct Theme {
    let name: String
    let page: NSColor          // README background behind everything
    let ink: NSColor
    let secondaryInk: NSColor
    let wallpaper: [NSColor]
    let glow: NSColor
    let menuBar: NSColor
    let menuInk: NSColor
    let line: NSColor
    let glassFill: NSColor
    let edgeTop: NSColor
    let edgeBottom: NSColor
    let shadow: NSColor
    let tile: NSColor
    let tileInk: NSColor
}

let light = Theme(
    name: "light",
    page: color(255, 255, 255), ink: color(29, 29, 31), secondaryInk: color(110, 110, 115),
    wallpaper: [color(214, 224, 255), color(232, 222, 252), color(255, 226, 222)],
    glow: color(255, 255, 255, 0.35),
    menuBar: color(255, 255, 255, 0.55), menuInk: color(30, 32, 48, 0.5),
    line: color(120, 124, 145), glassFill: color(255, 255, 255, 0.5),
    edgeTop: color(255, 255, 255, 0.95), edgeBottom: color(255, 255, 255, 0.35),
    shadow: color(40, 40, 80, 0.22),
    tile: color(245, 245, 247), tileInk: color(29, 29, 31))

let dark = Theme(
    name: "dark",
    page: color(13, 17, 23), ink: color(245, 245, 247), secondaryInk: color(161, 161, 166),
    wallpaper: [color(22, 26, 52), color(40, 30, 72), color(70, 36, 70)],
    glow: color(140, 120, 255, 0.22),
    menuBar: color(20, 20, 30, 0.55), menuInk: color(255, 255, 255, 0.5),
    line: color(150, 154, 175), glassFill: color(255, 255, 255, 0.12),
    edgeTop: color(255, 255, 255, 0.45), edgeBottom: color(255, 255, 255, 0.08),
    shadow: color(0, 0, 0, 0.5),
    tile: color(28, 28, 30), tileInk: color(245, 245, 247))

// MARK: Canvas

func makeBitmap(_ w: CGFloat, _ h: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func draw(_ rep: NSBitmapImageRep, scale: CGFloat, _ body: (CGContext) -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    body(ctx)
    NSGraphicsContext.restoreGraphicsState()
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func shadow(_ t: Theme, _ alpha: CGFloat, blur: CGFloat, y: CGFloat) {
    let s = NSShadow()
    s.shadowColor = t.shadow.withAlphaComponent(t.shadow.alphaComponent * alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          tracking: CGFloat = 0, centerX: CGFloat, baselineY: CGFloat, rounded: Bool = false) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    let s = NSAttributedString(string: string, attributes: attrs)
    let w = s.size().width
    s.draw(at: NSPoint(x: centerX - w / 2, y: baselineY + font.descender))
}

func leftText(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
              tracking: CGFloat = 0, x: CGFloat, baselineY: CGFloat, maxWidth: CGFloat = .infinity) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let s = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
    if s.size().width > maxWidth { fatalError("\"\(string)\" is too long: \(Int(s.size().width)) of \(Int(maxWidth)) points") }
    s.draw(at: NSPoint(x: x, y: baselineY + font.descender))
}

func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
}

// MARK: The scene

/// `kind` picks the picture, and the app it came from for its source tag.
struct Frame { let x: CGFloat; let w: CGFloat; let h: CGFloat; let tilt: CGFloat; let kind: Int }

struct SceneState {
    var reveal: CGFloat = 1            // 0 tucked away, 1 down
    var swing: [CGFloat] = [0, 0, 0]   // extra degrees per photo
    var cursor: NSPoint? = nil
    var hover: Int? = nil
    var pressed: CGFloat = 0
    var copied: CGFloat = 0            // 0...1, the hovered tag saying Copied
    var noteClip: CGFloat? = nil       // where the note clip hangs, if it does
}

func drawScene(_ ctx: CGContext, _ t: Theme, rect: NSRect, frames: [Frame], state: SceneState, cornerRadius: CGFloat,
               backdrop: ((CGContext) -> Void)? = nil, overlay: ((CGContext) -> Void)? = nil) {
    ctx.saveGState()
    let W = rect.width, H = rect.height
    ctx.translateBy(x: rect.minX, y: rect.minY)
    let canvas = NSRect(x: 0, y: 0, width: W, height: H)
    NSBezierPath(roundedRect: canvas, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

    NSGradient(colors: t.wallpaper, atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: canvas, angle: -35)
    NSGradient(colors: [t.glow, t.glow.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: W * 0.5, y: H * 0.45), radius: 0,
              toCenter: NSPoint(x: W * 0.5, y: H * 0.45), radius: W * 0.6, options: [])
    backdrop?(ctx)

    let barH: CGFloat = 26
    // The line lives under the menu bar and slides out from beneath it.
    let hidden: CGFloat = 260
    let dy = (1 - state.reveal) * hidden
    let top = H - barH - 20 + dy
    let sag: CGFloat = 22
    func lineY(_ x: CGFloat) -> CGFloat { let f = x / W; return top - 4 * sag * f * (1 - f) }

    ctx.saveGState()
    NSRect(x: 0, y: 0, width: W, height: H - barH).clip()
    let linePath = NSBezierPath()
    linePath.move(to: NSPoint(x: -10, y: top))
    let c = NSPoint(x: W / 2, y: top - 2 * sag)
    linePath.curve(to: NSPoint(x: W + 10, y: top),
                   controlPoint1: NSPoint(x: -10 + (c.x + 10) * 2 / 3, y: top + (c.y - top) * 2 / 3),
                   controlPoint2: NSPoint(x: W + 10 + (c.x - W - 10) * 2 / 3, y: top + (c.y - top) * 2 / 3))
    ctx.saveGState(); shadow(t, 0.8, blur: 3, y: -2)
    linePath.lineWidth = 1.8; t.line.setStroke(); linePath.stroke()
    ctx.restoreGState()

    for (i, f) in frames.enumerated() {
        let hover = state.hover == i
        let scale: CGFloat = hover ? (1.03 - 0.06 * state.pressed) : 1
        ctx.saveGState()
        ctx.translateBy(x: f.x, y: lineY(f.x) + 7)
        ctx.rotate(by: (f.tilt + state.swing[i]) * .pi / 180)
        ctx.scaleBy(x: scale, y: scale)
        drawTag(ctx, t, w: f.w, h: f.h, kind: f.kind, open: hover, copied: hover ? state.copied : 0)
        drawGlassPhoto(ctx, t, w: f.w, h: f.h, kind: f.kind, lift: hover)
        ctx.restoreGState()
    }
    if let x = state.noteClip {
        ctx.saveGState()
        ctx.translateBy(x: x, y: lineY(x) + 7)
        ctx.rotate(by: 2 * .pi / 180 + (state.swing.last ?? 0) * .pi / 360)
        drawNoteClip(ctx, t)
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Menu bar on top of everything.
    t.menuBar.setFill()
    NSRect(x: 0, y: H - barH, width: W, height: barH).fill()
    t.menuInk.setFill()
    NSBezierPath(ovalIn: NSRect(x: 18, y: H - barH / 2 - 5, width: 10, height: 10)).fill()
    for (i, w) in [CGFloat(46), 32, 28, 40, 34].enumerated() {
        let x = 42 + CGFloat(i) * 52
        NSBezierPath(roundedRect: NSRect(x: x, y: H - barH / 2 - 3.5, width: w, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
    }
    for i in 0..<4 {
        NSBezierPath(roundedRect: NSRect(x: W - 34 - CGFloat(i) * 30, y: H - barH / 2 - 5, width: 16, height: 10), xRadius: 3, yRadius: 3).fill()
    }

    overlay?(ctx)
    if let p = state.cursor { drawCursor(ctx, t, at: NSPoint(x: p.x, y: min(p.y, H - 1))) }
    ctx.restoreGState()
}

func drawGlassPhoto(_ ctx: CGContext, _ t: Theme, w: CGFloat, h: CGFloat, kind: Int, lift: Bool) {
    let radius: CGFloat = 16, inset: CGFloat = 4.5
    let frame = NSRect(x: -w / 2, y: -h, width: w, height: h)
    let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    ctx.saveGState(); shadow(t, lift ? 1.3 : 1, blur: lift ? 30 : 22, y: lift ? -16 : -12)
    t.glassFill.setFill(); path.fill()
    ctx.restoreGState()

    let photo = frame.insetBy(dx: inset, dy: inset)
    ctx.saveGState()
    NSBezierPath(roundedRect: photo, xRadius: radius - inset, yRadius: radius - inset).addClip()
    drawContent(kind, photo)
    ctx.restoreGState()

    ctx.saveGState()
    let ring = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    ring.append(NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1))
    ring.windingRule = .evenOdd
    ring.addClip()
    NSGradient(colors: [t.edgeTop, t.edgeBottom])!.draw(in: frame, angle: -90)
    ctx.restoreGState()

    let clip = NSRect(x: -4.5, y: -15, width: 9, height: 25)
    let clipPath = NSBezierPath(roundedRect: clip, xRadius: 3.5, yRadius: 3.5)
    ctx.saveGState(); shadow(t, 0.9, blur: 3, y: -1.5)
    color(200, 200, 205).setFill(); clipPath.fill()
    ctx.restoreGState()
    NSGradient(colors: [color(178, 179, 186), color(238, 239, 243), color(209, 210, 216), color(158, 159, 166)],
               atLocations: [0, 0.35, 0.65, 1], colorSpace: .sRGB)!.draw(in: clipPath, angle: 0)
    color(30, 30, 40, 0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: -2.5, y: -0.7, width: 5, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
}

func drawContent(_ kind: Int, _ r: NSRect) {
    switch kind {
    case 0:
        color(250, 250, 252).setFill(); r.fill()
        let bar = NSRect(x: r.minX, y: r.maxY - 20, width: r.width, height: 20)
        color(236, 237, 242).setFill(); bar.fill()
        for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 8 + CGFloat(i) * 11, y: bar.midY - 3, width: 6.5, height: 6.5)).fill()
        }
        color(98, 120, 255).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 12, y: bar.minY - 24, width: r.width * 0.45, height: 9), xRadius: 3, yRadius: 3).fill()
        color(214, 217, 226).setFill()
        for i in 0..<6 {
            let y = bar.minY - 42 - CGFloat(i) * 14
            if y < r.minY + 8 { break }
            let w = r.width * [0.8, 0.62, 0.72, 0.5, 0.66, 0.58][i]
            NSBezierPath(roundedRect: NSRect(x: r.minX + 12, y: y, width: w, height: 5.5), xRadius: 2.75, yRadius: 2.75).fill()
        }
    case 1:
        NSGradient(colors: [color(255, 156, 96), color(255, 108, 132), color(118, 88, 204)])!.draw(in: r, angle: 90)
        color(255, 232, 166).setFill()
        let s = r.height * 0.26
        NSBezierPath(ovalIn: NSRect(x: r.midX - s / 2, y: r.minY + r.height * 0.3, width: s, height: s)).fill()
        let hills = NSBezierPath()
        hills.move(to: NSPoint(x: r.minX, y: r.minY + r.height * 0.3))
        hills.curve(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.2),
                    controlPoint1: NSPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.55),
                    controlPoint2: NSPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.05))
        hills.line(to: NSPoint(x: r.maxX, y: r.minY)); hills.line(to: NSPoint(x: r.minX, y: r.minY)); hills.close()
        color(66, 48, 128).setFill(); hills.fill()
    default:
        color(24, 26, 36).setFill(); r.fill()
        let bars: [CGFloat] = [0.35, 0.55, 0.42, 0.7, 0.6, 0.85, 0.74]
        let bw = (r.width - 36) / CGFloat(bars.count)
        for (i, v) in bars.enumerated() {
            (i == bars.count - 2 ? color(120, 140, 255) : color(120, 140, 255, 0.45)).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 18 + CGFloat(i) * bw + 3, y: r.minY + 16,
                                             width: bw - 6, height: (r.height - 42) * v), xRadius: 3, yRadius: 3).fill()
        }
        color(255, 255, 255, 0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 18, y: r.maxY - 18, width: 54, height: 5.5), xRadius: 2.75, yRadius: 2.75).fill()
    }
}

/// Draws an SF Symbol centered on a point. Asked for at four times its size
/// and drawn back down, so it stays a crisp shape instead of a small bitmap
/// stretched over the 2x canvas, and turned with the tag without going soft.
func drawSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at center: NSPoint) {
    let k: CGFloat = 4
    let config = NSImage.SymbolConfiguration(pointSize: size * k, weight: weight).applying(.init(paletteColors: [color]))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let sz = NSSize(width: symbol.size.width / k, height: symbol.size.height / k)
    symbol.draw(in: NSRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2, width: sz.width, height: sz.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
}

/// The app each kind of picture came from: its icon colors and glyph.
let apps: [(colors: [NSColor], glyph: String)] = [
    ([color(90, 170, 255), color(40, 110, 240)], "safari"),
    ([color(255, 190, 80), color(250, 110, 120)], "photo.fill"),
    ([color(80, 90, 120), color(30, 34, 50)], "chart.bar.fill"),
    ([color(70, 72, 80), color(28, 28, 32)], "apple.terminal.fill"),
    ([color(110, 225, 120), color(40, 190, 70)], "message.fill"),
    ([color(100, 190, 255), color(30, 120, 250)], "envelope.fill"),
]

func drawAppIcon(_ kind: Int, in r: NSRect) {
    let app = apps[kind % apps.count]
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.23, yRadius: r.width * 0.23)
    NSGradient(colors: app.colors)!.draw(in: path, angle: -90)
    drawSymbol(app.glyph, size: r.width * 0.5, weight: .bold, color: .white, at: NSPoint(x: r.midX, y: r.midY))
}

/// The source tag tied under the card on a thread, a little right of the
/// middle, hanging slightly crooked. Resting it shows the app's icon; under
/// the pointer its name, and once copied a check and Copied.
func drawTag(_ ctx: CGContext, _ t: Theme, w: CGFloat, h: CGFloat, kind: Int, open: Bool, copied: CGFloat) {
    let anchor = NSPoint(x: -w / 2 + w * 0.62, y: -h)
    ctx.saveGState()
    ctx.translateBy(x: anchor.x, y: anchor.y)
    ctx.rotate(by: 4 * .pi / 180)
    let thread = NSBezierPath()
    thread.move(to: .zero); thread.line(to: NSPoint(x: 0, y: -14))
    thread.lineWidth = 1.1; color(140, 140, 145).setStroke(); thread.stroke()

    let icon: CGFloat = 27, pad: CGFloat = 5
    let label = copied > 0.5 ? T("Copied") : T("Photos")
    let shows = open || copied > 0
    let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let textW = shows ? NSAttributedString(string: label, attributes: [.font: font]).size().width.rounded(.up) : 0
    let pillW = pad + icon + (shows ? 7 + textW + 10 : pad), pillH = icon + pad * 2
    let pill = NSRect(x: -pillW / 2, y: -14 - pillH, width: pillW, height: pillH)
    let path = NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11)
    ctx.saveGState(); shadow(t, 0.7, blur: 5, y: -2)
    t.glassFill.withAlphaComponent(min(1, t.glassFill.alphaComponent * 1.5)).setFill(); path.fill()
    ctx.restoreGState()
    ctx.saveGState()
    let rim = NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11)
    rim.append(NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10))
    rim.windingRule = .evenOdd; rim.addClip()
    NSGradient(colors: [t.edgeTop, t.edgeBottom])!.draw(in: pill, angle: -90)
    ctx.restoreGState()

    let iconRect = NSRect(x: pill.minX + pad, y: pill.minY + pad, width: icon, height: icon)
    if copied > 0.5 {
        drawSymbol("checkmark", size: 12, weight: .bold, color: t.ink, at: NSPoint(x: iconRect.midX, y: iconRect.midY))
    } else {
        drawAppIcon(kind, in: iconRect)
    }
    if shows {
        NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: t.ink])
            .draw(at: NSPoint(x: iconRect.maxX + 7, y: pill.midY - (font.ascender - font.descender) / 2))
    }
    ctx.restoreGState()
}

/// The clip at the end of the line: a paperclip holding a little stack of
/// glass notes, the text you copied, with how many there are.
func drawNoteClip(_ ctx: CGContext, _ t: Theme) {
    let paper = NSSize(width: 104, height: 84), top: CGFloat = -21
    let anchor = NSPoint(x: paper.width * 0.3, y: 0)
    for (i, angle) in [CGFloat(-6), 4, 0].enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.rotate(by: angle * .pi / 180)
        ctx.translateBy(x: -anchor.x, y: -anchor.y)
        let r = NSRect(x: -paper.width / 2, y: top - paper.height, width: paper.width, height: paper.height)
        let path = NSBezierPath(roundedRect: r, xRadius: 15, yRadius: 15)
        ctx.saveGState(); shadow(t, 0.7, blur: 10, y: -5)
        t.glassFill.withAlphaComponent(min(1, t.glassFill.alphaComponent * 1.3)).setFill(); path.fill()
        ctx.restoreGState()
        ctx.saveGState()
        let rim = NSBezierPath(roundedRect: r, xRadius: 15, yRadius: 15)
        rim.append(NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14))
        rim.windingRule = .evenOdd; rim.addClip()
        NSGradient(colors: [t.edgeTop, t.edgeBottom])!.draw(in: r, angle: -90)
        ctx.restoreGState()
        if i == 2 {
            t.secondaryInk.withAlphaComponent(0.55).setFill()
            for (k, f) in [CGFloat(0.66), 0.5, 0.58].enumerated() {
                NSBezierPath(roundedRect: NSRect(x: r.minX + 11, y: r.maxY - 17 - CGFloat(k) * 12, width: (r.width - 36) * f / 0.66, height: 5),
                             xRadius: 2.5, yRadius: 2.5).fill()
            }
            let count = NSAttributedString(string: "12", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: t.secondaryInk])
            count.draw(at: NSPoint(x: r.maxX - 8 - count.size().width, y: r.minY + 6))
        }
        ctx.restoreGState()
    }
    // The paperclip: its top loop over the line, its legs over the notes.
    let clip = NSBezierPath()
    let x0 = anchor.x - 7.5
    func px(_ x: CGFloat) -> CGFloat { x0 + x * 1.35 }
    func py(_ y: CGFloat) -> CGFloat { 2 - y * 1.35 }
    clip.move(to: NSPoint(x: px(3.9), y: py(13)))
    clip.line(to: NSPoint(x: px(3.9), y: py(26)))
    clip.curve(to: NSPoint(x: px(7.1), y: py(26)), controlPoint1: NSPoint(x: px(3.9), y: py(28.2)), controlPoint2: NSPoint(x: px(7.1), y: py(28.2)))
    clip.line(to: NSPoint(x: px(7.1), y: py(4.6)))
    clip.curve(to: NSPoint(x: px(1.2), y: py(4.6)), controlPoint1: NSPoint(x: px(7.1), y: py(0.6)), controlPoint2: NSPoint(x: px(1.2), y: py(0.6)))
    clip.line(to: NSPoint(x: px(1.2), y: py(27.5)))
    clip.curve(to: NSPoint(x: px(9.8), y: py(27.5)), controlPoint1: NSPoint(x: px(1.2), y: py(33)), controlPoint2: NSPoint(x: px(9.8), y: py(33)))
    clip.line(to: NSPoint(x: px(9.8), y: py(9)))
    clip.lineWidth = 1.9; clip.lineCapStyle = .round; clip.lineJoinStyle = .round
    ctx.saveGState(); shadow(t, 1, blur: 2, y: -1.2)
    color(205, 206, 212).setStroke(); clip.stroke()
    ctx.restoreGState()
}

func drawCursor(_ ctx: CGContext, _ t: Theme, at p: NSPoint) {
    let a = NSBezierPath()
    a.move(to: p)
    a.line(to: NSPoint(x: p.x, y: p.y - 20))
    a.line(to: NSPoint(x: p.x + 5, y: p.y - 15.5))
    a.line(to: NSPoint(x: p.x + 8.6, y: p.y - 23.5))
    a.line(to: NSPoint(x: p.x + 11.8, y: p.y - 22.1))
    a.line(to: NSPoint(x: p.x + 8.2, y: p.y - 14.1))
    a.line(to: NSPoint(x: p.x + 14.5, y: p.y - 14.1))
    a.close()
    ctx.saveGState(); shadow(t, 0.9, blur: 3, y: -1.5)
    NSColor.black.setFill(); a.fill()
    ctx.restoreGState()
    a.lineWidth = 1.3; NSColor.white.setStroke(); a.stroke()
}

// MARK: Hero

func hero(_ t: Theme) {
    let W: CGFloat = 1200, H: CGFloat = 640, s: CGFloat = 2
    let rep = makeBitmap(W, H, scale: s)
    draw(rep, scale: s) { ctx in
        t.page.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        text("Clipline", size: 84, weight: .semibold, color: t.ink, tracking: -2.4, centerX: W / 2, baselineY: H - 128)
        text(T("Screenshots and snippets, all on one line."), size: 30, weight: .regular, color: t.secondaryInk,
             tracking: -0.4, centerX: W / 2, baselineY: H - 182)
        let frames = [Frame(x: 240, w: 250, h: 172, tilt: 2.5, kind: 0),
                      Frame(x: 510, w: 270, h: 186, tilt: -1.2, kind: 1),
                      Frame(x: 780, w: 220, h: 160, tilt: 3, kind: 2)]
        let scene = NSRect(x: 60, y: 40, width: W - 120, height: 330)
        ctx.saveGState(); shadow(t, 0.6, blur: 40, y: -18)
        t.page.setFill(); NSBezierPath(roundedRect: scene, xRadius: 26, yRadius: 26).fill()
        ctx.restoreGState()
        drawScene(ctx, t, rect: scene,
                  frames: frames.map { Frame(x: $0.x - 60 + 60, w: $0.w, h: $0.h, tilt: $0.tilt, kind: $0.kind) },
                  state: SceneState(cursor: NSPoint(x: 560, y: 330), noteClip: 985), cornerRadius: 26)
    }
    savePNG(rep, "\(outDir)/hero-\(t.name).png")
}

// MARK: Demo loop

func easeInOut(_ x: CGFloat) -> CGFloat { let x = max(0, min(1, x)); return x * x * (3 - 2 * x) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { a + (b - a) * x }
func lerp(_ a: NSPoint, _ b: NSPoint, _ x: CGFloat) -> NSPoint { NSPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x)) }

func demo(_ t: Theme) {
    let W: CGFloat = 960, H: CGFloat = 340, s: CGFloat = 1
    let fps: CGFloat = 25, duration: CGFloat = 5.2
    let frames = [Frame(x: 215, w: 210, h: 146, tilt: 2.5, kind: 0),
                  Frame(x: 445, w: 230, h: 158, tilt: -1.2, kind: 1),
                  Frame(x: 670, w: 190, h: 136, tilt: 3, kind: 2)]
    let rest = NSPoint(x: 620, y: 90), edge = NSPoint(x: 480, y: H), onPhoto = NSPoint(x: 457, y: 205)
    let away = NSPoint(x: 760, y: 70)

    let url = URL(fileURLWithPath: "\(outDir)/demo-\(t.name).gif")
    let count = Int(fps * duration)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                      kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary

    for i in 0..<count {
        let time = CGFloat(i) / fps
        var st = SceneState(reveal: 0, noteClip: 845)

        // Pointer travels to the top edge and rests there.
        if time < 1.0 { st.cursor = lerp(rest, edge, easeInOut((time - 0.2) / 0.8)) }
        else if time < 1.9 { st.cursor = edge }
        else if time < 2.7 { st.cursor = lerp(edge, onPhoto, easeInOut((time - 1.9) / 0.8)) }
        else if time < 3.9 { st.cursor = onPhoto }
        else { st.cursor = lerp(onPhoto, away, easeInOut((time - 3.9) / 0.7)) }

        // The line slides down with a soft spring, photos swing as it lands.
        let downAt: CGFloat = 1.25, upAt: CGFloat = 4.75
        if time >= downAt && time < upAt {
            let d = time - downAt
            st.reveal = 1 - exp(-7 * d) * cos(9 * d)
            for k in 0..<3 {
                let dk = max(0, d - 0.05 * CGFloat(k))
                st.swing[k] = 9 * exp(-2.6 * dk) * sin(8.5 * dk + 0.6) * (k % 2 == 0 ? 1 : -1)
            }
        } else if time >= upAt {
            st.reveal = 1 - easeInOut((time - upAt) / 0.28)
        }

        // Hover, press and copy on the middle photo.
        if time >= 2.55 && time < 4.0 { st.hover = 1 }
        if time >= 2.95 && time < 3.15 { st.pressed = easeInOut((time - 2.95) / 0.1) * (1 - easeInOut((time - 3.05) / 0.1)) }
        if time >= 3.1 && time < 4.0 { st.copied = min(1, (time - 3.1) / 0.15) * (time > 3.8 ? max(0, 1 - (time - 3.8) / 0.2) : 1) }

        let rep = makeBitmap(W, H, scale: s)
        draw(rep, scale: s) { ctx in
            t.page.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
            drawScene(ctx, t, rect: NSRect(x: 0, y: 0, width: W, height: H), frames: frames, state: st, cornerRadius: 22)
        }
        CGImageDestinationAddImage(dest, rep.cgImage!, frameProps)
    }
    CGImageDestinationFinalize(dest)
}

// MARK: Feature loops

let accent = color(10, 132, 255)
let captureBlue = NSColor(srgbRed: 0.22, green: 0.54, blue: 0.87, alpha: 1)
let markColors: [NSColor] = [color(245, 59, 54), color(255, 158, 10), color(255, 214, 10), color(51, 199, 89),
                             color(10, 133, 255), color(176, 82, 222), .black, .white]

/// Renders `duration` seconds at 25 frames a second into a looping GIF.
func loop(_ name: String, _ t: Theme, W: CGFloat, H: CGFloat, duration: CGFloat, _ body: (CGContext, CGFloat) -> Void) {
    let fps: CGFloat = 25
    let count = Int(fps * duration)
    let url = URL(fileURLWithPath: "\(outDir)/\(name)-\(t.name).gif")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                 kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
    for i in 0..<count {
        let rep = makeBitmap(W, H, scale: 1)
        draw(rep, scale: 1) { ctx in
            t.page.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
            body(ctx, CGFloat(i) / fps)
        }
        CGImageDestinationAddImage(dest, rep.cgImage!, props)
    }
    CGImageDestinationFinalize(dest)
}

/// 0 before `start`, 1 after `start + length`, eased in between.
func ramp(_ time: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat { easeInOut((time - start) / length) }

/// A path for the pointer through timed stops: it rests at each one, then
/// glides to the next.
func path(_ time: CGFloat, _ stops: [(CGFloat, NSPoint)], glide: CGFloat = 0.5) -> NSPoint {
    var p = stops[0].1
    for (at, q) in stops.dropFirst() where time > at - glide {
        p = lerp(p, q, ramp(time, at - glide, glide))
    }
    return p
}

/// A soft ring where the pointer clicked.
func drawClick(_ ctx: CGContext, at p: NSPoint, _ time: CGFloat, _ at: CGFloat) {
    let x = (time - at) / 0.3
    guard x >= 0, x < 1 else { return }
    let r = 6 + 14 * x
    accent.withAlphaComponent(0.45 * (1 - x)).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    ring.lineWidth = 2.5; ring.stroke()
}

func clicked(_ time: CGFloat, _ times: [CGFloat], at p: NSPoint, _ ctx: CGContext) {
    for at in times { drawClick(ctx, at: p, time, at) }
}

/// Keys being pressed, as glass keycaps near the bottom.
func drawKeys(_ ctx: CGContext, _ t: Theme, _ keys: [String], center: NSPoint, alpha: CGFloat) {
    guard alpha > 0 else { return }
    let w: CGFloat = 46, h: CGFloat = 42, gap: CGFloat = 8
    let total = CGFloat(keys.count) * w + CGFloat(keys.count - 1) * gap
    ctx.saveGState(); ctx.setAlpha(alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for (i, key) in keys.enumerated() {
        let r = NSRect(x: center.x - total / 2 + CGFloat(i) * (w + gap), y: center.y - h / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        ctx.saveGState(); shadow(t, 1, blur: 12, y: -4)
        (t.name == "light" ? color(255, 255, 255, 0.95) : color(58, 58, 68, 0.95)).setFill(); path.fill()
        ctx.restoreGState()
        ctx.saveGState()
        let rim = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        rim.append(NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9))
        rim.windingRule = .evenOdd; rim.addClip()
        NSGradient(colors: [t.edgeTop, t.edgeBottom])!.draw(in: r, angle: -90)
        ctx.restoreGState()
        text(key, size: 20, weight: .medium, color: t.ink, centerX: r.midX, baselineY: r.midY - 7)
    }
    ctx.endTransparencyLayer(); ctx.restoreGState()
}

// MARK: A desktop to take screenshots of

func windowFill(_ t: Theme) -> NSColor { t.name == "light" ? color(255, 255, 255) : color(38, 38, 44) }
func windowInk(_ t: Theme) -> NSColor { t.name == "light" ? color(206, 208, 216) : color(84, 86, 98) }

/// A window with a title bar; `content` draws below it, clipped to the window.
func drawWindow(_ ctx: CGContext, _ t: Theme, _ r: NSRect, _ content: (NSRect) -> Void) {
    let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
    ctx.saveGState(); shadow(t, 1, blur: 24, y: -10); windowFill(t).setFill(); path.fill(); ctx.restoreGState()
    ctx.saveGState(); path.addClip()
    content(NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 28))
    (t.name == "light" ? color(242, 242, 245) : color(50, 50, 58)).setFill()
    NSRect(x: r.minX, y: r.maxY - 28, width: r.width, height: 28).fill()
    for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 12 + CGFloat(i) * 17, y: r.maxY - 19.5, width: 11, height: 11)).fill()
    }
    ctx.restoreGState()
}

enum Desk {
    static let web = NSRect(x: 60, y: 40, width: 520, height: 320)
    static let chart = NSRect(x: 620, y: 120, width: 290, height: 240)
    static let sidebar = NSRect(x: web.minX, y: web.minY, width: 130, height: web.height - 28)
    static let button = NSRect(x: web.minX + 158, y: web.minY + 118, width: 124, height: 34)
    static let chartContent = NSRect(x: chart.minX, y: chart.minY, width: chart.width, height: chart.height - 28)
}

func drawDesktop(_ ctx: CGContext, _ t: Theme) {
    drawWindow(ctx, t, Desk.chart) { r in drawContent(2, r) }
    drawWindow(ctx, t, Desk.web) { r in
        let side = Desk.sidebar
        (t.name == "light" ? color(244, 244, 247) : color(44, 44, 52)).setFill(); side.fill()
        for (k, w) in [CGFloat(60), 48, 70, 40, 56, 50].enumerated() {
            let row = NSRect(x: side.minX + 10, y: side.maxY - 36 - CGFloat(k) * 28, width: side.width - 20, height: 22)
            if k == 1 { accent.withAlphaComponent(0.18).setFill(); NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill() }
            windowInk(t).setFill()
            NSBezierPath(roundedRect: NSRect(x: row.minX + 8, y: row.midY - 3, width: w, height: 6), xRadius: 3, yRadius: 3).fill()
        }
        let x0 = side.maxX + 28, x1 = r.maxX - 28
        t.ink.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: x0, y: r.maxY - 44, width: 210, height: 14), xRadius: 7, yRadius: 7).fill()
        windowInk(t).setFill()
        for (k, f) in [CGFloat(0.92), 0.8, 0.96, 0.58].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: x0, y: r.maxY - 74 - CGFloat(k) * 17, width: (x1 - x0) * f, height: 7),
                         xRadius: 3.5, yRadius: 3.5).fill()
        }
        let b = Desk.button
        accent.setFill(); NSBezierPath(roundedRect: b, xRadius: 8, yRadius: 8).fill()
        text(T("Download"), size: 14, weight: .semibold, color: .white, centerX: b.midX, baselineY: b.midY - 5)
        windowInk(t).setFill()
        for (k, f) in [CGFloat(0.86), 0.7, 0.9].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: x0, y: b.minY - 30 - CGFloat(k) * 17, width: (x1 - x0) * f, height: 7),
                         xRadius: 3.5, yRadius: 3.5).fill()
        }
    }
}

// MARK: The screenshot overlay

/// The frozen screen: dimmed, the chosen area left bright with a blue edge,
/// and a dark label over it.
func drawFreeze(_ ctx: CGContext, canvas: NSRect, hole: NSRect?, label: String?, handles: Bool) {
    let dim = CGMutablePath()
    dim.addRect(canvas)
    if let hole { dim.addRect(hole) }
    ctx.addPath(dim)
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.fillPath(using: .evenOdd)
    guard let hole else { return }
    let edge = NSBezierPath(rect: hole.insetBy(dx: -0.75, dy: -0.75))
    edge.lineWidth = 1.5; captureBlue.setStroke(); edge.stroke()
    if handles {
        for x in [hole.minX, hole.midX, hole.maxX] {
            for y in [hole.minY, hole.midY, hole.maxY] where !(x == hole.midX && y == hole.midY) {
                let dot = NSBezierPath(roundedRect: NSRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5)
                NSColor.white.setFill(); dot.fill()
                dot.lineWidth = 1.5; captureBlue.setStroke(); dot.stroke()
            }
        }
    }
    if let label {
        let s = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                               .foregroundColor: NSColor.white])
        let size = s.size()
        var pill = NSRect(x: hole.minX, y: hole.maxY + 5, width: size.width + 14, height: 20)
        if pill.maxY > canvas.maxY - 2 { pill.origin.y = hole.maxY - 25; pill.origin.x += 5 }
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: pill.minX + 7, y: pill.midY - size.height / 2))
    }
}

let toolSymbols = ["rectangle", "circle", "arrow.up.right", "scribble", "textformat", "1.circle", "checkerboard.rectangle"]

struct Toolbar {
    var tool: Int? = nil          // lit once marking started
    var color = 0
    var widthIndex = 1
    var custom: CGFloat? = nil    // a width scrolled to
    var marking: Bool { tool != nil }
}

/// Where everything on the glass toolbar goes, hung by its top right corner.
func toolbarLayout(_ bar: Toolbar, topRight: NSPoint) -> (frame: NSRect, items: [(String, NSRect)]) {
    var row1: [(String, CGFloat)] = toolSymbols.indices.map { ("tool\($0)", 28) }
    if bar.marking { row1 += [("div", 7), ("undo", 28), ("redo", 28)] }
    row1 += [("div", 7), ("pin", 28), ("save", 28), ("cancel", 28), ("done", 28)]
    let w1 = row1.reduce(0) { $0 + $1.1 } + CGFloat(row1.count - 1) * 2

    var row2: [(String, CGFloat)] = []
    if bar.marking {
        row2 = markColors.indices.map { ("color\($0)", 20) }
        row2 += [("div2", 21)] + (0..<3).map { ("width\($0)", 28) }
        if let c = bar.custom { row2.append(("custom", textWidth(String(format: "%g", c), size: 11, weight: .semibold) + 27)) }
    }
    /// Colors sit 5 apart, the widths 2; the divider brings its own room.
    func gap(_ a: String, _ b: String) -> CGFloat {
        if a.hasPrefix("color") && b.hasPrefix("color") { return 5 }
        return a == "div2" || b == "div2" ? 0 : 2
    }
    func w2() -> CGFloat {
        var w: CGFloat = 0
        for (i, item) in row2.enumerated() { w += item.1 + (i > 0 ? gap(row2[i - 1].0, item.0) : 0) }
        return w
    }
    let width = max(w1, bar.marking ? w2() + 8 : 0) + 10
    let height: CGFloat = bar.marking ? 66 : 36
    let frame = NSRect(x: topRight.x - width, y: topRight.y - height, width: width, height: height)

    var items: [(String, NSRect)] = []
    var x = frame.maxX - 5 - w1
    for (id, w) in row1 {
        items.append((id, NSRect(x: x, y: frame.maxY - 31, width: w, height: 26)))
        x += w + 2
    }
    x = frame.maxX - 9 - w2()
    for (i, (id, w)) in row2.enumerated() {
        if i > 0 { x += gap(row2[i - 1].0, id) }
        items.append((id, NSRect(x: x, y: frame.minY + 5, width: w, height: 26)))
        x += w
    }
    return (frame, items)
}

func toolbarItem(_ bar: Toolbar, topRight: NSPoint, _ id: String) -> NSPoint {
    let r = toolbarLayout(bar, topRight: topRight).items.first { $0.0 == id }!.1
    return NSPoint(x: r.midX + 3, y: r.midY + 4)
}

func drawToolbar(_ ctx: CGContext, _ t: Theme, _ bar: Toolbar, topRight: NSPoint) {
    let (frame, items) = toolbarLayout(bar, topRight: topRight)
    let path = NSBezierPath(roundedRect: frame, xRadius: 11, yRadius: 11)
    ctx.saveGState(); shadow(t, 1.2, blur: 18, y: -6)
    (t.name == "light" ? color(250, 250, 252, 0.94) : color(46, 46, 54, 0.94)).setFill(); path.fill()
    ctx.restoreGState()
    ctx.saveGState()
    let rim = NSBezierPath(roundedRect: frame, xRadius: 11, yRadius: 11)
    rim.append(NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10))
    rim.windingRule = .evenOdd; rim.addClip()
    NSGradient(colors: [t.edgeTop, t.edgeBottom])!.draw(in: frame, angle: -90)
    ctx.restoreGState()

    let ink = t.ink.withAlphaComponent(0.85)
    func button(_ r: NSRect, selected: Bool, _ symbol: String, dim: Bool = false) {
        if selected { accent.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
        drawSymbol(symbol, size: 13, weight: .medium, color: selected ? .white : (dim ? t.ink.withAlphaComponent(0.3) : ink),
                   at: NSPoint(x: r.midX, y: r.midY))
    }
    for (id, r) in items {
        switch id {
        case let id where id.hasPrefix("tool"):
            let i = Int(id.dropFirst(4))!
            button(r, selected: bar.tool == i, toolSymbols[i])
        case "div", "div2":
            t.ink.withAlphaComponent(0.15).setFill()
            NSRect(x: r.midX - 0.5, y: r.midY - 10, width: 1, height: 20).fill()
        case "undo": button(r, selected: false, "arrow.uturn.backward", dim: true)
        case "redo": button(r, selected: false, "arrow.uturn.forward", dim: true)
        case "pin": button(r, selected: false, "pin")
        case "save": button(r, selected: false, "square.and.arrow.down")
        case "cancel": button(r, selected: false, "xmark")
        case "done": button(r, selected: true, "checkmark")
        case let id where id.hasPrefix("color"):
            let i = Int(id.dropFirst(5))!
            let c = NSRect(x: r.midX - 7.5, y: r.midY - 7.5, width: 15, height: 15)
            markColors[i].setFill(); NSBezierPath(ovalIn: c).fill()
            t.ink.withAlphaComponent(0.25).setStroke()
            let edge = NSBezierPath(ovalIn: c); edge.lineWidth = 0.5; edge.stroke()
            if bar.color == i {
                let ring = NSBezierPath(ovalIn: c.insetBy(dx: -2.5, dy: -2.5)); ring.lineWidth = 2
                accent.setStroke(); ring.stroke()
            }
        case let id where id.hasPrefix("width"):
            let i = Int(id.dropFirst(5))!
            let selected = bar.custom == nil && bar.widthIndex == i
            if selected { accent.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            let d = 4 + CGFloat(i) * 3.5
            (selected ? NSColor.white : ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
        case "custom":
            accent.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            let label = String(format: "%g", bar.custom ?? 0)
            leftText(label, size: 11, weight: .semibold, color: .white, x: r.minX + 7, baselineY: r.midY - 4)
            drawSymbol("arrow.uturn.backward", size: 9, weight: .semibold, color: .white,
                       at: NSPoint(x: r.maxX - 12, y: r.midY))
        default: break
        }
    }
}

// MARK: Marks

func drawRectMark(_ r: NSRect, color: NSColor, width: CGFloat) {
    let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
    path.lineWidth = width; path.lineJoinStyle = .round
    color.setStroke(); path.stroke()
}

func drawArrowMark(from a: NSPoint, to b: NSPoint, color: NSColor, width: CGFloat) {
    let len = hypot(b.x - a.x, b.y - a.y)
    guard len > 1 else { return }
    let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
    let head = min(len, max(14, width * 3.6)), half = head * 0.55
    let base = NSPoint(x: b.x - ux * head, y: b.y - uy * head)
    let shaft = NSBezierPath()
    shaft.move(to: a); shaft.line(to: NSPoint(x: base.x + ux * 2, y: base.y + uy * 2))
    shaft.lineWidth = width; shaft.lineCapStyle = .round
    color.setStroke(); shaft.stroke()
    let tip = NSBezierPath()
    tip.move(to: b)
    tip.line(to: NSPoint(x: base.x - uy * half, y: base.y + ux * half))
    tip.line(to: NSPoint(x: base.x + uy * half, y: base.y - ux * half))
    tip.close()
    tip.lineJoinStyle = .round; tip.lineWidth = 1.5
    color.setFill(); color.setStroke(); tip.fill(); tip.stroke()
}

/// Text in colored runs, with a caret after it while typing.
func drawTextMark(_ runs: [(String, NSColor)], at p: NSPoint, caret: Bool) {
    let font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    let s = NSMutableAttributedString()
    for (text, c) in runs { s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c])) }
    s.draw(at: NSPoint(x: p.x, y: p.y + font.descender))
    if caret {
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSRect(x: p.x + s.size().width + 1.5, y: p.y + font.descender + 2, width: 1.5, height: font.ascender - font.descender - 2).fill()
    }
}

// MARK: Screenshot loop

func captureLoop(_ t: Theme) {
    let W: CGFloat = 960, H: CGFloat = 440
    let canvas = NSRect(x: 0, y: 0, width: W, height: H)
    let selection = NSRect(x: Desk.sidebar.maxX + 14, y: Desk.web.minY + 102,
                           width: Desk.web.maxX - 14 - Desk.sidebar.maxX - 14, height: Desk.web.maxY - 38 - Desk.web.minY - 102)
    let bar = Toolbar()
    let barTop = NSPoint(x: selection.maxX, y: selection.minY - 8)
    let done = toolbarItem(bar, topRight: barTop, "done")
    let start = NSPoint(x: selection.minX, y: selection.maxY), end = NSPoint(x: selection.maxX, y: selection.minY)
    let frames = [Frame(x: 240, w: 190, h: 132, tilt: 2.5, kind: 1),
                  Frame(x: 460, w: 180, h: 128, tilt: -1.5, kind: 2),
                  Frame(x: 690, w: 220, h: 150, tilt: 2, kind: 0)]
    let size = { (r: NSRect) in "\(Int(r.width * 2)) × \(Int(r.height * 2))" }

    loop("capture", t, W: W, H: H, duration: 9) { ctx, time in
        let cursor = path(time, [(0, NSPoint(x: 470, y: 250)),
                                 (1.6, NSPoint(x: 780, y: 230)),
                                 (2.5, NSPoint(x: 470, y: 290)),
                                 (3.3, NSPoint(x: Desk.button.midX + 10, y: Desk.button.midY)),
                                 (4.1, start)], glide: 0.6)
        let dragging = ramp(time, 4.3, 0.9)
        let dragged = NSPoint(x: lerp(start.x, end.x, dragging), y: lerp(start.y, end.y, dragging))
        let pointer = time < 4.3 ? cursor : time < 5.4 ? dragged : path(time, [(5.4, end), (6.3, done)], glide: 0.6)

        let frozen = time >= 1.0 && time < 6.5
        var hole: NSRect? = nil, label: String? = nil
        if frozen {
            if time >= 4.3 {
                hole = NSRect(x: start.x, y: dragged.y, width: dragged.x - start.x, height: start.y - dragged.y)
                label = size(hole!)
            } else if time >= 3.1 {
                hole = Desk.button; label = "\(T("button"))   \(size(Desk.button))"
            } else if time >= 2.2 {
                hole = Desk.web; label = "Safari — Clipline   \(size(Desk.web))"
            } else if time >= 1.3 {
                hole = Desk.chart; label = "\(T("Charts")) — Q3   \(size(Desk.chart))"
            }
        }

        // After Done, the line comes down with the new screenshot at its end.
        var st = SceneState(reveal: 0, swing: [0, 0, 0], cursor: pointer)
        let downAt: CGFloat = 6.7, upAt: CGFloat = 8.4
        if time >= downAt && time < upAt {
            let d = time - downAt
            st.reveal = 1 - exp(-7 * d) * cos(9 * d)
            for k in 0..<3 {
                let dk = max(0, d - 0.05 * CGFloat(k))
                st.swing[k] = (k == 2 ? 14 : 7) * exp(-2.6 * dk) * sin(8.5 * dk + 0.6) * (k % 2 == 0 ? 1 : -1)
            }
        } else if time >= upAt {
            st.reveal = 1 - ramp(time, upAt, 0.28)
        }

        drawScene(ctx, t, rect: canvas, frames: frames, state: st, cornerRadius: 22,
                  backdrop: { ctx in drawDesktop(ctx, t) },
                  overlay: { ctx in
            if frozen {
                drawFreeze(ctx, canvas: canvas, hole: hole, label: label, handles: time >= 5.25)
                if time >= 5.25 {
                    ctx.saveGState(); ctx.setAlpha(ramp(time, 5.25, 0.2))
                    drawToolbar(ctx, t, bar, topRight: barTop)
                    ctx.restoreGState()
                }
            }
            // A white flash as it is taken.
            if time >= 6.5 && time < 6.7 {
                NSColor.white.withAlphaComponent(0.35 * (1 - (time - 6.5) / 0.2)).setFill(); canvas.fill()
            }
            clicked(time, [6.45], at: done, ctx)
            drawKeys(ctx, t, ["\u{2303}", "\u{2325}", "A"], center: NSPoint(x: W / 2, y: 60),
                     alpha: min(ramp(time, 0.3, 0.15), 1 - ramp(time, 1.3, 0.2)))
        })
    }
}

// MARK: Markup loop

func markupLoop(_ t: Theme) {
    let W: CGFloat = 960, H: CGFloat = 440
    let canvas = NSRect(x: 0, y: 0, width: W, height: H)
    let hole = Desk.chart
    let barTop = NSPoint(x: hole.maxX, y: hole.minY - 8)
    // The tallest bar in the chart, as drawContent draws it.
    let content = Desk.chartContent
    let bw = (content.width - 36) / 7
    let tall = NSRect(x: content.minX + 18 + 5 * bw + 3, y: content.minY + 16, width: bw - 6, height: (content.height - 42) * 0.85)
    let box = tall.insetBy(dx: -8, dy: -8)
    let arrowFrom = NSPoint(x: 690, y: 262), arrowTo = NSPoint(x: box.minX - 6, y: box.maxY - 30)
    let textAt = NSPoint(x: 646, y: 276)
    let word = T("Peak"), extra = " +32%"

    loop("markup", t, W: W, H: H, duration: 9.6) { ctx, time in
        var bar = Toolbar()
        if time >= 1.1 { bar.tool = 0 }
        if time >= 2.0 { bar.custom = 5 }
        if time >= 2.25 { bar.custom = 6 }
        if time >= 2.5 { bar.custom = 7 }
        if time >= 4.55 { bar.tool = 2 }
        if time >= 6.05 { bar.tool = 4 }
        if time >= 7.4 { bar.color = 3 }
        let width = bar.custom ?? 4
        let item = { (id: String) in toolbarItem(bar, topRight: barTop, id) }

        let drag = ramp(time, 3.0, 0.8)
        let boxNow = NSRect(x: box.minX, y: lerp(box.maxY, box.minY, drag), width: box.width * drag,
                            height: (box.maxY - lerp(box.maxY, box.minY, drag)))
        let arrow = ramp(time, 4.75, 0.7)
        let arrowNow = lerp(arrowFrom, arrowTo, arrow)

        var pointer: NSPoint
        if time < 3.0 {
            pointer = path(time, [(0, NSPoint(x: 470, y: 250)), (1.0, item("tool0")), (1.8, NSPoint(x: box.minX, y: box.maxY))])
        } else if time < 3.8 {
            pointer = NSPoint(x: boxNow.maxX, y: boxNow.minY)
        } else if time < 4.75 {
            pointer = path(time, [(3.8, NSPoint(x: box.maxX, y: box.minY)), (4.5, item("tool2")), (4.75, arrowFrom)], glide: 0.45)
        } else if time < 5.45 {
            pointer = arrowNow
        } else {
            pointer = path(time, [(5.45, arrowTo), (6.0, item("tool4")), (6.3, NSPoint(x: textAt.x + 4, y: textAt.y + 10)), (6.75, NSPoint(x: 640, y: 214)),
                                  (7.35, item("color3")), (8.4, item("done")), (9.4, NSPoint(x: 560, y: 250))], glide: 0.45)
        }

        // Typing: the word in red, then the rest in green.
        let typed1 = Int(max(0, min(CGFloat(word.count), (time - 6.4) / 0.13)))
        let typed2 = Int(max(0, min(CGFloat(extra.count), (time - 7.6) / 0.12)))
        var runs: [(String, NSColor)] = []
        if typed1 > 0 { runs.append((String(word.prefix(typed1)), markColors[0])) }
        if typed2 > 0 { runs.append((String(extra.prefix(typed2)), markColors[3])) }

        let frozen = time < 8.6
        drawScene(ctx, t, rect: canvas, frames: [], state: SceneState(reveal: 0, cursor: pointer), cornerRadius: 22,
                  backdrop: { ctx in drawDesktop(ctx, t) },
                  overlay: { ctx in
            guard frozen else { return }
            drawFreeze(ctx, canvas: canvas, hole: hole, label: "\(Int(hole.width * 2)) × \(Int(hole.height * 2))", handles: true)
            ctx.saveGState(); NSBezierPath(rect: hole).addClip()
            if time >= 3.0 { drawRectMark(time < 3.8 ? boxNow : box, color: markColors[0], width: width) }
            if time >= 4.75 { drawArrowMark(from: arrowFrom, to: arrowNow, color: markColors[0], width: width) }
            if !runs.isEmpty || (time >= 6.3 && time < 8.4) {
                drawTextMark(runs, at: textAt, caret: time < 8.4 && Int(time * 2.5) % 2 == 0)
            }
            ctx.restoreGState()
            drawToolbar(ctx, t, bar, topRight: barTop)
            // Scrolling: a dot the size of the line, and its width.
            if time >= 1.95 && time < 3.0 {
                ctx.saveGState(); ctx.setAlpha(min(1, (3.0 - time) / 0.2))
                let c = NSPoint(x: pointer.x + 22, y: pointer.y - 30)
                markColors[0].setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - width / 2, y: c.y - width / 2, width: width, height: width)).fill()
                let label = "\(String(format: "%g", width)) pt"
                let lw = textWidth(label, size: 11, weight: .semibold) + 12
                let pill = NSRect(x: c.x + 10, y: c.y - 10, width: lw, height: 20)
                NSColor.black.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
                leftText(label, size: 11, weight: .semibold, color: .white, x: pill.minX + 6, baselineY: pill.minY + 6)
                ctx.restoreGState()
            }
            clicked(time, [1.1, 4.55, 6.05, 6.35, 7.4, 8.5], at: pointer, ctx)
        })
    }
}

// MARK: Copied text loop

struct Snippet { let text: String; let kind: Int; let app: String; let when: String }

func notesLoop(_ t: Theme) {
    let W: CGFloat = 960, H: CGFloat = 480
    let canvas = NSRect(x: 0, y: 0, width: W, height: H)
    let frames = [Frame(x: 215, w: 210, h: 146, tilt: 2.5, kind: 0),
                  Frame(x: 445, w: 230, h: 158, tilt: -1.2, kind: 1),
                  Frame(x: 670, w: 190, h: 136, tilt: 3, kind: 2)]
    let clipX: CGFloat = 845
    let top = H - 26 - 20
    let f = clipX / W
    let clipY = top - 4 * 22 * f * (1 - f) + 7
    let clipPoint = NSPoint(x: clipX + 4, y: clipY - 60)
    let panel = NSRect(x: W - 16 - 300, y: clipY - 105 - 8 - 300, width: 300, height: 300)
    let snippets = [
        Snippet(text: "brew install --cask ffkiyo7/tap/clipline", kind: 3, app: T("Terminal"), when: T("1 min. ago")),
        Snippet(text: T("Meeting moved to 3:30, same room."), kind: 4, app: T("Messages"), when: T("4 min. ago")),
        Snippet(text: "https://github.com/ffkiyo7/Clipline", kind: 0, app: "Safari", when: T("12 min. ago")),
        Snippet(text: "brew upgrade --cask clipline", kind: 3, app: T("Terminal"), when: T("1 hr. ago")),
        Snippet(text: T("Thanks! I\u{2019}ll send the deck tonight."), kind: 5, app: T("Mail"), when: T("2 hr. ago")),
    ]
    let query = "brew"
    let rowH: CGFloat = 46
    func rowRect(_ i: Int) -> NSRect {
        NSRect(x: panel.minX + 6, y: panel.maxY - 50 - 6 - rowH - CGFloat(i) * (rowH + 2), width: panel.width - 12, height: rowH)
    }

    loop("notes", t, W: W, H: H, duration: 8.4) { ctx, time in
        var st = SceneState(reveal: 0, noteClip: clipX)
        let downAt: CGFloat = 1.0, upAt: CGFloat = 7.0
        if time >= downAt && time < upAt {
            let d = time - downAt
            st.reveal = 1 - exp(-7 * d) * cos(9 * d)
            for k in 0..<3 {
                let dk = max(0, d - 0.05 * CGFloat(k))
                st.swing[k] = 9 * exp(-2.6 * dk) * sin(8.5 * dk + 0.6) * (k % 2 == 0 ? 1 : -1)
            }
        } else if time >= upAt {
            st.reveal = 1 - ramp(time, upAt, 0.28)
        }
        let hoverRows = [rowRect(0), rowRect(1), rowRect(2)].map { NSPoint(x: $0.midX + 40, y: $0.midY - 4) }
        st.cursor = path(time, [(0, NSPoint(x: 600, y: 120)), (0.8, NSPoint(x: 480, y: H)),
                                (2.0, clipPoint), (3.0, hoverRows[0]), (3.4, hoverRows[1]), (3.8, hoverRows[2]),
                                (6.6, NSPoint(x: 600, y: 140))], glide: 0.45)

        let typed = Int(max(0, min(CGFloat(query.count), (time - 4.1) / 0.15)))
        let q = String(query.prefix(typed))
        let results = q.isEmpty ? snippets : snippets.filter { $0.text.localizedCaseInsensitiveContains(q) }
        var selection = 0
        if time >= 3.0 && time < 3.4 { selection = 0 }
        if time >= 3.4 && time < 3.8 { selection = 1 }
        if time >= 3.8 && time < 4.1 { selection = 2 }
        if time >= 5.1 { selection = 1 }
        let copied = time >= 5.8 ? selection : nil
        let open = time >= 2.1 && time < 6.15
        let panelAlpha = time < 3 ? ramp(time, 2.1, 0.15) : 1 - ramp(time, 6.0, 0.15)

        drawScene(ctx, t, rect: canvas, frames: frames, state: st, cornerRadius: 22, overlay: { ctx in
            clicked(time, [2.05], at: clipPoint, ctx)
            if open {
                ctx.saveGState(); ctx.setAlpha(panelAlpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                drawNotesPanel(ctx, t, panel, query: q, caret: time >= 2.1 && Int(time * 2.5) % 2 == 0,
                               rows: results, selection: selection, copied: copied, rowRect: rowRect)
                ctx.endTransparencyLayer(); ctx.restoreGState()
            }
            drawKeys(ctx, t, ["\u{2193}"], center: NSPoint(x: W / 2 - 60, y: 60),
                     alpha: min(ramp(time, 4.95, 0.1), 1 - ramp(time, 5.4, 0.15)))
            drawKeys(ctx, t, ["\u{21A9}"], center: NSPoint(x: W / 2 - 60, y: 60),
                     alpha: min(ramp(time, 5.7, 0.1), 1 - ramp(time, 6.15, 0.15)))
        })
    }
}

func drawNotesPanel(_ ctx: CGContext, _ t: Theme, _ r: NSRect, query: String, caret: Bool,
                    rows: [Snippet], selection: Int, copied: Int?, rowRect: (Int) -> NSRect) {
    let light = t.name == "light"
    let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
    ctx.saveGState(); shadow(t, 1.3, blur: 26, y: -10)
    (light ? color(248, 248, 250, 0.97) : color(40, 40, 46, 0.97)).setFill(); path.fill()
    ctx.restoreGState()
    ctx.saveGState(); path.addClip()
    let secondary = t.secondaryInk

    // Search field.
    let field = NSRect(x: r.minX + 10, y: r.maxY - 40, width: r.width - 20, height: 30)
    t.ink.withAlphaComponent(0.06).setFill()
    NSBezierPath(roundedRect: field, xRadius: 7, yRadius: 7).fill()
    drawSymbol("magnifyingglass", size: 12, weight: .regular, color: secondary, at: NSPoint(x: field.minX + 17, y: field.midY))
    let fieldX = field.minX + 30
    if query.isEmpty {
        leftText(T("Search copied text"), size: 13, weight: .regular, color: secondary.withAlphaComponent(0.7), x: fieldX, baselineY: field.midY - 4.5)
    } else {
        leftText(query, size: 13, weight: .regular, color: t.ink, x: fieldX, baselineY: field.midY - 4.5)
    }
    if caret {
        t.ink.setFill()
        NSRect(x: fieldX + (query.isEmpty ? 0 : textWidth(query, size: 13, weight: .regular)) + 1, y: field.midY - 8, width: 1.2, height: 16).fill()
    }
    t.ink.withAlphaComponent(0.1).setFill()
    NSRect(x: r.minX, y: r.maxY - 50, width: r.width, height: 1).fill()

    // Rows.
    let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
    for (i, row) in rows.enumerated() {
        let rr = rowRect(i)
        guard rr.maxY > r.minY + 28 else { break }
        if i == selection {
            accent.withAlphaComponent(light ? 0.16 : 0.3).setFill()
            NSBezierPath(roundedRect: rr, xRadius: 7, yRadius: 7).fill()
        }
        drawAppIcon(row.kind, in: NSRect(x: rr.minX + 8, y: rr.maxY - 8 - 16, width: 16, height: 16))
        let textX = rr.minX + 32
        NSAttributedString(string: row.text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: t.ink,
                                                          .paragraphStyle: para])
            .draw(with: NSRect(x: textX, y: rr.maxY - 24, width: rr.maxX - 8 - textX, height: 17), options: [.usesLineFragmentOrigin])
        if copied == i {
            drawSymbol("checkmark", size: 9, weight: .semibold, color: secondary, at: NSPoint(x: textX + 5, y: rr.minY + 13))
            leftText(T("Copied"), size: 10.5, weight: .regular, color: secondary, x: textX + 13, baselineY: rr.minY + 9.5)
        } else {
            leftText("\(row.app) · \(row.when)", size: 10.5, weight: .regular, color: secondary, x: textX, baselineY: rr.minY + 9.5)
        }
    }

    // Footer.
    (light ? color(248, 248, 250) : color(40, 40, 46)).setFill()
    NSRect(x: r.minX, y: r.minY, width: r.width, height: 28).fill()
    t.ink.withAlphaComponent(0.1).setFill()
    NSRect(x: r.minX, y: r.minY + 28, width: r.width, height: 1).fill()
    leftText(String(format: T("%d items"), 12), size: 11, weight: .regular, color: secondary, x: r.minX + 12, baselineY: r.minY + 10)
    let clear = T("Clear")
    leftText(clear, size: 11, weight: .regular, color: secondary, x: r.maxX - 12 - textWidth(clear, size: 11, weight: .regular),
             baselineY: r.minY + 10)
    ctx.restoreGState()
}

// MARK: Bento

/// A glass badge like the app's own buttons: frosted glass over a little
/// of the line's wallpaper, its edge lit from above, the symbol on top.
func drawBadge(_ ctx: CGContext, _ t: Theme, symbol name: String, at origin: NSPoint) {
    let size: CGFloat = 76
    let r = NSRect(x: origin.x, y: origin.y, width: size, height: size)
    ctx.saveGState()
    let blob = NSBezierPath(ovalIn: r.offsetBy(dx: 14, dy: -10).insetBy(dx: 4, dy: 4))
    NSGradient(colors: t.wallpaper.map { $0.withAlphaComponent(t.name == "light" ? 1 : 0.9) })!.draw(in: blob, angle: -35)
    ctx.restoreGState()
    let path = NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22)
    ctx.saveGState(); shadow(t, 0.8, blur: 18, y: -8)
    (t.name == "light" ? color(255, 255, 255, 0.62) : color(255, 255, 255, 0.10)).setFill(); path.fill()
    ctx.restoreGState()
    ctx.saveGState()
    let rim = NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22)
    rim.append(NSBezierPath(roundedRect: r.insetBy(dx: 1.2, dy: 1.2), xRadius: 20.8, yRadius: 20.8))
    rim.windingRule = .evenOdd; rim.addClip()
    NSGradient(colors: [t.edgeTop, t.edgeBottom])!.draw(in: r, angle: -90)
    ctx.restoreGState()
    drawSymbol(name, size: 32, weight: .medium, color: t.ink, at: NSPoint(x: r.midX, y: r.midY))
}

func bento(_ t: Theme) {
    let W: CGFloat = 1200, H: CGFloat = 700, s: CGFloat = 2, gap: CGFloat = 20
    let tiles: [(String, String, String)] = [
        ("doc.on.doc", T("Click to copy."), T("Paste it anywhere, instantly.")),
        ("pencil.and.scribble", T("Hold to mark up."), T("Arrows, text, mosaic. In place.")),
        ("arrow.up.forward.app", T("Drag to share."), T("In an app, it leaves the line.")),
        ("square.and.arrow.down", T("Drop to hang."), T("Any image can join the line.")),
        ("viewfinder", T("\u{2303}\u{2325}A to capture."), T("Windows and buttons light up.")),
        ("xmark.circle", T("Let it go."), T("The cross or the Trash. That\u{2019}s it.")),
    ]
    let rep = makeBitmap(W, H, scale: s)
    draw(rep, scale: s) { ctx in
        t.page.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        let tw = (W - gap * 4) / 3, th = (H - gap * 3) / 2
        for (i, tile) in tiles.enumerated() {
            let col = CGFloat(i % 3), row = CGFloat(1 - i / 3)
            let r = NSRect(x: gap + col * (tw + gap), y: gap + row * (th + gap), width: tw, height: th)
            t.tile.setFill()
            NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28).fill()
            drawBadge(ctx, t, symbol: tile.0, at: NSPoint(x: r.minX + 34, y: r.maxY - 38 - 76))
            leftText(tile.1, size: 29, weight: .semibold, color: t.tileInk, tracking: -0.6, x: r.minX + 34, baselineY: r.minY + 74, maxWidth: r.width - 60)
            leftText(tile.2, size: 17, weight: .regular, color: t.secondaryInk, tracking: -0.1, x: r.minX + 34, baselineY: r.minY + 40, maxWidth: r.width - 60)
        }
    }
    savePNG(rep, "\(outDir)/bento-\(t.name).png")
}

for t in [light, dark] {
    hero(t)
    bento(t)
    demo(t)
    captureLoop(t)
    markupLoop(t)
    notesLoop(t)
}
