// The 30 second promo film, 1920 × 1080 at 60 frames a second.
// It reuses everything make-readme-art.swift draws (the line, the glass
// photos, the tags, the note clip, the screenshot overlay), so it is not run
// on its own: scripts/make-promo-video.sh glues the two together.
//
//   0–4    the name, and the line coming down
//   4–8.5  the reveal: the line slides down, a tag opens, a click copies
//   8.5–14 ⌃⌥A: windows and a button light up, a drag selects, Done hangs it
//   14–18.5 marking up in place
//   18.5–23.5 a photo dragged off the line into a chat
//   23.5–27 the clip of copied text
//   27–30  the name again, and how to get it
//
// THEME=dark renders the dark one. STILLS=1.5,6.2 also saves those moments
// as PNGs, and STILLS_ONLY=1 saves just those.
import AVFoundation
import CoreVideo

// MARK: Film words

func L(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }

let theme = ProcessInfo.processInfo.environment["THEME"] == "dark" ? dark : light
let VW: CGFloat = 1280, VH: CGFloat = 720, VScale: CGFloat = 1.5
let fps = 60
let shots: [(start: CGFloat, end: CGFloat)] = [(0, 4), (4, 8.5), (8.5, 14), (14, 18.5), (18.5, 23.5), (23.5, 27), (27, 30)]
let duration: CGFloat = 30

let captions: [(String, String)] = [
    ("", ""),
    (L("看不见，却够得着。", "Out of sight, within reach."),
     L("指针停在菜单栏中间，绳子就滑下来。单击即复制。", "Rest the pointer mid menu bar and the line slides down. Click to copy.")),
    (L("\u{2303}\u{2325}A，指哪截哪。", "\u{2303}\u{2325}A to capture."),
     L("窗口和按钮自动亮起，单击或拖选都行。", "Windows and buttons light up. Click one, or drag.")),
    (L("截完，原地标注。", "Mark it up in place."),
     L("箭头、形状、文字、马赛克，完成就挂上绳。", "Arrows, shapes, text, mosaic. Done hangs it on the line.")),
    (L("拖出分享。", "Drag to share."),
     L("拖进 App 就发出去，绳上随即收走。", "Drop it in an app to send it. It leaves the line.")),
    (L("复制的文字，收在绳尾。", "Copied text, clipped to the end."),
     L("搜索、方向键选中、回车复制。", "Search, pick with the arrows, Return to copy.")),
    ("", ""),
]

// MARK: The card the line hangs in

/// Every shot draws in a 960 × 460 scene, shown as a card under the caption.
let SW: CGFloat = 960, SH: CGFloat = 460
let cardK: CGFloat = 1.15
let card = NSRect(x: (VW - SW * cardK) / 2, y: 30, width: SW * cardK, height: SH * cardK)
let lineTop = SH - 26 - 20

func lineY(_ x: CGFloat, reveal: CGFloat = 1) -> CGFloat {
    let f = x / SW
    return lineTop + (1 - reveal) * 260 - 4 * 22 * f * (1 - f)
}

/// A photo on the line, with what its tag says when it opens.
struct VPhoto {
    var f: Frame
    var label: String
    var open: CGFloat = 0
    var pressed: CGFloat = 0
    var copied: CGFloat = 0
}

let homeFrames = [Frame(x: 215, w: 210, h: 146, tilt: 2.5, kind: 0),
                  Frame(x: 445, w: 230, h: 158, tilt: -1.2, kind: 1),
                  Frame(x: 670, w: 190, h: 136, tilt: 3, kind: 2)]
let homeLabels = ["Safari \u{2014} Clipline", L("照片 \u{2014} 日落", "Photos \u{2014} Sunset"), "\(T("Charts")) \u{2014} Q3"]
func homePhotos() -> [VPhoto] { zip(homeFrames, homeLabels).map { VPhoto(f: $0, label: $1) } }

/// The line coming down with a soft spring, the photos swinging as it lands.
func spring(_ l: CGFloat, _ at: CGFloat, amp: CGFloat = 9) -> (reveal: CGFloat, swing: [CGFloat]) {
    guard l >= at else { return (0, [0, 0, 0]) }
    let d = l - at
    let swing = (0..<3).map { k -> CGFloat in
        let dk = max(0, d - 0.05 * CGFloat(k))
        return amp * exp(-2.6 * dk) * sin(8.5 * dk + 0.6) * (k % 2 == 0 ? 1 : -1)
    }
    return (1 - exp(-7 * d) * cos(9 * d), swing)
}

