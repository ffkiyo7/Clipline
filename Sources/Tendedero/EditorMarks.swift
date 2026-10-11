import AppKit
import CoreImage
import Combine

/// One mark drawn over the screenshot. Everything is kept in the image's own
/// pixels, top-left origin, so the saved file is as sharp as the original.
struct Mark: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case rectangle, ellipse, arrow, pen, text, number, mosaic
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    /// Line width in pixels; text and numbers grow with it.
    var width: CGFloat
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 0

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var fontSize: CGFloat { width * 5 + 6 }
    var numberRadius: CGFloat { width * 2.2 + 8 }

    /// Whether the mark is still too small to keep after a click.
    var isEmpty: Bool {
        switch kind {
        case .rectangle, .ellipse, .mosaic: rect.width < 3 || rect.height < 3
        case .arrow: hypot(end.x - start.x, end.y - start.y) < 4
        case .pen: points.count < 2
        case .text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: false
        }
    }

    mutating func move(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }

    /// The area it covers, for hit testing and the selection outline.
    var bounds: CGRect {
        switch kind {
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .null }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -width, dy: -width)
        case .text:
            let size = (text as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: start, size: size)
        case .number:
            let r = numberRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .arrow:
            return rect.insetBy(dx: -width * 2, dy: -width * 2)
        default:
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    func hit(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .rectangle, .ellipse:
            // Only the outline: clicking inside a frame draws a new one.
            let outer = rect.insetBy(dx: -tolerance - width, dy: -tolerance - width)
            let inner = rect.insetBy(dx: tolerance + width, dy: tolerance + width)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .arrow:
            return distance(from: p, toSegment: start, end) <= tolerance + width
        case .pen:
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= tolerance + width }
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    /// The two handles that reshape it: its start and end points.
    var hasHandles: Bool { [.rectangle, .ellipse, .arrow, .mosaic].contains(kind) }

    var textAttributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(color.isLight ? 0.55 : 0)
        shadow.shadowBlurRadius = width
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }
}

private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.7
    }
}

// MARK: Drawing

/// Draws marks into a context whose units are image pixels, y pointing down.
/// The editor's canvas and the saved file both go through here, so what you
/// see is what gets saved.
enum MarkRenderer {
    static func draw(_ marks: [Mark], in ctx: CGContext, image: CGImage, mosaic: CGImage?) {
        for mark in marks { draw(mark, in: ctx, image: image, mosaic: mosaic) }
    }

    static func draw(_ mark: Mark, in ctx: CGContext, image: CGImage, mosaic: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(mark.color.cgColor)
        ctx.setFillColor(mark.color.cgColor)
        ctx.setLineWidth(mark.width)

        switch mark.kind {
        case .rectangle:
            ctx.stroke(mark.rect)
        case .ellipse:
            ctx.strokeEllipse(in: mark.rect)
        case .arrow:
            drawArrow(from: mark.start, to: mark.end, width: mark.width, in: ctx)
        case .pen:
            guard let first = mark.points.first else { return }
            ctx.move(to: first)
            for p in mark.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .mosaic:
            guard let mosaic else { return }
            ctx.clip(to: mark.rect)
            drawImage(mosaic, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), ctx: ctx)
        case .number:
            let r = mark.numberRadius
            let circle = CGRect(x: mark.start.x - r, y: mark.start.y - r, width: r * 2, height: r * 2)
            ctx.setShadow(offset: CGSize(width: 0, height: r * 0.12), blur: r * 0.3,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(max(1.5, r * 0.12))
            ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
            let label = NSAttributedString(string: "\(mark.number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: mark.color.isLight ? NSColor.black : NSColor.white,
            ])
            let size = label.size()
            withAppKit(ctx) {
                label.draw(at: CGPoint(x: mark.start.x - size.width / 2, y: mark.start.y - size.height / 2))
            }
        case .text:
            let text = NSAttributedString(string: mark.text, attributes: mark.textAttributes)
            withAppKit(ctx) { text.draw(at: mark.start) }
        }
    }

    /// A tapered arrow: a thin tail growing into a solid head.
    private static func drawArrow(from a: CGPoint, to b: CGPoint, width w: CGFloat, in ctx: CGContext) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { return }
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        let px = -uy, py = ux
        let head = min(length * 0.6, w * 4 + 10)
        let headHalf = head * 0.55
        let neck = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        let shaftHalf = max(w * 0.6, 1.2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: a.x + px * 0.4, y: a.y + py * 0.4))
        path.addLine(to: CGPoint(x: neck.x + px * shaftHalf, y: neck.y + py * shaftHalf))
        path.addLine(to: CGPoint(x: neck.x + px * headHalf, y: neck.y + py * headHalf))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: neck.x - px * headHalf, y: neck.y - py * headHalf))
        path.addLine(to: CGPoint(x: neck.x - px * shaftHalf, y: neck.y - py * shaftHalf))
        path.addLine(to: CGPoint(x: a.x - px * 0.4, y: a.y - py * 0.4))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    /// Draws a CGImage upright in a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Text is drawn by AppKit, which needs to know the context is y-down.
    private static func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The finished image: the screenshot with every mark, at full size.
    static func render(image: CGImage, marks: [Mark], mosaic: CGImage?) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawImage(image, in: CGRect(x: 0, y: 0, width: w, height: h), ctx: ctx)
        draw(marks, in: ctx, image: image, mosaic: mosaic)
        return ctx.makeImage()
    }

    /// The whole screenshot pixelated once; each mosaic mark shows its piece.
    static func pixelated(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(14, CGFloat(max(image.width, image.height)) / 60), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }
}

