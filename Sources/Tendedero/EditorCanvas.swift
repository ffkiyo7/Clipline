import AppKit
import Combine

/// The screenshot and its marks, fitted to the window. Drawing tools drag
/// out a new mark; on the selected mark, dragging moves it and its handles
/// reshape it. The select tool picks up any mark.
final class EditorCanvas: NSView {
    let model: EditorModel
    var onCommand: (Command) -> Void = { _ in }
    /// Room around the image. None when the marks go right over a
    /// screenshot being taken.
    var inset: CGFloat = 12
    /// The grey surround and the sheet under the image, for the window. Off
    /// over a screenshot being taken, where the screen itself is around it.
    var drawsBackdrop = true

    enum Command { case done, cancel, copy, save, pin }

    private var cancellables = Set<AnyCancellable>()
    private var drag: Drag?
    /// The text mark being edited, if editing one that already existed.
    private var editingTextID: UUID?

    private enum Drag {
        case drawing(UUID)
        /// `editOnClick`: a text under the text tool, edited if not dragged.
        case moving(UUID, last: CGPoint, moved: Bool, editOnClick: Bool = false)
        case handle(UUID, isStart: Bool)
    }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.needsDisplay = true }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Where the image sits in the view, kept to its proportions.
    private var imageRect: CGRect {
        let w = CGFloat(model.image.width), h = CGFloat(model.image.height)
        let area = bounds.insetBy(dx: inset, dy: inset)
        let s = min(area.width / w, area.height / h)
        let size = CGSize(width: w * s, height: h * s)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// View points per image pixel.
    private var zoom: CGFloat { imageRect.width / CGFloat(model.image.width) }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: (p.x - r.minX) / zoom, y: (p.y - r.minY) / zoom)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + p.x * zoom, y: r.minY + p.y * zoom)
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = toImage(convert(event.locationInWindow, from: nil))
        // Marks start inside the image, never off its edge.
        return CGPoint(x: min(max(p.x, 0), CGFloat(model.image.width)),
                       y: min(max(p.y, 0), CGFloat(model.image.height)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        if drawsBackdrop {
            NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black)?.setFill()
            bounds.fill()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            NSColor.white.setFill()
            r.fill()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        let full = CGRect(x: 0, y: 0, width: model.image.width, height: model.image.height)
        ctx.interpolationQuality = .high
        MarkRenderer.drawImage(model.image, in: full, ctx: ctx)
        let shown = model.marks.filter { $0.id != editingTextID }
        MarkRenderer.draw(shown, in: ctx, image: model.image, mosaic: model.mosaic)
        ctx.restoreGState()

        if let id = model.selection, let mark = model.marks.first(where: { $0.id == id }) {
            drawSelection(mark)
        }
    }

    private func drawSelection(_ mark: Mark) {
        let b = mark.bounds
        let r = CGRect(origin: toView(b.origin), size: CGSize(width: b.width * zoom, height: b.height * zoom))
            .insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        guard mark.hasHandles else { return }
        for p in [mark.start, mark.end] {
            let c = toView(p)
            let dot = NSBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    // MARK: Mouse

    private var tolerance: CGFloat { 6 / zoom }

    private func handle(at p: CGPoint) -> (UUID, Bool)? {
        guard let id = model.selection, let mark = model.marks.first(where: { $0.id == id }), mark.hasHandles else { return nil }
        let reach = 8 / zoom
        if hypot(p.x - mark.start.x, p.y - mark.start.y) <= reach { return (id, true) }
        if hypot(p.x - mark.end.x, p.y - mark.end.y) <= reach { return (id, false) }
        return nil
    }

    private func mark(at p: CGPoint) -> Mark? {
        model.marks.last { $0.hit(p, tolerance: tolerance) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A click away from the text being typed only finishes it.
        if textBox != nil {
            commitText()
            return
        }
        let p = point(event)

        if let (id, isStart) = handle(at: p) {
            model.checkpoint()
            drag = .handle(id, isStart: isStart)
            return
        }
        // With the text tool, a text moves when dragged and edits when clicked.
        if model.tool == .text, let hit = mark(at: p), hit.kind == .text {
            model.selection = hit.id
            model.checkpoint()
            drag = .moving(hit.id, last: p, moved: false, editOnClick: true)
            return
        }
        // The selected mark, or with the select tool any mark, moves.
        if let hit = mark(at: p), model.tool == .select || hit.id == model.selection {
            model.selection = hit.id
            if event.clickCount == 2, hit.kind == .text {
                beginText(at: hit.start, editing: hit)
                return
            }
            model.checkpoint()
            drag = .moving(hit.id, last: p, moved: false)
            return
        }

        model.selection = nil
        guard let kind = model.tool.kind else { return }
        switch kind {
        case .text:
            beginText(at: p, editing: nil)
        case .number:
            model.add(Mark(kind: .number, color: model.color, width: model.width, start: p, end: p,
                           number: model.nextNumber))
        default:
            var mark = Mark(kind: kind, color: model.color, width: model.width, start: p, end: p)
            if kind == .pen { mark.points = [p] }
            model.add(mark)
            drag = .drawing(mark.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .drawing(let id):
            let shift = event.modifierFlags.contains(.shift)
            model.update(id) { mark in
                if mark.kind == .pen {
                    mark.points.append(p)
                } else {
                    mark.end = shift ? constrained(from: mark.start, to: p, kind: mark.kind) : p
                }
            }
        case .moving(let id, let last, _, let editOnClick):
            model.update(id) { $0.move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y)) }
            drag = .moving(id, last: p, moved: true, editOnClick: editOnClick)
            NSCursor.closedHand.set()
        case .handle(let id, let isStart):
            model.update(id) { if isStart { $0.start = p } else { $0.end = p } }
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .drawing(let id):
            // A click without a drag leaves nothing behind.
            if let mark = model.marks.first(where: { $0.id == id }), mark.isEmpty {
                model.rollback()
            }
        case .moving(let id, _, let moved, let editOnClick):
            if !moved {
                model.discardCheckpoint()
                if editOnClick, let mark = model.marks.first(where: { $0.id == id }) {
                    beginText(at: mark.start, editing: mark)
                }
            }
            updateCursor(at: convert(event.locationInWindow, from: nil))
        default:
            break
        }
        drag = nil
    }

    /// Shift: squares and circles, arrows at 45° steps.
    private func constrained(from a: CGPoint, to b: CGPoint, kind: Mark.Kind) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        if kind == .arrow {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }

    /// Right-clicking a mark offers to delete it.
    override func rightMouseDown(with event: NSEvent) {
        commitText()
        guard let hit = mark(at: point(event)) else { return }
        model.selection = hit.id
        let menu = NSMenu()
        if hit.kind == .text {
            menu.addItem(ClosureMenuItem(L("Edit Text")) { [weak self] in self?.beginText(at: hit.start, editing: hit) })
        }
        let delete = ClosureMenuItem(L("Delete")) { [weak self] in self?.model.remove(hit.id) }
        delete.keyEquivalent = "\u{8}"
        delete.keyEquivalentModifierMask = []
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: model.tool == .select ? .arrow : .crosshair)
    }

    // MARK: Cursor

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// An open hand over what a drag would move: the selected mark, any mark
    /// with the select tool, any text with the text tool.
    private func updateCursor(at viewPoint: CGPoint) {
        guard textBox == nil || textBox?.frame.contains(viewPoint) == false else { return }
        let p = toImage(viewPoint)
        if handle(at: p) != nil {
            NSCursor.crosshair.set()
        } else if let hit = mark(at: p),
                  model.tool == .select || hit.id == model.selection || (model.tool == .text && hit.kind == .text) {
            NSCursor.openHand.set()
        } else if imageRect.contains(viewPoint) {
            (model.tool == .select ? NSCursor.arrow : model.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Text

    private func beginText(at p: CGPoint, editing existing: Mark?) {
        let template = existing ?? Mark(kind: .text, color: model.color, width: model.width, start: p, end: p)
        let font = NSFont.systemFont(ofSize: template.fontSize * zoom, weight: .semibold)
        let field = NSTextField(string: existing?.text ?? "")
        field.font = font
        field.textColor = template.color
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(template.color.isLight ? 0.35 : 0.06)
        field.focusRingType = .none
        field.placeholderString = L("Type here")
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.lineBreakMode = .byClipping
        // Only Return or Esc ends typing; losing focus to a drag does not.
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = self

        let box = TextBox(field: field)
        let origin = toView(template.start)
        box.frame.origin = CGPoint(x: origin.x - 2 - TextBox.fieldInset.x, y: origin.y - TextBox.fieldInset.y)
        box.onMove = { [weak self] in self?.needsDisplay = true }
        box.onDelete = { [weak self] in self?.deleteText() }
        addSubview(box)
        fitTextBox(box)
        window?.makeFirstResponder(field)
        textBox = box
        editingTextID = existing?.id
        pendingText = template
        needsDisplay = true
    }

    private var pendingText: Mark?
    private var textBox: TextBox?

    /// The box grows with the text, up to the edge of the canvas.
    private func fitTextBox(_ box: TextBox) {
        let field = box.field
        let text = field.stringValue.isEmpty ? (field.placeholderString ?? "") : field.stringValue
        let font = field.font ?? .systemFont(ofSize: 20)
        // A trailing newline still needs its empty line shown.
        let measured = text.hasSuffix("\n") ? text + " " : text
        let size = (measured as NSString).boundingRect(
            with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
            attributes: [.font: font]).size
        let room = bounds.maxX - box.frame.minX - TextBox.fieldInset.x - 12
        let lineHeight = font.boundingRectForFont.height
        box.setFieldSize(CGSize(width: max(60, min(size.width + 14, room)),
                                height: max(lineHeight, size.height) + 4))
    }


    /// The cross on the text box: the text goes, whether new or edited.
    private func deleteText() {
        guard let box = textBox else { return }
        textBox = nil
        pendingText = nil
        box.removeFromSuperview()
        if let id = editingTextID {
            editingTextID = nil
            model.remove(id)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Ends text editing, keeping the text unless it was left empty. Where
    /// the box was dragged to is where the text goes.
    func commitText() {
        guard let box = textBox, var mark = pendingText else { return }
        textBox = nil
        pendingText = nil
        let fieldOrigin = CGPoint(x: box.frame.minX + TextBox.fieldInset.x, y: box.frame.minY + TextBox.fieldInset.y)
        box.removeFromSuperview()
        mark.text = box.field.stringValue
        mark.start = toImage(CGPoint(x: fieldOrigin.x + 2, y: fieldOrigin.y))
        mark.end = mark.start
        if let id = editingTextID {
            editingTextID = nil
            if mark.isEmpty {
                model.remove(id)
            } else if let old = model.marks.first(where: { $0.id == id }), old.text != mark.text || old.start != mark.start {
                model.checkpoint()
                model.update(id) { $0.text = mark.text; $0.start = mark.start; $0.end = mark.start }
            }
        } else if !mark.isEmpty {
            model.add(mark)
        }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: onCommand(.cancel); return // Esc
        case 36, 76: onCommand(.done); return // Return, Enter
        case 51, 117: // Delete, Forward Delete
            if let id = model.selection { model.remove(id) }
            return
        default: break
        }
        if command {
            switch chars {
            case "z": flags.contains(.shift) ? model.redo() : model.undo()
            case "c": onCommand(.copy)
            case "s": onCommand(.save)
            case "p": onCommand(.pin)
            default: super.keyDown(with: event)
            }
            return
        }
        if let tool = EditorModel.Tool.allCases.first(where: { $0.key.lowercased() == chars }) {
            model.tool = tool
            window?.invalidateCursorRects(for: self)
        } else if let n = Int(chars), (1...EditorModel.colors.count).contains(n) {
            model.colorIndex = n - 1
        } else {
            super.keyDown(with: event)
        }
    }
}

extension EditorCanvas: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if let box = textBox { fitTextBox(box) }
    }

    /// Return starts a new line, as in Snipaste. Esc or Command-Return
    /// finishes the text and hands the keys back to the canvas.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                finishTyping()
            } else {
                textView.insertNewlineIgnoringFieldEditor(nil)
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishTyping()
            return true
        }
        return false
    }

    private func finishTyping() {
        commitText()
        window?.makeFirstResponder(self)
    }
}

/// The text being typed, in a dashed frame with a grip on its left. Dragging
/// the frame or the grip moves it; clicks inside the field edit the text.
final class TextBox: NSView {
    /// A clear band around the dashed frame that still grabs, so a drag
    /// need not land exactly on the frame.
    static let margin: CGFloat = 10
    static let fieldInset = CGPoint(x: margin + 18, y: margin + 6)
    let field: NSTextField
    var onMove: () -> Void = {}
    var onDelete: () -> Void = {}

    /// The cross at the frame's top right corner.
    private var deleteRect: CGRect {
        CGRect(x: bounds.maxX - Self.margin - 9, y: Self.margin - 9, width: 18, height: 18)
    }
    private var last: CGPoint?

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setFieldSize(_ size: CGSize) {
        field.frame = CGRect(origin: CGPoint(x: Self.fieldInset.x, y: Self.fieldInset.y), size: size)
        setFrameSize(CGSize(width: size.width + Self.fieldInset.x + Self.margin + 6, height: size.height + Self.fieldInset.y * 2))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: Self.margin + 0.5, dy: Self.margin + 0.5), xRadius: 5, yRadius: 5)
        frame.lineWidth = 1
        frame.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        frame.stroke()
        // The cross that deletes the text.
        let cross = deleteRect.insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: cross).fill()
        let x = NSBezierPath()
        let c = CGPoint(x: cross.midX, y: cross.midY), r: CGFloat = 3.2
        x.move(to: CGPoint(x: c.x - r, y: c.y - r)); x.line(to: CGPoint(x: c.x + r, y: c.y + r))
        x.move(to: CGPoint(x: c.x + r, y: c.y - r)); x.line(to: CGPoint(x: c.x - r, y: c.y + r))
        x.lineWidth = 1.6
        x.lineCapStyle = .round
        NSColor.white.setStroke()
        x.stroke()
        // The grip: two columns of dots.
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        let midY = bounds.midY
        for col in 0..<2 {
            for row in -1...1 {
                let x = Self.margin + 6 + CGFloat(col) * 4, y = midY + CGFloat(row) * 4
                NSBezierPath(ovalIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(field.frame, cursor: .iBeam)
        addCursorRect(deleteRect, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        if deleteRect.contains(convert(event.locationInWindow, from: nil)) {
            onDelete()
            return
        }
        last = superview?.convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last, let p = superview?.convert(event.locationInWindow, from: nil) else { return }
        frame.origin.x += p.x - last.x
        frame.origin.y += p.y - last.y
        self.last = p
        onMove()
    }

    override func mouseUp(with event: NSEvent) {
        guard last != nil else { return }
        last = nil
        NSCursor.pop()
        // Back to typing. Still editing, it keeps its caret; otherwise the
        // caret goes to the end rather than selecting everything.
        guard field.currentEditor() == nil else { return }
        window?.makeFirstResponder(field)
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }
}