/// The source tag, opening to say where the photo came from. Like drawTag,
/// but it says anything and grows open instead of jumping.
func vTag(_ ctx: CGContext, _ t: Theme, w: CGFloat, h: CGFloat, kind: Int, label: String, open: CGFloat, copied: CGFloat) {
    let anchor = NSPoint(x: -w / 2 + w * 0.62, y: -h)
    ctx.saveGState()
    ctx.translateBy(x: anchor.x, y: anchor.y)
    ctx.rotate(by: 4 * .pi / 180)
    let thread = NSBezierPath()
    thread.move(to: .zero); thread.line(to: NSPoint(x: 0, y: -14))
    thread.lineWidth = 1.1; color(140, 140, 145).setStroke(); thread.stroke()

    let icon: CGFloat = 27, pad: CGFloat = 5
    let words = copied > 0.5 ? T("Copied") : label
    let amount = copied > 0 ? 1 : easeInOut(open)
    let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let textW = NSAttributedString(string: words, attributes: [.font: font]).size().width.rounded(.up)
    let pillW = pad + icon + pad + (7 + textW + 10 - pad) * amount, pillH = icon + pad * 2
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
    if amount > 0 {
        ctx.saveGState()
        NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).addClip()
        NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: t.ink.withAlphaComponent(amount)])
            .draw(at: NSPoint(x: iconRect.maxX + 7, y: pill.midY - (font.ascender - font.descender) / 2))
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

/// drawScene, with tags that say more and photos that can leave the line.
func vScene(_ ctx: CGContext, _ t: Theme, photos: [VPhoto], reveal: CGFloat, swing: [CGFloat], noteClip: CGFloat? = 845,
            cursor: NSPoint? = nil, backdrop: ((CGContext) -> Void)? = nil, overlay: ((CGContext) -> Void)? = nil) {
    ctx.saveGState()
    let W = SW, H = SH
    let canvas = NSRect(x: 0, y: 0, width: W, height: H)
    NSBezierPath(roundedRect: canvas, xRadius: 22, yRadius: 22).addClip()

    NSGradient(colors: t.wallpaper, atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: canvas, angle: -35)
    NSGradient(colors: [t.glow, t.glow.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: W * 0.5, y: H * 0.45), radius: 0,
              toCenter: NSPoint(x: W * 0.5, y: H * 0.45), radius: W * 0.6, options: [])
    backdrop?(ctx)

    let barH: CGFloat = 26
    let top = lineY(0, reveal: reveal)
    let sag: CGFloat = 22
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

    for (i, p) in photos.enumerated() {
        let f = p.f
        let scale: CGFloat = 1 + 0.03 * easeInOut(p.open) - 0.06 * p.pressed
        ctx.saveGState()
        ctx.translateBy(x: f.x, y: lineY(f.x, reveal: reveal) + 7)
        ctx.rotate(by: (f.tilt + (i < swing.count ? swing[i] : 0)) * .pi / 180)
        ctx.scaleBy(x: scale, y: scale)
        vTag(ctx, t, w: f.w, h: f.h, kind: f.kind, label: p.label, open: p.open, copied: p.copied)
        drawGlassPhoto(ctx, t, w: f.w, h: f.h, kind: f.kind, lift: p.open > 0.5)
        ctx.restoreGState()
    }
    if let x = noteClip {
        ctx.saveGState()
        ctx.translateBy(x: x, y: lineY(x, reveal: reveal) + 7)
        ctx.rotate(by: 2 * .pi / 180 + (swing.last ?? 0) * .pi / 360)
        drawNoteClip(ctx, t)
        ctx.restoreGState()
    }
    ctx.restoreGState()

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
    if let p = cursor { drawCursor(ctx, t, at: NSPoint(x: p.x, y: min(p.y, H - 1))) }
    ctx.restoreGState()
}

