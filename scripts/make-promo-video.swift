// The 30 second promo film, 1920 × 1080 at 60 frames a second.
// It reuses everything make-readme-art.swift draws (the line, the glass
// photos, the tags, the note clip, the screenshot overlay), so it is not run
// on its own: scripts/make-promo-video.sh glues the two together.
//
//   0–3.5  the name, and the line coming down
//   3.5–8  the reveal: the line slides down, a tag opens, a click copies
//   8–13.5 ⌃⌥A: windows and a button light up, a drag selects, Done hangs it
//   13.5–19 marking up in place, played a little slower than written
//   19–24  a photo dragged off the line into Claude Code
//   24–27.5 the clip of copied text
//   27.5–30 the name again, and how to get it
//
// THEME=dark renders the dark one. STILLS=1.5,6.2 also saves those moments
// as PNGs, and STILLS_ONLY=1 saves just those.
import AVFoundation
import CoreVideo

// MARK: Film words

func L(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }

let theme: Theme = {
    let t = ProcessInfo.processInfo.environment["THEME"] == "dark" ? dark : light
    // PAGE=r,g,b swaps the colour behind the card and the ending, to try others.
    guard let v = ProcessInfo.processInfo.environment["PAGE"]?.split(separator: ",").compactMap({ Double($0) }), v.count == 3 else { return t }
    return Theme(name: t.name, page: color(CGFloat(v[0]), CGFloat(v[1]), CGFloat(v[2])), ink: t.ink, secondaryInk: t.secondaryInk,
                 wallpaper: t.wallpaper, glow: t.glow, menuBar: t.menuBar, menuInk: t.menuInk, line: t.line,
                 glassFill: t.glassFill, edgeTop: t.edgeTop, edgeBottom: t.edgeBottom, shadow: t.shadow,
                 tile: t.tile, tileInk: t.tileInk)
}()
let VW: CGFloat = 1280, VH: CGFloat = 720, VScale: CGFloat = 1.5
let fps = 60
let shots: [(start: CGFloat, end: CGFloat)] = [(0, 3.5), (3.5, 8), (8, 13.5), (13.5, 19), (19, 24), (24, 27.5), (27.5, 30)]
let duration: CGFloat = 30