// MARK: Model

@MainActor
final class EditorModel: ObservableObject {
    enum Tool: String, CaseIterable {
        case select, rectangle, ellipse, arrow, pen, text, number, mosaic

        var kind: Mark.Kind? { Mark.Kind(rawValue: rawValue) }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .arrow: "arrow.up.right"
            case .pen: "scribble"
            case .text: "textformat"
            case .number: "1.circle"
            case .mosaic: "checkerboard.rectangle"
            }
        }

        var key: String {
            switch self {
            case .select: "V"
            case .rectangle: "R"
            case .ellipse: "O"
            case .arrow: "A"
            case .pen: "P"
            case .text: "T"
            case .number: "N"
            case .mosaic: "M"
            }
        }

        var title: String {
            switch self {
            case .select: L("Select")
            case .rectangle: L("Rectangle")
            case .ellipse: L("Ellipse")
            case .arrow: L("Arrow")
            case .pen: L("Pen")
            case .text: L("Text")
            case .number: L("Number")
            case .mosaic: L("Mosaic")
            }
        }
    }

    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.96, green: 0.23, blue: 0.21, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        .black, .white,
    ]

    /// Line widths in points; multiplied by the image's pixels per point.
    static let widths: [CGFloat] = [2, 4, 7]

    @Published var tool: Tool = .rectangle { didSet { if tool != oldValue { selection = nil } } }
    @Published var colorIndex = UserDefaults.standard.integer(forKey: "editorColor") {
        didSet {
            UserDefaults.standard.set(colorIndex, forKey: "editorColor")
            restyleSelection { $0.color = self.color }
        }
    }
    @Published var widthIndex = UserDefaults.standard.object(forKey: "editorWidth") as? Int ?? 1 {
        didSet {
            UserDefaults.standard.set(widthIndex, forKey: "editorWidth")
            restyleSelection { $0.width = self.width }
        }
    }
    @Published private(set) var marks: [Mark] = []
    @Published var selection: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let image: CGImage
    let mosaic: CGImage?
    /// Image pixels per point, so a "medium" line looks the same on any image.
    let scale: CGFloat

    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []

    var color: NSColor { Self.colors[min(max(colorIndex, 0), Self.colors.count - 1)] }
    var width: CGFloat { Self.widths[min(max(widthIndex, 0), Self.widths.count - 1)] * scale }
    var hasChanges: Bool { !marks.isEmpty || !undoStack.isEmpty }
    var nextNumber: Int { (marks.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1 }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        mosaic = MarkRenderer.pixelated(image)
    }

    // MARK: Changes, each one undoable

    func checkpoint() {
        undoStack.append(marks)
        redoStack.removeAll()
        updateUndo()
    }

    func add(_ mark: Mark) {
        checkpoint()
        marks.append(mark)
        selection = mark.id
    }

    /// Changes a mark without a checkpoint, while it is being dragged.
    func update(_ id: UUID, _ change: (inout Mark) -> Void) {
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
        change(&marks[i])
    }

    func remove(_ id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        checkpoint()
        marks.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    /// Goes back to the last checkpoint without leaving a redo, for a mark
    /// that turned out empty.
    func rollback() {
        guard let previous = undoStack.popLast() else { return }
        marks = previous
        selection = nil
        updateUndo()
    }

    /// Drops the last checkpoint, for a drag that ended up changing nothing.
    func discardCheckpoint() {
        guard let last = undoStack.last, last == marks else { return }
        undoStack.removeLast()
        updateUndo()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(marks)
        marks = previous
        selection = nil
        updateUndo()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        marks = next
        selection = nil
        updateUndo()
    }

    private func updateUndo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Choosing a color or width while a mark is selected changes that mark.
    private func restyleSelection(_ change: (inout Mark) -> Void) {
        guard let id = selection, let mark = marks.first(where: { $0.id == id }), mark.kind != .mosaic else { return }
        checkpoint()
        update(id, change)
    }

    func rendered() -> CGImage? {
        MarkRenderer.render(image: image, marks: marks, mosaic: mosaic)
    }
}