func withAlpha(_ ctx: CGContext, _ alpha: CGFloat, _ body: () -> Void) {
    guard alpha > 0.001 else { return }
    if alpha >= 0.999 { body(); return }
    ctx.saveGState(); ctx.setAlpha(alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer(); ctx.restoreGState()
}

func bump(_ l: CGFloat, _ at: CGFloat) -> CGFloat {
    guard l >= at && l < at + 0.2 else { return 0 }
    return easeInOut((l - at) / 0.1) * (1 - easeInOut((l - at - 0.1) / 0.1))
}

// MARK: Shot 0, the name and the line

func heroShot(_ ctx: CGContext, _ l: CGFloat) {
    let s = spring(l, 1.2)
    vScene(ctx, theme, photos: homePhotos(), reveal: s.reveal, swing: s.swing)
}

// MARK: Shot 1, the reveal

func revealShot(_ ctx: CGContext, _ l: CGFloat) {
    var s = spring(l, 1.15)
    if l < 0.3 { s = (1 - ramp(l, 0, 0.3), [0, 0, 0]) }
    if l >= 4.05 { s.reveal = 1 - ramp(l, 4.05, 0.28) }
    var photos = homePhotos()
    photos[0].open = ramp(l, 1.95, 0.25) * (1 - ramp(l, 2.5, 0.2))
    photos[1].open = ramp(l, 2.8, 0.25) * (1 - ramp(l, 3.9, 0.2))
    photos[1].pressed = bump(l, 3.25)
    if l >= 3.4 && l < 4.0 { photos[1].copied = min(1, (l - 3.4) / 0.15) * (l > 3.8 ? max(0, 1 - (l - 3.8) / 0.2) : 1) }
    let cursor = path(l, [(0, NSPoint(x: 760, y: 90)), (1.0, NSPoint(x: 480, y: SH)), (2.0, NSPoint(x: 232, y: 322)),
                          (2.85, NSPoint(x: 457, y: 318)), (4.4, NSPoint(x: 770, y: 80))], glide: 0.5)
    vScene(ctx, theme, photos: photos, reveal: s.reveal, swing: s.swing, cursor: cursor, overlay: { ctx in
        clicked(l, [3.25], at: cursor, ctx)
    })
}

// MARK: Shot 2, the screenshot tool

func captureShot(_ ctx: CGContext, _ l: CGFloat) {
    let t = theme
    let canvas = NSRect(x: 0, y: 0, width: SW, height: SH)
    let selection = NSRect(x: Desk.sidebar.maxX + 14, y: Desk.web.minY + 102,
                           width: Desk.web.maxX - 14 - Desk.sidebar.maxX - 14, height: Desk.web.maxY - 38 - Desk.web.minY - 102)
    let bar = Toolbar()
    let barTop = NSPoint(x: selection.maxX, y: selection.minY - 8)
    let done = toolbarItem(bar, topRight: barTop, "done")
    let start = NSPoint(x: selection.minX, y: selection.maxY), end = NSPoint(x: selection.maxX, y: selection.minY)
    let size = { (r: NSRect) in "\(Int(r.width * 2)) \u{00D7} \(Int(r.height * 2))" }

    let cursor = path(l, [(0, NSPoint(x: 470, y: 250)), (0.85, NSPoint(x: 780, y: 230)), (1.3, NSPoint(x: Desk.button.maxX + 40, y: Desk.button.minY - 36)),
                          (1.75, NSPoint(x: Desk.button.maxX - 18, y: Desk.button.minY + 8)),
                          (2.05, NSPoint(x: Desk.button.maxX - 18, y: Desk.button.minY + 8)), (2.35, start)], glide: 0.4)
    let dragging = ramp(l, 2.4, 0.6)
    let dragged = NSPoint(x: lerp(start.x, end.x, dragging), y: lerp(start.y, end.y, dragging))
    let pointer = l < 2.4 ? cursor : l < 3.0 ? dragged : path(l, [(3.0, end), (3.45, done), (4.6, NSPoint(x: 760, y: 120))], glide: 0.35)

    let frozen = l >= 0.55 && l < 3.6
    var hole: NSRect? = nil, label: String? = nil
    if frozen {
        if l >= 2.4 {
            hole = NSRect(x: start.x, y: dragged.y, width: dragged.x - start.x, height: start.y - dragged.y)
            label = size(hole!)
        } else if l >= 1.75 {
            hole = Desk.button; label = "\(T("button"))   \(size(Desk.button))"
        } else if l >= 1.2 {
            hole = Desk.web; label = "Safari \u{2014} Clipline   \(size(Desk.web))"
        } else if l >= 0.75 {
            hole = Desk.chart; label = "\(T("Charts")) \u{2014} Q3   \(size(Desk.chart))"
        }
    }

    let frames = [Frame(x: 240, w: 190, h: 132, tilt: 2.5, kind: 1),
                  Frame(x: 460, w: 180, h: 128, tilt: -1.5, kind: 2),
                  Frame(x: 690, w: 220, h: 150, tilt: 2, kind: 0)]
    var photos = zip(frames, [homeLabels[1], homeLabels[2], homeLabels[0]]).map { VPhoto(f: $0, label: $1) }
    photos[2].open = ramp(l, 4.15, 0.25) * (1 - ramp(l, 4.9, 0.2))
    var s = spring(l, 3.75)
    s.swing[2] *= 14 / 9
    if l >= 5.1 { s.reveal = 1 - ramp(l, 5.1, 0.28) }

    vScene(ctx, t, photos: photos, reveal: s.reveal, swing: s.swing, noteClip: nil, cursor: pointer,
           backdrop: { ctx in drawDesktop(ctx, t) },
           overlay: { ctx in
        if frozen {
            drawFreeze(ctx, canvas: canvas, hole: hole, label: label, handles: l >= 3.0)
            if l >= 3.0 { withAlpha(ctx, ramp(l, 3.0, 0.15)) { drawToolbar(ctx, t, bar, topRight: barTop) } }
        }
        if l >= 3.6 && l < 3.8 {
            NSColor.white.withAlphaComponent(0.35 * (1 - (l - 3.6) / 0.2)).setFill(); canvas.fill()
        }
        clicked(l, [3.55], at: done, ctx)
        drawKeys(ctx, t, ["\u{2303}", "\u{2325}", "A"], center: NSPoint(x: SW / 2, y: 60),
                 alpha: min(ramp(l, 0.1, 0.15), 1 - ramp(l, 0.85, 0.2)))
    })
}

// MARK: Shot 3, marking up

func markupShot(_ ctx: CGContext, _ l: CGFloat) {
    let t = theme
    let canvas = NSRect(x: 0, y: 0, width: SW, height: SH)
    let hole = Desk.chart
    let barTop = NSPoint(x: hole.maxX, y: hole.minY - 8)
    let content = Desk.chartContent
    let bw = (content.width - 36) / 7
    let tall = NSRect(x: content.minX + 18 + 5 * bw + 3, y: content.minY + 16, width: bw - 6, height: (content.height - 42) * 0.85)
    let box = tall.insetBy(dx: -8, dy: -8)
    let arrowFrom = NSPoint(x: 690, y: 262), arrowTo = NSPoint(x: box.minX - 6, y: box.maxY - 30)
    let textAt = NSPoint(x: 646, y: 276)
    let word = T("Peak"), extra = " +32%"

    var bar = Toolbar()
    bar.custom = 6
    if l >= 0.3 { bar.tool = 0 }
    if l >= 1.35 { bar.tool = 2 }
    if l >= 2.2 { bar.tool = 4 }
    if l >= 2.95 { bar.color = 3 }
    let width = bar.custom ?? 4
    let item = { (id: String) in toolbarItem(bar, topRight: barTop, id) }

    let drag = ramp(l, 0.6, 0.5)
    let boxNow = NSRect(x: box.minX, y: lerp(box.maxY, box.minY, drag), width: box.width * drag,
                        height: box.maxY - lerp(box.maxY, box.minY, drag))
    let arrow = ramp(l, 1.55, 0.4)
    let arrowNow = lerp(arrowFrom, arrowTo, arrow)

    var pointer: NSPoint
    if l < 0.6 {
        pointer = path(l, [(0, NSPoint(x: 560, y: 250)), (0.3, item("tool0")), (0.6, NSPoint(x: box.minX, y: box.maxY))], glide: 0.28)
    } else if l < 1.1 {
        pointer = NSPoint(x: boxNow.maxX, y: boxNow.minY)
    } else if l < 1.55 {
        pointer = path(l, [(1.1, NSPoint(x: box.maxX, y: box.minY)), (1.35, item("tool2")), (1.55, arrowFrom)], glide: 0.2)
    } else if l < 1.95 {
        pointer = arrowNow
    } else {
        pointer = path(l, [(1.95, arrowTo), (2.2, item("tool4")), (2.42, NSPoint(x: textAt.x + 4, y: textAt.y + 10)),
                           (2.75, NSPoint(x: 640, y: 214)), (2.95, item("color3")), (3.8, item("done")),
                           (4.45, NSPoint(x: 560, y: 250))], glide: 0.22)
    }

    let typed1 = Int(max(0, min(CGFloat(word.count), (l - 2.45) / 0.12)))
    let typed2 = Int(max(0, min(CGFloat(extra.count), (l - 3.05) / 0.08)))
    var runs: [(String, NSColor)] = []
    if typed1 > 0 { runs.append((String(word.prefix(typed1)), markColors[0])) }
    if typed2 > 0 { runs.append((String(extra.prefix(typed2)), markColors[3])) }

    let frozen = l < 3.95
    vScene(ctx, t, photos: [], reveal: 0, swing: [0, 0, 0], noteClip: nil, cursor: pointer,
           backdrop: { ctx in drawDesktop(ctx, t) },
           overlay: { ctx in
        if frozen {
            drawFreeze(ctx, canvas: canvas, hole: hole, label: "\(Int(hole.width * 2)) \u{00D7} \(Int(hole.height * 2))", handles: true)
            ctx.saveGState(); NSBezierPath(rect: hole).addClip()
            if l >= 0.6 { drawRectMark(l < 1.1 ? boxNow : box, color: markColors[0], width: width) }
            if l >= 1.55 { drawArrowMark(from: arrowFrom, to: arrowNow, color: markColors[0], width: width) }
            if !runs.isEmpty || (l >= 2.4 && l < 3.8) {
                drawTextMark(runs, at: textAt, caret: l < 3.8 && Int(l * 2.5) % 2 == 0)
            }
            ctx.restoreGState()
            drawToolbar(ctx, t, bar, topRight: barTop)
        }
        if l >= 3.95 && l < 4.15 {
            NSColor.white.withAlphaComponent(0.35 * (1 - (l - 3.95) / 0.2)).setFill(); canvas.fill()
        }
        clicked(l, [0.3, 1.35, 2.2, 2.42, 2.95, 3.88], at: pointer, ctx)
    })
}

// MARK: Shot 4, dragging a photo into a chat

let chatOrange = color(217, 119, 87)

/// A many-pointed spark, the chat app's mark.
func drawSpark(at c: NSPoint, radius r: CGFloat, color: NSColor) {
    let rays = 10
    let lengths: [CGFloat] = [1, 0.8, 0.95, 0.75, 1, 0.85, 0.92, 0.78, 1, 0.82]
    let p = NSBezierPath()
    for i in 0..<rays {
        let a = CGFloat(i) / CGFloat(rays) * 2 * .pi + 0.2
        p.move(to: NSPoint(x: c.x + cos(a) * r * 0.12, y: c.y + sin(a) * r * 0.12))
        p.line(to: NSPoint(x: c.x + cos(a) * r * lengths[i], y: c.y + sin(a) * r * lengths[i]))
    }
    p.lineWidth = r * 0.2; p.lineCapStyle = .round
    color.setStroke(); p.stroke()
}

enum Chat {
    static let window = NSRect(x: 150, y: 22, width: 660, height: 318)
    static let main = NSRect(x: window.minX + 150, y: window.minY, width: window.width - 150, height: window.height - 28)
    static let composer = NSRect(x: main.minX + 40, y: main.minY + 18, width: main.width - 80, height: 96)
    static let thumb = NSRect(x: composer.minX + 12, y: composer.maxY - 12 - 42, width: 60, height: 42)
}

func drawChatWindow(_ ctx: CGContext, _ t: Theme, highlight: CGFloat, attached: CGFloat, typed: String, caret: Bool) {
    let lightUI = t.name == "light"
    let r = Chat.window
    let bg = lightUI ? color(250, 249, 245) : color(38, 38, 36)
    let side = lightUI ? color(243, 241, 235) : color(31, 30, 29)
    let ink = lightUI ? color(40, 38, 34) : color(240, 238, 232)
    let faint = lightUI ? color(216, 212, 202) : color(78, 76, 72)
    let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
    ctx.saveGState(); shadow(t, 1, blur: 24, y: -10); bg.setFill(); path.fill(); ctx.restoreGState()
    ctx.saveGState(); path.addClip()

    side.setFill(); NSRect(x: r.minX, y: r.minY, width: 150, height: r.height).fill()
    for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 12 + CGFloat(i) * 17, y: r.maxY - 19.5, width: 11, height: 11)).fill()
    }
    // The sidebar: a new chat, then recent ones.
    let newChat = NSRect(x: r.minX + 10, y: r.maxY - 62, width: 130, height: 24)
    chatOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: newChat.minX + 6, y: newChat.midY - 8, width: 16, height: 16)).fill()
    drawSymbol("plus", size: 9, weight: .bold, color: .white, at: NSPoint(x: newChat.minX + 14, y: newChat.midY))
    faint.setFill()
    NSBezierPath(roundedRect: NSRect(x: newChat.minX + 30, y: newChat.midY - 3, width: 56, height: 6), xRadius: 3, yRadius: 3).fill()
    for (k, w) in [CGFloat(84), 66, 92, 58, 76, 70].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: r.minX + 18, y: r.maxY - 100 - CGFloat(k) * 26, width: w, height: 6), xRadius: 3, yRadius: 3).fill()
    }

    // The greeting.
    let m = Chat.main
    var font = NSFont.systemFont(ofSize: 21, weight: .regular)
    if let d = font.fontDescriptor.withDesign(.serif) { font = NSFont(descriptor: d, size: 21) ?? font }
    let hello = NSAttributedString(string: L("有什么可以帮你的？", "How can I help you today?"),
                                   attributes: [.font: font, .foregroundColor: ink])
    let total = 26 + 10 + hello.size().width
    let x0 = m.midX - total / 2, baseline = m.minY + 150
    drawSpark(at: NSPoint(x: x0 + 13, y: baseline + 7), radius: 13, color: chatOrange)
    hello.draw(at: NSPoint(x: x0 + 36, y: baseline + font.descender))

    // The composer, lit while a photo is over it.
    let c = Chat.composer
    let box = NSBezierPath(roundedRect: c, xRadius: 14, yRadius: 14)
    ctx.saveGState(); shadow(t, 0.35, blur: 10, y: -3)
    (lightUI ? NSColor.white : color(48, 48, 46)).setFill(); box.fill()
    ctx.restoreGState()
    if highlight > 0 { chatOrange.withAlphaComponent(0.07 * highlight).setFill(); box.fill() }
    box.lineWidth = 1 + highlight
    (highlight > 0 ? chatOrange.withAlphaComponent(0.25 + 0.65 * highlight) : faint).setStroke(); box.stroke()

    if attached > 0 {
        withAlpha(ctx, attached) {
            let th = Chat.thumb
            let s = 0.8 + 0.2 * attached
            let tr = NSRect(x: th.minX, y: th.maxY - th.height * s, width: th.width * s, height: th.height * s)
            ctx.saveGState()
            NSBezierPath(roundedRect: tr, xRadius: 7, yRadius: 7).addClip()
            // Drawn at the photo's own size and scaled down, so the whole chart shows.
            let full = homeFrames[2]
            let k = max(tr.width / full.w, tr.height / full.h)
            ctx.translateBy(x: tr.midX - full.w * k / 2, y: tr.midY - full.h * k / 2)
            ctx.scaleBy(x: k, y: k)
            drawContent(2, NSRect(x: 0, y: 0, width: full.w, height: full.h))
            ctx.restoreGState()
            let edge = NSBezierPath(roundedRect: tr, xRadius: 7, yRadius: 7)
            edge.lineWidth = 1; faint.setStroke(); edge.stroke()
        }
    }
    let textFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
    let textAt = NSPoint(x: c.minX + 14, y: c.minY + 18)
    if typed.isEmpty {
        NSAttributedString(string: L("回复 Claude…", "Reply to Claude…"),
                           attributes: [.font: textFont, .foregroundColor: t.secondaryInk.withAlphaComponent(0.8)])
            .draw(at: NSPoint(x: textAt.x, y: textAt.y + textFont.descender))
    } else {
        NSAttributedString(string: typed, attributes: [.font: textFont, .foregroundColor: ink])
            .draw(at: NSPoint(x: textAt.x, y: textAt.y + textFont.descender))
    }
    if caret {
        let w = typed.isEmpty ? 0 : NSAttributedString(string: typed, attributes: [.font: textFont]).size().width
        ink.setFill(); NSRect(x: textAt.x + w + 1, y: textAt.y - 3, width: 1.3, height: 16).fill()
    }
    let send = NSRect(x: c.maxX - 12 - 28, y: c.minY + 10, width: 28, height: 28)
    chatOrange.withAlphaComponent(typed.isEmpty ? 0.45 : 1).setFill()
    NSBezierPath(roundedRect: send, xRadius: 8, yRadius: 8).fill()
    drawSymbol("arrow.up", size: 12, weight: .bold, color: .white, at: NSPoint(x: send.midX, y: send.midY))
    ctx.restoreGState()
}