let captions: [(String, String)] = [
    ("", ""),
    (L("看不见，却够得着。", "Out of sight, within reach."),
     L("指针停在菜单栏中间，绳子就滑下来。单击即复制。", "Rest the pointer mid menu bar and the line slides down. Click to copy.")),
    (L("截图，指哪截哪。", "Capture exactly what you point at."),
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

// MARK: Shot 4, dragging a photo into Claude Code

/// The Claude desktop app on its Code view, laid out after a real window:
/// the sidebar (search, places, pinned projects, sessions), the session
/// title, a transcript in a centred column, and the prompt box with the
/// model row under it. Every word is a bar.
enum Chat {
    static let window = NSRect(x: 120, y: 12, width: 720, height: 404)
    static let sideW: CGFloat = 124
    static let main = NSRect(x: window.minX + sideW, y: window.minY, width: window.width - sideW, height: window.height)
    static let column = NSRect(x: main.minX + main.width * 0.15, y: main.minY, width: main.width * 0.7, height: main.height)
    /// The prompt box with a photo in it; it is `closedH` tall without one.
    static let composer = NSRect(x: column.minX - 4, y: main.minY + 26, width: column.width + 8, height: 74)
    static let closedH: CGFloat = 30
    static let thumb = NSRect(x: composer.minX + 9, y: composer.maxY - 9 - 34, width: 50, height: 34)
}

func drawChatWindow(_ ctx: CGContext, _ t: Theme, highlight: CGFloat, attached: CGFloat, typed: String, caret: Bool) {
    let lightUI = t.name == "light"
    let r = Chat.window
    let bg = lightUI ? color(250, 249, 247) : color(31, 31, 31)
    let side = lightUI ? color(244, 243, 240) : color(27, 27, 27)
    let raised = lightUI ? color(236, 234, 229) : color(47, 47, 47)
    let field = lightUI ? NSColor.white : color(38, 38, 38)
    let ink = lightUI ? color(40, 38, 34) : color(232, 232, 230)
    let text = lightUI ? color(160, 157, 150) : color(150, 150, 148)
    let faint = lightUI ? color(205, 202, 196) : color(92, 92, 90)
    let hair = lightUI ? color(226, 223, 216) : color(58, 58, 58)
    let code = lightUI ? color(200, 90, 80) : color(226, 112, 104)
    let bar = { (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, c: NSColor) in
        c.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
    let box = { (rect: NSRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?) in
        let p = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if let f = fill { f.setFill(); p.fill() }
        if let s = stroke { p.lineWidth = 0.8; s.setStroke(); p.stroke() }
    }

    let frame = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
    ctx.saveGState(); shadow(t, 1, blur: 26, y: -10); bg.setFill(); frame.fill(); ctx.restoreGState()
    ctx.saveGState(); frame.addClip()

    // The sidebar.
    side.setFill(); NSRect(x: r.minX, y: r.minY, width: Chat.sideW, height: r.height).fill()
    hair.setFill(); NSRect(x: r.minX + Chat.sideW, y: r.minY, width: 0.8, height: r.height).fill()
    let top = r.maxY - 12
    for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 9 + CGFloat(i) * 12, y: top - 4, width: 8, height: 8)).fill()
    }
    let toggle = NSRect(x: r.minX + 48, y: top - 6, width: 32, height: 12)
    box(toggle, 4, raised.withAlphaComponent(0.5), nil)
    box(NSRect(x: toggle.midX, y: toggle.minY + 1, width: toggle.width / 2 - 1, height: toggle.height - 2), 3.5, raised, nil)
    bar(toggle.minX + 5, toggle.midY - 1.5, 6, 3, text)
    bar(toggle.midX + 5, toggle.midY - 1.5, 6, 3, ink)

    let search = NSRect(x: r.minX + 6, y: r.maxY - 40, width: Chat.sideW - 12, height: 13)
    box(search, 4, field, hair)
    bar(search.minX + 5, search.midY - 2, 4, 4, text)
    bar(search.minX + 13, search.midY - 1.75, 22, 3.5, text)

    var y = r.maxY - 55
    for w in [CGFloat(16), 30, 30, 34, 20] {
        box(NSRect(x: r.minX + 9, y: y - 2.5, width: 5, height: 5), 1.2, nil, text)
        bar(r.minX + 20, y - 1.75, w, 3.5, ink.withAlphaComponent(0.8))
        y -= 13
    }
    y -= 8
    bar(r.minX + 9, y - 1.5, 20, 3, text)
    y -= 13
    for (w, c) in [(CGFloat(26), color(240, 140, 60)), (30, color(232, 72, 104)), (32, color(236, 150, 50))] {
        box(NSRect(x: r.minX + 9, y: y - 3, width: 6, height: 6), 1.5, c.withAlphaComponent(0.35), c)
        bar(r.minX + 20, y - 1.75, w, 3.5, ink.withAlphaComponent(0.8))
        y -= 13.5
    }
    for (header, rows, selected) in [(CGFloat(32), 0, -1), (24, 2, 1)] {
        y -= 8
        bar(r.minX + 9, y - 1.5, header, 3, text)
        bar(r.minX + Chat.sideW - 14, y - 2, 4, 4, text)
        y -= 13
        for k in 0..<rows {
            if k == selected { box(NSRect(x: r.minX + 4, y: y - 6, width: Chat.sideW - 8, height: 12), 4, raised, nil) }
            bar(r.minX + 11, y - 1, 2, 2, text)
            bar(r.minX + 20, y - 1.75, [CGFloat(54), 62][k], 3.5, ink.withAlphaComponent(k == selected ? 0.95 : 0.75))
            y -= 13.5
        }
    }
    y -= 8
    bar(r.minX + 9, y - 1.5, 22, 3, text)
    bar(r.minX + 9, r.minY + 10, 8, 8, faint)
    bar(r.minX + 21, r.minY + 12.25, 26, 3.5, ink.withAlphaComponent(0.8))
    bar(r.minX + Chat.sideW - 15, r.minY + 11, 6, 6, text)

    // The session title, its folder, and the window's own buttons.
    let m = Chat.main
    box(NSRect(x: m.minX + 9, y: top - 4, width: 8, height: 8), 1.5, nil, ink.withAlphaComponent(0.8))
    bar(m.minX + 22, top - 2, 70, 4, ink)
    bar(m.minX + 96, top - 1, 4, 2, text)
    box(NSRect(x: m.minX + 106, y: top - 5, width: 34, height: 10), 3, raised.withAlphaComponent(0.7), nil)
    bar(m.minX + 110, top - 1.5, 26, 3, text)
    for k in 0..<2 { box(NSRect(x: m.maxX - 18 - CGFloat(k) * 16, y: top - 3.5, width: 7, height: 7), 1.5, nil, text) }

    // The transcript, cut off above the prompt box.
    let col = Chat.column
    ctx.saveGState()
    NSRect(x: m.minX, y: Chat.composer.minY + Chat.closedH + 10, width: m.width, height: r.maxY - 24 - Chat.composer.minY - Chat.closedH - 10).clip()
    /// A line of prose: bars, with inline code chips at the given spots.
    func prose(_ w: CGFloat, chips: [CGFloat] = [], strong: Bool = false) {
        var x = col.minX
        let end = col.minX + col.width * w
        for c in chips + [1] {
            let stop = min(end, col.minX + col.width * c)
            if stop - x > 6 { bar(x, y - 1.75, stop - x - 4, 3.5, strong ? ink : text) }
            x = stop
            if c < 1 && x < end {
                box(NSRect(x: x, y: y - 4, width: 34, height: 8), 2, raised.withAlphaComponent(0.8), hair)
                bar(x + 3, y - 1.5, 28, 3, code)
                x += 38
            }
        }
        y -= 10
    }
    y = r.maxY - 34
    prose(0.9, chips: [0.3, 0.5]); prose(0.94, chips: [0.2]); prose(0.5)
    y -= 12
    let ask = NSRect(x: col.maxX - col.width * 0.62, y: y - 9, width: col.width * 0.62, height: 18)
    box(ask, 6, raised, nil)
    bar(ask.minX + 8, ask.midY - 1.75, ask.width - 16, 3.5, ink.withAlphaComponent(0.85))
    y = ask.minY - 18
    prose(0.88); prose(0.12)
    y -= 6
    let block = NSRect(x: col.minX - 2, y: y - 9, width: col.width * 0.82, height: 18)
    box(block, 4, field, hair)
    bar(block.minX + 8, block.midY - 1.5, block.width - 30, 3, ink.withAlphaComponent(0.7))
    box(NSRect(x: block.maxX - 14, y: block.midY - 3, width: 6, height: 6), 1.2, nil, text)
    y = block.minY - 14
    prose(0.92, chips: [0.36, 0.62]); prose(0.4)
    y -= 6
    prose(0.16, strong: true)
    y -= 2
    for w in [CGFloat(0.9), 0.62, 0.7] {
        bar(col.minX + 8, y - 1.25, 2.5, 2.5, text)
        bar(col.minX + 18, y - 1.75, col.width * w - 18, 3.5, text)
        y -= 10
    }
    y -= 6
    prose(0.18, strong: true)
    y -= 2
    for (w, chip) in [(CGFloat(0.94), true), (0.76, true), (0.6, true)] {
        bar(col.minX + 8, y - 1.25, 2.5, 2.5, text)
        if chip {
            box(NSRect(x: col.minX + 18, y: y - 4, width: 40, height: 8), 2, raised.withAlphaComponent(0.8), hair)
            bar(col.minX + 21, y - 1.5, 34, 3, code)
        }
        bar(col.minX + 64, y - 1.75, col.width * w - 64, 3.5, text)
        y -= 10
    }
    ctx.restoreGState()

    // The prompt box: one line until a photo lands, then it opens to hold it.
    let open = easeInOut(attached)
    let full = Chat.composer
    let c = NSRect(x: full.minX, y: full.minY, width: full.width, height: Chat.closedH + (full.height - Chat.closedH) * open)
    box(c, 9, field, hair)
    let lit = lightUI ? color(70, 130, 240) : color(120, 165, 255)
    if highlight > 0 {
        let p = NSBezierPath(roundedRect: c, xRadius: 9, yRadius: 9)
        lit.withAlphaComponent(0.08 * highlight).setFill(); p.fill()
        p.lineWidth = 1.5; lit.withAlphaComponent(0.85 * highlight).setStroke(); p.stroke()
    }
    if attached > 0 {
        withAlpha(ctx, attached) {
            let th = NSRect(x: Chat.thumb.minX, y: c.maxY - 9 - Chat.thumb.height, width: Chat.thumb.width, height: Chat.thumb.height)
            ctx.saveGState()
            NSBezierPath(roundedRect: th, xRadius: 5, yRadius: 5).addClip()
            // Drawn at the photo's own size and scaled down, so the whole page shows.
            let photo = homeFrames[0]
            let k = max(th.width / photo.w, th.height / photo.h)
            ctx.translateBy(x: th.midX - photo.w * k / 2, y: th.midY - photo.h * k / 2)
            ctx.scaleBy(x: k, y: k)
            drawContent(photo.kind, NSRect(x: 0, y: 0, width: photo.w, height: photo.h))
            ctx.restoreGState()
            box(th, 5, nil, hair)
        }
    }
    let textFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    let textAt = NSPoint(x: c.minX + 10, y: c.minY + 11)
    if typed.isEmpty {
        bar(textAt.x, textAt.y + 1, 70, 3.5, faint)
    } else {
        NSAttributedString(string: typed, attributes: [.font: textFont, .foregroundColor: ink])
            .draw(at: NSPoint(x: textAt.x, y: textAt.y - 2 + textFont.descender))
    }
    if caret {
        let w = typed.isEmpty ? 0 : NSAttributedString(string: typed, attributes: [.font: textFont]).size().width
        ink.setFill(); NSRect(x: textAt.x + w + 1, y: textAt.y - 3, width: 1, height: 12).fill()
    }
    drawSymbol("return", size: 8, weight: .medium, color: typed.isEmpty ? text : ink, at: NSPoint(x: c.maxX - 12, y: c.minY + 15))

    // Under the box: attach, voice and mode; the model and effort on the right.
    let row = full.minY - 12
    drawSymbol("plus", size: 7, weight: .medium, color: text, at: NSPoint(x: full.minX + 8, y: row))
    drawSymbol("mic", size: 7, weight: .medium, color: text, at: NSPoint(x: full.minX + 20, y: row))
    bar(full.minX + 30, row - 1, 3, 2, text)
    bar(full.minX + 40, row - 1.75, 16, 3.5, text)
    bar(full.maxX - 72, row - 1.75, 26, 3.5, ink.withAlphaComponent(0.85))
    bar(full.maxX - 40, row - 1.75, 22, 3.5, ink.withAlphaComponent(0.85))
    NSBezierPath(ovalIn: NSRect(x: full.maxX - 12, y: row - 3.5, width: 7, height: 7)).fill()
    ctx.restoreGState()
}