func dragShot(_ ctx: CGContext, _ l: CGFloat) {
    let t = theme
    let picked = homeFrames[2]
    let grab = NSPoint(x: picked.x, y: lineY(picked.x) + 7 - picked.h / 2)
    let drop = NSPoint(x: Chat.composer.midX - 20, y: Chat.composer.midY + 6)
    let typeAt = NSPoint(x: Chat.composer.minX + 120, y: Chat.composer.minY + 30)

    // Down comes the line, the pointer takes the chart and carries it over.
    var s = spring(l, 0.15)
    let lifted = l >= 1.3
    if lifted {
        let d = l - 1.3
        for k in 0..<2 { s.swing[k] += 4 * exp(-3 * d) * sin(9 * d) * (k == 0 ? 1 : -1) }
    }
    if l >= 3.3 { s.reveal = 1 - ramp(l, 3.3, 0.28) }

    var photos = homePhotos()
    photos[2].open = ramp(l, 0.75, 0.25) * (1 - ramp(l, 1.2, 0.12))
    photos[2].pressed = bump(l, 1.12)
    if lifted { photos.removeLast() }

    let carry = ramp(l, 1.3, 1.25)
    var pointer: NSPoint
    if l < 1.3 {
        pointer = path(l, [(0, NSPoint(x: 760, y: 110)), (0.85, NSPoint(x: grab.x + 6, y: grab.y + 4))], glide: 0.55)
    } else if l < 2.6 {
        pointer = lerp(NSPoint(x: grab.x + 6, y: grab.y + 4), drop, carry)
        pointer.x += 40 * sin(.pi * carry)
    } else {
        pointer = path(l, [(2.6, drop), (2.95, typeAt), (3.35, NSPoint(x: Chat.composer.maxX - 150, y: Chat.composer.maxY + 26)), (4.7, NSPoint(x: 770, y: 150))], glide: 0.3)
    }
    let over = l >= 2.15 && l < 2.75 ? min(ramp(l, 2.15, 0.15), 1 - ramp(l, 2.6, 0.15)) : 0
    let landed = ramp(l, 2.62, 0.22)
    let message = L("这季度哪个月是峰值？", "Which month peaked?")
    let typed = String(message.prefix(Int(max(0, min(CGFloat(message.count), (l - 3.05) / 0.09)))))

    vScene(ctx, t, photos: photos, reveal: s.reveal, swing: s.swing, cursor: pointer,
           backdrop: { ctx in
        drawChatWindow(ctx, t, highlight: over, attached: landed, typed: typed, caret: l >= 2.95 && Int(l * 2.5) % 2 == 0)
    }, overlay: { ctx in
        // The photo in hand: smaller as it travels, gone into the composer on release.
        guard lifted, landed < 1 else { return }
        let scale = lerp(1.04, 0.5, carry) * (1 - 0.6 * landed)
        let at = l < 2.6 ? pointer : lerp(drop, NSPoint(x: Chat.thumb.midX, y: Chat.thumb.midY), landed)
        withAlpha(ctx, 1 - landed) {
            ctx.saveGState()
            ctx.translateBy(x: at.x - 6 * scale, y: at.y - 4 * scale + picked.h * scale / 2)
            ctx.rotate(by: lerp(picked.tilt, -4, carry) * .pi / 180)
            ctx.scaleBy(x: scale, y: scale)
            drawGlassPhoto(ctx, t, w: picked.w, h: picked.h, kind: picked.kind, lift: true)
            ctx.restoreGState()
        }
        // The green plus that says it can be dropped here.
        if over > 0 {
            withAlpha(ctx, over) {
                let c = NSPoint(x: pointer.x + 16, y: pointer.y - 30)
                color(52, 199, 89).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)).fill()
                drawSymbol("plus", size: 10, weight: .bold, color: .white, at: c)
            }
        }
    })
}

// MARK: Shot 5, the clip of copied text

func notesShot(_ ctx: CGContext, _ l: CGFloat) {
    let t = theme
    let clipX: CGFloat = 845
    let clipY = lineY(clipX) + 7
    let clipPoint = NSPoint(x: clipX + 4, y: clipY - 60)
    let panel = NSRect(x: SW - 16 - 300, y: clipY - 105 - 8 - 280, width: 300, height: 280)
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

    let s = spring(l, 0.05)
    let cursor = path(l, [(0, NSPoint(x: 560, y: 160)), (0.6, clipPoint), (1.25, NSPoint(x: 560, y: 250))], glide: 0.45)
    let typed = Int(max(0, min(CGFloat(query.count), (l - 0.95) / 0.13)))
    let q = String(query.prefix(typed))
    let results = q.isEmpty ? snippets : snippets.filter { $0.text.localizedCaseInsensitiveContains(q) }
    let selection = l >= 1.85 ? 1 : 0
    let copied = l >= 2.35 ? selection : nil
    let open = l >= 0.7

    vScene(ctx, t, photos: homePhotos(), reveal: s.reveal, swing: s.swing, cursor: cursor, overlay: { ctx in
        clicked(l, [0.65], at: clipPoint, ctx)
        if open {
            withAlpha(ctx, ramp(l, 0.7, 0.15)) {
                drawNotesPanel(ctx, t, panel, query: q, caret: Int(l * 2.5) % 2 == 0,
                               rows: results, selection: selection, copied: copied, rowRect: rowRect)
            }
        }
        drawKeys(ctx, t, ["\u{2193}"], center: NSPoint(x: SW / 2 - 60, y: 60),
                 alpha: min(ramp(l, 1.75, 0.1), 1 - ramp(l, 2.15, 0.12)))
        drawKeys(ctx, t, ["\u{21A9}"], center: NSPoint(x: SW / 2 - 60, y: 60),
                 alpha: min(ramp(l, 2.25, 0.1), 1 - ramp(l, 2.9, 0.15)))
    })
}