func dragShot(_ ctx: CGContext, _ l: CGFloat) {
    let t = theme
    let picked = homeFrames[0]
    let grab = NSPoint(x: picked.x, y: lineY(picked.x) + 7 - picked.h / 2)
    let drop = NSPoint(x: Chat.composer.midX - 20, y: Chat.composer.minY + Chat.closedH / 2 + 4)
    let typeAt = NSPoint(x: Chat.composer.minX + 150, y: Chat.composer.minY + 16)

    // Down comes the line, the pointer takes the chart and carries it over.
    var s = spring(l, 0.15)
    let lifted = l >= 1.3
    if lifted {
        let d = l - 1.3
        for k in 1..<3 { s.swing[k] += 4 * exp(-3 * d) * sin(9 * d) * (k == 1 ? 1 : -1) }
    }
    if l >= 3.3 { s.reveal = 1 - ramp(l, 3.3, 0.28) }

    var photos = homePhotos()
    photos[0].open = ramp(l, 0.75, 0.25) * (1 - ramp(l, 1.2, 0.12))
    photos[0].pressed = bump(l, 1.12)
    if lifted { photos.removeFirst(); s.swing.removeFirst() }

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
    let message = L("把首页的下载按钮改成截图里这样", "Make the homepage download button match this screenshot")
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

/// The GitHub mark (Octicons mark-github, MIT), on a 16 × 16 grid with y down.
let githubMark = "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"

/// Enough of SVG path syntax for the mark: M, C, c, A (a circular arc) and z.
func svgPath(_ d: String) -> NSBezierPath {
    var numbers: [CGFloat] = [], commands: [(Character, [CGFloat])] = []
    var token = "", command: Character = " "
    func flush() { if let v = Double(token) { numbers.append(CGFloat(v)) }; token = "" }
    for ch in d {
        if ch.isLetter {
            flush(); if command != " " { commands.append((command, numbers)) }
            command = ch; numbers = []
        } else if ch == "-" { flush(); token = "-" }
        else if ch == "." && token.contains(".") { flush(); token = "." }
        else if ch == " " || ch == "," { flush() }
        else { token.append(ch) }
    }
    flush(); commands.append((command, numbers))

    let p = NSBezierPath()
    var cur = NSPoint.zero
    for (c, n) in commands {
        switch c {
        case "M": cur = NSPoint(x: n[0], y: n[1]); p.move(to: cur)
        case "C", "c":
            for i in stride(from: 0, to: n.count - 5, by: 6) {
                let o = c == "c" ? cur : .zero
                let c1 = NSPoint(x: o.x + n[i], y: o.y + n[i + 1]), c2 = NSPoint(x: o.x + n[i + 2], y: o.y + n[i + 3])
                cur = NSPoint(x: o.x + n[i + 4], y: o.y + n[i + 5])
                p.curve(to: cur, controlPoint1: c1, controlPoint2: c2)
            }
        case "A":
            // Arc flags run into the end point here ("0 0016 8"): radius, rotation, then "0016" is 0, 0, 16.
            let end = NSPoint(x: 16, y: 8), centre = NSPoint(x: 8, y: 8)
            let a0 = atan2(cur.y - centre.y, cur.x - centre.x) * 180 / .pi, a1: CGFloat = 0
            p.appendArc(withCenter: centre, radius: hypot(cur.x - centre.x, cur.y - centre.y),
                        startAngle: a0, endAngle: a1, clockwise: true)
            cur = end
        case "z", "Z": p.close()
        default: break
        }
    }
    return p
}

/// The mark, `size` points square, with its bottom-left at `origin`.
func drawGitHubMark(at origin: NSPoint, size: CGFloat, color: NSColor) {
    let p = svgPath(githubMark)
    var t = AffineTransform(translationByX: origin.x, byY: origin.y + size)
    t.scale(x: size / 16, y: -size / 16)
    p.transform(using: t)
    color.setFill(); p.fill()
}

func drawEnding(_ ctx: CGContext, alpha: CGFloat, rise: CGFloat) {
    withAlpha(ctx, alpha) {
        ctx.saveGState(); ctx.translateBy(x: 0, y: -rise)
        drawBrand(nameSize: 92, baseline: 444)
        text(T("Screenshots and snippets, all on one line."), size: language == "en" ? 30 : 28, weight: .regular,
             color: theme.secondaryInk, tracking: language == "en" ? -0.4 : 1, centerX: VW / 2, baselineY: 376)
        text(L("免费开源 · 不联网 · macOS 14 及以上", "Free and open source · No network · macOS 14 and later"),
             size: 19, weight: .regular, color: theme.secondaryInk, tracking: 0.3, centerX: VW / 2, baselineY: 322)

        // Where it lives: the GitHub mark and the repository, no address.
        let repoFont = NSFont.systemFont(ofSize: 19, weight: .medium)
        let repo = NSAttributedString(string: "ffkiyo7/Clipline", attributes: [.font: repoFont, .foregroundColor: theme.ink, .kern: 0.2])
        let mark: CGFloat = 20, gap: CGFloat = 9, repoBaseline: CGFloat = 272
        let left = (VW - (mark + gap + repo.size().width)) / 2
        drawGitHubMark(at: NSPoint(x: left, y: repoBaseline - 3.5), size: mark, color: theme.ink)
        repo.draw(at: NSPoint(x: left + mark + gap, y: repoBaseline + repoFont.descender))

        let command = NSAttributedString(string: "brew install --cask ffkiyo7/tap/clipline", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium), .foregroundColor: theme.ink])
        let size = command.size()
        let pill = NSRect(x: (VW - size.width - 44) / 2, y: 196, width: size.width + 44, height: 48)
        theme.tile.setFill(); NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
        command.draw(at: NSPoint(x: pill.minX + 22, y: pill.midY - size.height / 2))
        ctx.restoreGState()
    }
}

// MARK: A frame of the film

/// Marking up is written in 4.5 seconds; it plays at this pace to match the rest.
let markupPace: CGFloat = 5.5 / 4.5
let shotBodies: [(CGContext, CGFloat) -> Void] = [heroShot, revealShot, captureShot,
                                                  { markupShot($0, $1 / markupPace) }, dragShot, notesShot]

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