// MARK: Words over the card

/// The icon and the name side by side, centered, as in the hero.
func drawBrand(nameSize: CGFloat, baseline: CGFloat) {
    let k = nameSize / 84
    let icon = NSImage(contentsOfFile: "docs/images/icon.png")!
    let iconSize = 118 * k, gap = 16 * k
    let nameW = NSAttributedString(string: "Clipline", attributes: [.font: NSFont.systemFont(ofSize: nameSize, weight: .semibold),
                                                                   .kern: -2.4 * k]).size().width
    let left = (VW - (iconSize * 0.8 + gap + nameW)) / 2
    icon.draw(in: NSRect(x: left - iconSize * 0.1, y: baseline - 22 * k, width: iconSize, height: iconSize),
              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
              hints: [.interpolation: NSImageInterpolation.high.rawValue])
    text("Clipline", size: nameSize, weight: .semibold, color: theme.ink, tracking: -2.4 * k,
         centerX: left + iconSize * 0.8 + gap + nameW / 2, baselineY: baseline)
}

func drawCaption(_ ctx: CGContext, _ i: Int, alpha: CGFloat, rise: CGFloat) {
    withAlpha(ctx, alpha) {
        ctx.saveGState(); ctx.translateBy(x: 0, y: -rise)
        if i == 0 {
            drawBrand(nameSize: 62, baseline: 628)
            text(T("Screenshots and snippets, all on one line."), size: language == "en" ? 24 : 22, weight: .regular,
                 color: theme.secondaryInk, tracking: language == "en" ? -0.3 : 1, centerX: VW / 2, baselineY: 586)
        } else {
            let (title, sub) = captions[i]
            text(title, size: 40, weight: .semibold, color: theme.ink, tracking: language == "en" ? -0.8 : 0.5,
                 centerX: VW / 2, baselineY: 630)
            text(sub, size: 20, weight: .regular, color: theme.secondaryInk, tracking: language == "en" ? -0.2 : 0.5,
                 centerX: VW / 2, baselineY: 590)
        }
        ctx.restoreGState()
    }
}

func drawEnding(_ ctx: CGContext, alpha: CGFloat, rise: CGFloat) {
    withAlpha(ctx, alpha) {
        ctx.saveGState(); ctx.translateBy(x: 0, y: -rise)
        drawBrand(nameSize: 92, baseline: 420)
        text(T("Screenshots and snippets, all on one line."), size: language == "en" ? 30 : 28, weight: .regular,
             color: theme.secondaryInk, tracking: language == "en" ? -0.4 : 1, centerX: VW / 2, baselineY: 352)
        text(L("免费开源 · 不联网 · macOS 14 及以上", "Free and open source · No network · macOS 14 and later"),
             size: 19, weight: .regular, color: theme.secondaryInk, tracking: 0.3, centerX: VW / 2, baselineY: 298)
        let command = NSAttributedString(string: "brew install --cask ffkiyo7/tap/clipline", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium), .foregroundColor: theme.ink])
        let size = command.size()
        let pill = NSRect(x: (VW - size.width - 44) / 2, y: 206, width: size.width + 44, height: 48)
        theme.tile.setFill(); NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
        command.draw(at: NSPoint(x: pill.minX + 22, y: pill.midY - size.height / 2))
        ctx.restoreGState()
    }
}

// MARK: A frame of the film

let shotBodies: [(CGContext, CGFloat) -> Void] = [heroShot, revealShot, captureShot, markupShot, dragShot, notesShot]

func drawCard(_ ctx: CGContext, alpha: CGFloat, scale: CGFloat, _ body: (CGContext) -> Void) {
    withAlpha(ctx, alpha) {
        ctx.saveGState()
        ctx.translateBy(x: card.midX, y: card.midY); ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -card.midX, y: -card.midY)
        ctx.saveGState(); shadow(theme, 0.6, blur: 40, y: -18)
        theme.page.setFill(); NSBezierPath(roundedRect: card, xRadius: 22 * cardK, yRadius: 22 * cardK).fill()
        ctx.restoreGState()
        ctx.translateBy(x: card.minX, y: card.minY); ctx.scaleBy(x: cardK, y: cardK)
        body(ctx)
        ctx.restoreGState()
    }
}

func renderFrame(_ ctx: CGContext, _ time: CGFloat) {
    theme.page.setFill(); NSRect(x: 0, y: 0, width: VW, height: VH).fill()
    let i = shots.lastIndex { time >= $0.start } ?? 0
    let l = time - shots[i].start

    for j in max(0, i - 1)...i where j < 6 {
        let shot = shots[j]
        let into = j == 0 ? ramp(time, 0.1, 0.6) : ramp(time, shot.start + 0.1, 0.35)
        let out = 1 - ramp(time, shot.end - 0.22, 0.22)
        drawCaption(ctx, j, alpha: into * out, rise: (1 - into) * 12)
    }

    switch i {
    case 0:
        let appear = ramp(l, 0.45, 0.6)
        drawCard(ctx, alpha: appear, scale: 0.96 + 0.04 * appear) { shotBodies[0]($0, l) }
    case 1...5:
        drawCard(ctx, alpha: 1, scale: 1) { ctx in
            if l < 0.3 {
                shotBodies[i - 1](ctx, shots[i - 1].end - shots[i - 1].start)
                withAlpha(ctx, ramp(l, 0, 0.3)) { shotBodies[i](ctx, l) }
            } else {
                shotBodies[i](ctx, l)
            }
        }
    default:
        let gone = ramp(l, 0, 0.45)
        drawCard(ctx, alpha: 1 - gone, scale: 1 - 0.03 * gone) { shotBodies[5]($0, shots[5].end - shots[5].start + l) }
        let into = ramp(l, 0.3, 0.6)
        drawEnding(ctx, alpha: into, rise: (1 - into) * 14)
    }
}

// MARK: Writing it out

let env = ProcessInfo.processInfo.environment
let name = "clipline-promo-\(language)-\(theme.name)"

for still in (env["STILLS"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
    let rep = makeBitmap(VW, VH, scale: VScale)
    draw(rep, scale: VScale) { ctx in renderFrame(ctx, CGFloat(still)) }
    savePNG(rep, "\(outDir)/\(name)-\(String(format: "%05.2f", still)).png")
}

if env["STILLS_ONLY"] != "1" {
    let pw = Int(VW * VScale), ph = Int(VH * VScale)
    let url = URL(fileURLWithPath: "\(outDir)/\(name).mp4")
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: pw, AVVideoHeightKey: ph,
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000,
                                          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                          AVVideoExpectedSourceFrameRateKey: fps,
                                          AVVideoMaxKeyFrameIntervalKey: fps],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: pw, kCVPixelBufferHeightKey as String: ph,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let count = Int(duration) * fps
    for i in 0..<count {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let cg = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: pw, height: ph, bitsPerComponent: 8,
                           bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        cg.scaleBy(x: VScale, y: VScale)
        renderFrame(cg, CGFloat(i) / CGFloat(fps))
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
        if i % fps == 0 { print("\(i / fps) s") }
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    finished.wait()
    if writer.status != .completed { fatalError("Writing failed: \(String(describing: writer.error))") }
    print(url.path)
}
