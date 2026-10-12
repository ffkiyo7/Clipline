import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// Tendedero's own screenshot, taken the way Snipaste takes one. The screen
/// freezes and dims, and the window under the pointer lights up: a click
/// takes that window. With Accessibility allowed, the button or panel under
/// it lights up instead, and scrolling steps out to what holds it. A drag selects an area instead, its edges sticking to
/// the windows' edges, with a magnifier for the last pixel. The selection
/// can then be moved, resized and marked up right where it is. Return hangs
/// it on the line and copies it.
@MainActor
final class Capture: ObservableObject {
    private static var current: Capture?
    private static var starting = false
    static var isActive: Bool { current != nil || starting }

    /// The screenshot is saved: hang it, with the window it shows.
    static var onCaptured: (URL, Source?) -> Void = { _, _ in }

    /// One screen, frozen as it was when the shortcut was pressed.
    struct Shot {
        let screen: NSScreen
        let image: CGImage
        /// Image pixels per point.
        var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
    }

    /// A window that was on screen, in AppKit screen coordinates.
    struct Target {
        let frame: CGRect
        let pid: pid_t
        let bundleID: String?
        let appName: String
        let title: String?
    }

    enum Phase {
        case choosing
        /// The button is down; a drag selects an area, a click the window.
        case pressing(CGPoint)
        case dragging(CGPoint)
        case selected
        case moving(CGVector)
        case resizing(Handle)
        /// Marks going on: the selection is fixed from now on.
        case marking
    }

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    enum Finish { case done, save, pin }

    private let shots: [Shot]
    private let targets: [Target]
    /// The app in front before, given the keys back afterwards.
    private let previous: NSRunningApplication?
    private var overlays: [CaptureWindow] = []
    private var toolbar: NSHostingView<CaptureToolbar>?
    private var canvas: EditorCanvas?
    private var widthChange: AnyCancellable?

    private(set) var phase: Phase = .choosing
    /// In screen coordinates, always within one screen.
    private(set) var selection: CGRect?
    private(set) var mouse = NSEvent.mouseLocation
    /// The window under the pointer while choosing, or the whole screen.
    private(set) var hovered: CGRect?
    private(set) var hoveredTarget: Target?
    /// The parts of that window under the pointer, innermost first, and how
    /// many steps out from the innermost the highlight is. As many steps as
    /// there are parts is the window itself.
    private var parts: [Elements.Element] = []
    private var level = 0
    private var looking = false
    private var lookAgain = false
    private var scrolled: CGFloat = 0
    /// Edges the selection is sticking to, drawn as dashed lines.
    private(set) var guides: (x: CGFloat?, y: CGFloat?) = (nil, nil)
    private(set) var colorCopiedUntil = Date.distantPast
    @Published private(set) var editor: EditorModel?

    // MARK: Starting and ending

    static func start() {
        guard !isActive else { return }
        let allowed = CGPreflightScreenCaptureAccess()
        log.notice("Capture started; screen recording allowed: \(allowed, privacy: .public)")
        guard allowed else {
            askForAccess()
            return
        }
        starting = true
        let previous = NSWorkspace.shared.frontmostApplication
        let targets = listTargets()
        Task { @MainActor in
            let shots = await grab()
            starting = false
            guard !shots.isEmpty else {
                NSSound.beep()
                return
            }
            if Elements.isActive { Elements.wake(Set(targets.map(\.pid))) }
            let capture = Capture(shots: shots, targets: targets, previous: previous)
            current = capture
            capture.show()
        }
    }

    private init(shots: [Shot], targets: [Target], previous: NSRunningApplication?) {
        self.shots = shots
        self.targets = targets
        self.previous = previous
    }

    private func show() {
        Editor.installEditMenu()
        for shot in shots {
            let window = CaptureWindow(shot: shot, capture: self)
            overlays.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        focus(overlay(at: mouse) ?? overlays.first)
        NSCursor.crosshair.set()
        updateHover()
        redraw()
    }

    private func close() {
        toolbar?.removeFromSuperview()
        toolbar = nil
        canvas = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        Self.current = nil
        NSCursor.arrow.set()
    }

    private func giveKeysBack() {
        if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.activate()
        }
    }

    func cancel() {
        close()
        giveKeysBack()
    }

    /// Saves the selection, marks included, then copies, pins or saves it
    /// elsewhere as asked. Every way, it also hangs on the line.
    func finish(_ how: Finish) {
        canvas?.commitText()
        guard let area = selection, let shot = shot(for: area),
              let image = editor?.rendered() ?? crop(area, shot),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            NSSound.beep()
            return
        }
        let target = targets.first { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }
        let source = target.map { Source(bundleID: $0.bundleID, appName: $0.appName, windowTitle: $0.title) }
        close()
        guard let url = Self.save(png, area: area) else {
            NSSound.beep()
            giveKeysBack()
            return
        }
        switch how {
        case .done:
            Self.copy(png, url: url)
            giveKeysBack()
        case .pin:
            giveKeysBack()
            Pin.show(url, image: NSImage(cgImage: image, size: area.size))
        case .save:
            Self.saveAs(png, name: url.lastPathComponent)
            giveKeysBack()
        }
        Self.onCaptured(url, source)
    }

    // MARK: The pointer

    func moved(to p: CGPoint) {
        mouse = p
        if case .choosing = phase { updateHover() }
        redraw()
    }

    func pressed(at p: CGPoint, clicks: Int) {
        mouse = p
        switch phase {
        case .choosing:
            phase = .pressing(p)
        case .selected:
            guard let area = selection else { return }
            if let handle = handle(at: p, of: area) {
                phase = .resizing(handle)
            } else if area.contains(p) {
                if clicks == 2 {
                    finish(.done)
                    return
                }
                phase = .moving(CGVector(dx: p.x - area.minX, dy: p.y - area.minY))
                NSCursor.closedHand.set()
            } else {
                // Starting over somewhere else.
                selection = nil
                updateHover()
                phase = .pressing(p)
            }
        default:
            return
        }
        layoutToolbar()
        redraw()
    }

    func dragged(to p: CGPoint, flags: NSEvent.ModifierFlags) {
        mouse = p
        // Command held: no sticking to edges, for an exact hand-made area.
        let sticks = !flags.contains(.command)
        switch phase {
        case .pressing(let start):
            guard hypot(p.x - start.x, p.y - start.y) > 3, let shot = shot(at: start) else { return }
            let x = sticks ? snap(start.x, to: xEdges(shot)).value : start.x
            let y = sticks ? snap(start.y, to: yEdges(shot)).value : start.y
            phase = .dragging(CGPoint(x: x, y: y))
            dragged(to: p, flags: flags)
            return
        case .dragging(let start):
            guard let shot = shot(at: start) else { return }
            let q = clamp(p, to: shot.screen.frame)
            let x = snap(q.x, to: sticks ? xEdges(shot) : [])
            let y = snap(q.y, to: sticks ? yEdges(shot) : [])
            guides = (x.guide, y.guide)
            selection = CGRect(x: min(start.x, x.value), y: min(start.y, y.value),
                               width: abs(x.value - start.x), height: abs(y.value - start.y))
        case .moving(let offset):
            guard var area = selection, let shot = shot(for: area) else { return }
            let bounds = shot.screen.frame
            area.origin.x = min(max(p.x - offset.dx, bounds.minX), bounds.maxX - area.width)
            area.origin.y = min(max(p.y - offset.dy, bounds.minY), bounds.maxY - area.height)
            selection = area
            layoutToolbar()
        case .resizing(let handle):
            guard let area = selection, let shot = shot(for: area) else { return }
            let q = clamp(p, to: shot.screen.frame)
            let x = snap(q.x, to: sticks ? xEdges(shot) : [])
            let y = snap(q.y, to: sticks ? yEdges(shot) : [])
            var minX = area.minX, maxX = area.maxX, minY = area.minY, maxY = area.maxY
            switch handle {
            case .topLeft: minX = x.value; maxY = y.value
            case .top: maxY = y.value
            case .topRight: maxX = x.value; maxY = y.value
            case .right: maxX = x.value
            case .bottomRight: maxX = x.value; minY = y.value
            case .bottom: minY = y.value
            case .bottomLeft: minX = x.value; minY = y.value
            case .left: minX = x.value
            }
            let movesX = ![.top, .bottom].contains(handle), movesY = ![.left, .right].contains(handle)
            guides = (movesX ? x.guide : nil, movesY ? y.guide : nil)
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            layoutToolbar()
        default:
            return
        }
        redraw()
    }

    func released(at p: CGPoint) {
        mouse = p
        switch phase {
        case .pressing:
            // A click: the window under it, or the whole screen.
            updateHover()
            if let hovered, hovered.width >= 4, hovered.height >= 4 {
                selection = hovered
                phase = .selected
            } else {
                phase = .choosing
            }
        case .dragging:
            if let area = selection, area.width >= 4, area.height >= 4 {
                phase = .selected
            } else {
                selection = nil
                phase = .choosing
                updateHover()
            }
        case .moving, .resizing:
            if let area = selection, area.width < 4 || area.height < 4 {
                selection = CGRect(origin: area.origin, size: CGSize(width: max(4, area.width), height: max(4, area.height)))
            }
            phase = .selected
        default:
            return
        }
        guides = (nil, nil)
        if let area = selection { focus(overlay(at: CGPoint(x: area.midX, y: area.midY))) }
        updateCursor()
        layoutToolbar()
        redraw()
    }

    /// Right-click: drop the selection, or leave when there is none.
    func rightClicked() {
        switch phase {
        case .choosing: cancel()
        case .marking: break
        default:
            selection = nil
            phase = .choosing
            updateHover()
            layoutToolbar()
            redraw()
        }
    }

    func updateCursor() {
        switch phase {
        case .marking:
            if let canvas, canvas.frame.contains(canvas.superview?.convert(canvas.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil) ?? .zero) { return }
            NSCursor.arrow.set()
        case .selected:
            guard let area = selection else { return }
            if handle(at: mouse, of: area) != nil {
                NSCursor.crosshair.set()
            } else if area.contains(mouse) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        case .moving:
            NSCursor.closedHand.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    // MARK: Keys

    /// Returns false for keys it does not use.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: // Esc
            cancel()
            return true
        case 36, 76: // Return, Enter: while choosing, takes the window under the pointer.
            if case .choosing = phase, let hovered { selection = hovered }
            if selection != nil { finish(.done) }
            return true
        case 123, 124, 125, 126: // Arrows
            nudge(event.keyCode, resize: flags.contains(.shift))
            return true
        default:
            break
        }
        if flags.contains(.command) {
            guard selection != nil else { return false }
            switch chars {
            case "c": finish(.done)
            case "s": finish(.save)
            case "p": finish(.pin)
            default: return false
            }
            return true
        }
        if case .selected = phase,
           let tool = EditorModel.Tool.allCases.first(where: { $0 != .select && $0.key.lowercased() == chars }) {
            pick(tool)
            return true
        }
        if chars == "c", showsMagnifier, let hex = hex(at: mouse) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(hex, forType: .string)
            ClipboardWatcher.ownChangeCount = pb.changeCount
            colorCopiedUntil = Date().addingTimeInterval(1.2)
            redraw()
            return true
        }
        return false
    }

    /// Arrows move the selection a point; with Shift they move its right or
    /// bottom edge instead.
    private func nudge(_ keyCode: UInt16, resize: Bool) {
        guard case .selected = phase, var area = selection, let shot = shot(for: area) else { return }
        let dx: CGFloat = keyCode == 123 ? -1 : keyCode == 124 ? 1 : 0
        let dy: CGFloat = keyCode == 125 ? -1 : keyCode == 126 ? 1 : 0
        if resize {
            area.size.width = max(4, area.width + dx)
            // Down grows the area downwards; up shrinks it from below.
            if area.height - dy >= 4 {
                area.origin.y += dy
                area.size.height -= dy
            }
        } else {
            area.origin.x += dx
            area.origin.y += dy
        }
        selection = area.intersection(shot.screen.frame)
        layoutToolbar()
        redraw()
    }

    // MARK: Marking up

    /// A tool from the toolbar or its key. The first one fixes the selection
    /// and lays a canvas over it, the same one as the markup window's.
    func pick(_ tool: EditorModel.Tool) {
        if let editor {
            editor.tool = tool
            return
        }
        guard let area = selection, let shot = shot(for: area), let image = crop(area, shot),
              let window = overlay(at: CGPoint(x: area.midX, y: area.midY)) else { return }
        let model = EditorModel(image: image, scale: shot.scale)
        model.tool = tool
        let canvas = EditorCanvas(model: model)
        canvas.inset = 0
        canvas.drawsBackdrop = false
        canvas.frame = window.overlay.local(area)
        canvas.onCommand = { [weak self] command in
            switch command {
            case .done, .copy: self?.finish(.done)
            case .save: self?.finish(.save)
            case .pin: self?.finish(.pin)
            case .cancel: self?.cancel()
            }
        }
        window.overlay.addSubview(canvas, positioned: .below, relativeTo: toolbar)
        window.makeFirstResponder(canvas)
        self.canvas = canvas
        editor = model
        // The width scrolled to shows in the toolbar, which grows to fit it.
        widthChange = model.$customWidth.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layoutToolbar() } }
        phase = .marking
        layoutToolbar()
        // The toolbar grows a row for colors once SwiftUI has caught up.
        DispatchQueue.main.async { [weak self] in self?.layoutToolbar() }
        redraw()
    }

    // MARK: What the overlays draw

    /// The bright hole in the dimmed screen, if it is on this screen.
    func highlight(on shot: Shot) -> CGRect? {
        let rect: CGRect?
        switch phase {
        case .choosing, .pressing: rect = hovered
        default: rect = selection
        }
        guard let rect, shot.screen.frame.intersects(rect) else { return nil }
        return rect
    }

    var showsHandles: Bool {
        switch phase {
        case .selected, .moving, .resizing: true
        default: false
        }
    }

    var showsMagnifier: Bool {
        switch phase {
        case .choosing, .pressing, .dragging, .resizing: true
        default: false
        }
    }

    /// The window's name while choosing, then the size in pixels.
    func label(for rect: CGRect, on shot: Shot) -> String {
        let size = "\(Int((rect.width * shot.scale).rounded())) × \(Int((rect.height * shot.scale).rounded()))"
        switch phase {
        case .choosing, .pressing:
            if let part = hoveredPart { return part.kind.map { "\($0)   \(size)" } ?? size }
            guard let target = hoveredTarget else { return size }
            let name = [target.appName, target.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            return name.isEmpty ? size : "\(name)   \(size)"
        default:
            return size
        }
    }

    /// The pixel under a point as #RRGGBB.
    func hex(at p: CGPoint) -> String? {
        guard let shot = shot(at: p), let rgb = Self.pixel(shot.image, at: pixelPoint(p, in: shot)) else { return nil }
        return String(format: "#%02X%02X%02X", rgb.0, rgb.1, rgb.2)
    }

    func pixelPoint(_ p: CGPoint, in shot: Shot) -> CGPoint {
        CGPoint(x: ((p.x - shot.screen.frame.minX) * shot.scale).rounded(.down),
                y: ((shot.screen.frame.maxY - p.y) * shot.scale).rounded(.down))
    }

    private func redraw() {
        overlays.forEach { $0.overlay.needsDisplay = true }
    }

    // MARK: Toolbar

    private func layoutToolbar() {
        let shown: Bool
        switch phase {
        case .selected, .moving, .resizing, .marking: shown = true
        default: shown = false
        }
        guard shown, let area = selection, let window = overlay(at: CGPoint(x: area.midX, y: area.midY)) else {
            toolbar?.removeFromSuperview()
            return
        }
        let host = toolbar ?? NSHostingView(rootView: CaptureToolbar(capture: self))
        toolbar = host
        if host.superview !== window.overlay {
            host.removeFromSuperview()
            window.overlay.addSubview(host)
        }
        let size = host.fittingSize
        let r = window.overlay.local(area), b = window.overlay.bounds
        // Under the selection, flush with its right edge, as in Snipaste.
        // Without room below it goes above, and failing that inside.
        let x = min(max(r.maxX - size.width, b.minX + 6), b.maxX - size.width - 6)
        var y = r.minY - size.height - 8
        if y < b.minY + 6 { y = r.maxY + 8 }
        if y + size.height > b.maxY - 6 { y = max(r.minY + 8, b.minY + 6) }
        host.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Geometry

    private func updateHover() {
        guard let shot = shot(at: mouse) else {
            hovered = nil
            hoveredTarget = nil
            parts = []
            return
        }
        let target = targets.first { $0.frame.contains(mouse) }
        if target?.frame != hoveredTarget?.frame || target?.pid != hoveredTarget?.pid {
            parts = []
            level = 0
        }
        hoveredTarget = target
        applyHover(on: shot)
        lookForParts()
    }

    /// The part lit up, or nil for the whole window.
    private var hoveredPart: Elements.Element? {
        guard level < parts.count, parts[0].frame.contains(mouse) else { return nil }
        return parts[level]
    }

    private func applyHover(on shot: Shot) {
        let frame = hoveredPart?.frame ?? hoveredTarget?.frame ?? shot.screen.frame
        hovered = frame.intersection(shot.screen.frame)
    }

    /// Asks the app under the pointer for its parts, away from the main
    /// thread, since a busy app can take a moment to answer. One question at
    /// a time; meanwhile the pointer may move on, and is asked about next.
    private func lookForParts() {
        guard Elements.isActive, case .choosing = phase, let target = hoveredTarget,
              let top = NSScreen.screens.first?.frame.maxY else { return }
        if looking {
            lookAgain = true
            return
        }
        looking = true
        let p = mouse, pid = target.pid, window = target.frame
        Task.detached(priority: .userInitiated) {
            let found = Elements.chain(at: p, pid: pid, window: window, top: top)
            await MainActor.run { [weak self] in self?.found(found, pid: pid) }
        }
    }

    private func found(_ found: [Elements.Element], pid: pid_t) {
        looking = false
        if case .choosing = phase, hoveredTarget?.pid == pid, let shot = shot(at: mouse) {
            // Stepped out to a part that still holds the pointer: it stays lit.
            let held = level > 0 ? hoveredPart : nil
            parts = found
            level = held.flatMap { held in found.firstIndex { $0.frame == held.frame } } ?? 0
            applyHover(on: shot)
            redraw()
        }
        if lookAgain {
            lookAgain = false
            lookForParts()
        }
    }

    /// Scrolling while choosing steps out to the part around the lit one,
    /// up to the window, and back in.
    func scroll(by delta: CGFloat, precise: Bool) {
        guard case .choosing = phase, !parts.isEmpty, let shot = shot(at: mouse) else { return }
        scrolled += precise ? delta : delta * 12
        guard abs(scrolled) >= 12 else { return }
        let step = scrolled > 0 ? 1 : -1
        scrolled = 0
        let next = min(max(0, level + step), parts.count)
        guard next != level else { return }
        level = next
        applyHover(on: shot)
        redraw()
    }

    private func shot(at p: CGPoint) -> Shot? {
        shots.first { NSMouseInRect(p, $0.screen.frame, false) }
    }

    private func shot(for area: CGRect) -> Shot? {
        shot(at: CGPoint(x: area.midX, y: area.midY))
    }

    private func overlay(at p: CGPoint) -> CaptureWindow? {
        overlays.first { NSMouseInRect(p, $0.frame, false) }
    }

    private func focus(_ window: CaptureWindow?) {
        guard let window, editor == nil else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.overlay)
    }

    private func handle(at p: CGPoint, of area: CGRect) -> Handle? {
        let reach: CGFloat = 8
        for handle in Handle.allCases where hypot(p.x - point(of: handle, in: area).x, p.y - point(of: handle, in: area).y) <= reach {
            return handle
        }
        // Anywhere along an edge, not only at its middle.
        let inX = p.x > area.minX && p.x < area.maxX, inY = p.y > area.minY && p.y < area.maxY
        if inX && abs(p.y - area.maxY) <= 4 { return .top }
        if inX && abs(p.y - area.minY) <= 4 { return .bottom }
        if inY && abs(p.x - area.minX) <= 4 { return .left }
        if inY && abs(p.x - area.maxX) <= 4 { return .right }
        return nil
    }

    func point(of handle: Handle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.maxY)
        case .top: CGPoint(x: r.midX, y: r.maxY)
        case .topRight: CGPoint(x: r.maxX, y: r.maxY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottom: CGPoint(x: r.midX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.minY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Edges an area sticks to: the windows' and the screen's.
    private func xEdges(_ shot: Shot) -> [CGFloat] {
        let frame = shot.screen.frame
        return [frame.minX, frame.maxX] + targets.filter { $0.frame.intersects(frame) }.flatMap { [$0.frame.minX, $0.frame.maxX] }
            + parts.flatMap { [$0.frame.minX, $0.frame.maxX] }
    }

    private func yEdges(_ shot: Shot) -> [CGFloat] {
        let frame = shot.screen.frame
        return [frame.minY, frame.maxY] + targets.filter { $0.frame.intersects(frame) }.flatMap { [$0.frame.minY, $0.frame.maxY] }
            + parts.flatMap { [$0.frame.minY, $0.frame.maxY] }
    }

    /// Within a few points of an edge, the value becomes the edge.
    private func snap(_ value: CGFloat, to edges: [CGFloat]) -> (value: CGFloat, guide: CGFloat?) {
        guard let nearest = edges.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) <= 6 else {
            return (value, nil)
        }
        return (nearest, nearest)
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// The area cut from the frozen screen, at full resolution.
    private func crop(_ area: CGRect, _ shot: Shot) -> CGImage? {
        let s = shot.scale, f = shot.screen.frame
        let pixels = CGRect(x: (area.minX - f.minX) * s, y: (f.maxY - area.maxY) * s,
                            width: area.width * s, height: area.height * s).integral
        return shot.image.cropping(to: pixels)
    }

    // MARK: Screens and windows

    /// Every screen at full resolution, without the pointer.
    private static func grab() async -> [Shot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            log.error("Could not list the screens: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var shots: [Shot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                shots.append(Shot(screen: screen, image: image))
            } catch {
                log.error("Could not capture a screen: \(error.localizedDescription, privacy: .public)")
            }
        }
        return shots
    }

    /// Ordinary windows on screen, front to back, other than Tendedero's.
    private static func listTargets() -> [Target] {
        guard let main = NSScreen.screens.first else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 40, rect.height > 40 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let appName = app?.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? ""
            // Many windows are named after their app; that name shows once.
            let title = (info[kCGWindowName as String] as? String).flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed.caseInsensitiveCompare(appName) == .orderedSame ? nil : trimmed
            }
            // Window bounds are measured from the top of the main screen.
            return Target(frame: CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height),
                          pid: pid, bundleID: app?.bundleIdentifier, appName: appName, title: title)
        }
    }

    static func pixel(_ image: CGImage, at p: CGPoint) -> (UInt8, UInt8, UInt8)? {
        guard p.x >= 0, p.y >= 0, Int(p.x) < image.width, Int(p.y) < image.height,
              let one = image.cropping(to: CGRect(x: p.x, y: p.y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? (bytes[0], bytes[1], bytes[2]) : nil
    }

    // MARK: Files

    /// Into Tendedero's folder, named like a macOS screenshot and tagged with
    /// the area it came from, so it flies from there to the line and a pin
    /// opens right over it.
    private static func save(_ png: Data, area: CGRect) -> URL? {
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return f.string(from: Date())
        }()
        var url = Inbox.folder.appendingPathComponent("Screenshot \(stamp).png")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = Inbox.folder.appendingPathComponent("Screenshot \(stamp) \(n).png")
            n += 1
        }
        do {
            try fm.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("Could not save a screenshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if let main = NSScreen.screens.first {
            let values = [area.minX, main.frame.maxY - area.maxY, area.width, area.height].map { NSNumber(value: Double($0)) }
            if let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) {
                _ = data.withUnsafeBytes { bytes in
                    setxattr(url.path, "com.apple.metadata:kMDItemScreenCaptureGlobalRect", bytes.baseAddress, data.count, 0, 0)
                }
            }
        }
        return url
    }

    /// The picture and its file, as a copy from the line would give them.
    private static func copy(_ png: Data, url: URL) {
        let entry = NSPasteboardItem()
        entry.setData(png, forType: .png)
        entry.setString(url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
        ClipboardWatcher.ownChangeCount = pb.changeCount
    }

    private static func saveAs(_ png: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try png.write(to: target, options: .atomic) } catch { NSSound.beep() }
    }

    private static func askForAccess() {
        let alert = NSAlert()
        alert.messageText = L("Tendedero needs Screen Recording access to take screenshots")
        alert.informativeText = L("Turn on Tendedero in System Settings → Privacy & Security → Screen Recording, then try again.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        CGRequestScreenCaptureAccess()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - The overlay on each screen

/// Covers one screen, above the menu bar, Dock and full screen apps: the
/// frozen screen underneath, the dimming and selection drawn over it.
@MainActor
final class CaptureWindow: NSWindow {
    let overlay: CaptureView

    init(shot: Capture.Shot, capture: Capture) {
        overlay = CaptureView(shot: shot, capture: capture)
        super.init(contentRect: shot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let root = NSView(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        let frozen = NSView(frame: root.bounds)
        frozen.wantsLayer = true
        frozen.layer?.contents = shot.image
        frozen.layer?.contentsGravity = .resize
        frozen.autoresizingMask = [.width, .height]
        overlay.frame = root.bounds
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(frozen)
        root.addSubview(overlay)
        contentView = root
        setFrame(shot.screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CaptureView: NSView {
    private let shot: Capture.Shot
    private let capture: Capture

    init(shot: Capture.Shot, capture: Capture) {
        self.shot = shot
        self.capture = capture
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// From screen coordinates to this view's.
    func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - shot.screen.frame.minX, y: p.y - shot.screen.frame.minY) }
    private func global(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + shot.screen.frame.minX, y: p.y + shot.screen.frame.minY)
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        capture.moved(to: global(event))
        capture.updateCursor()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capture.pressed(at: global(event), clicks: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        capture.dragged(to: global(event), flags: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        capture.released(at: global(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        capture.rightClicked()
    }

    override func scrollWheel(with event: NSEvent) {
        capture.scroll(by: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
    }

    override func keyDown(with event: NSEvent) {
        if !capture.key(event) { super.keyDown(with: event) }
    }

    // MARK: Drawing

    private static let blue = NSColor(srgbRed: 0.22, green: 0.54, blue: 0.87, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hole = capture.highlight(on: shot).map(local)

        // The dimming, with the hole left bright.
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addRect(hole) }
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.fillPath(using: .evenOdd)

        if let hole {
            let frame = NSBezierPath(rect: hole.insetBy(dx: -0.75, dy: -0.75))
            frame.lineWidth = 1.5
            Self.blue.setStroke()
            frame.stroke()
            if capture.showsHandles {
                for handle in Capture.Handle.allCases {
                    let c = capture.point(of: handle, in: hole)
                    let dot = NSBezierPath(roundedRect: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5)
                    NSColor.white.setFill()
                    dot.fill()
                    dot.lineWidth = 1.5
                    Self.blue.setStroke()
                    dot.stroke()
                }
            }
            if let area = capture.highlight(on: shot) {
                drawLabel(capture.label(for: area, on: shot), over: hole)
            }
        }
        drawGuides()
        if capture.showsMagnifier, NSMouseInRect(capture.mouse, shot.screen.frame, false) {
            drawMagnifier(at: local(capture.mouse))
        }
    }

    private func drawGuides() {
        let path = NSBezierPath()
        if let x = capture.guides.x {
            let lx = x - shot.screen.frame.minX
            path.move(to: CGPoint(x: lx, y: bounds.minY))
            path.line(to: CGPoint(x: lx, y: bounds.maxY))
        }
        if let y = capture.guides.y {
            let ly = y - shot.screen.frame.minY
            path.move(to: CGPoint(x: bounds.minX, y: ly))
            path.line(to: CGPoint(x: bounds.maxX, y: ly))
        }
        guard !path.isEmpty else { return }
        path.lineWidth = 1
        path.setLineDash([5, 4], count: 2, phase: 0)
        Self.blue.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }

    /// A dark pill above the hole's top left corner, or inside it at the top
    /// of the screen.
    private func drawLabel(_ text: String, over hole: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let width = min(size.width + 14, max(80, bounds.width - 12))
        var box = CGRect(x: hole.minX, y: hole.maxY + 5, width: width, height: size.height + 6)
        if box.maxY > bounds.maxY - 2 { box.origin.y = hole.maxY - box.height - 5; box.origin.x += 5 }
        box.origin.x = min(max(box.minX, bounds.minX + 2), bounds.maxX - box.width - 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(with: CGRect(x: box.minX + 7, y: box.minY + 3, width: box.width - 14, height: size.height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The pixels around the pointer, enlarged, with its position and color.
    private func drawMagnifier(at p: CGPoint) {
        let cells = 15, side: CGFloat = 120, infoHeight: CGFloat = 36
        let total = CGSize(width: side, height: side + infoHeight)
        var origin = CGPoint(x: p.x + 22, y: p.y - 22 - total.height)
        if origin.x + total.width > bounds.maxX - 4 { origin.x = p.x - 22 - total.width }
        if origin.y < bounds.minY + 4 { origin.y = p.y + 22 }
        let box = CGRect(origin: origin, size: total)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let outline = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.82).setFill()
        outline.fill()

        let zoomRect = CGRect(x: box.minX, y: box.maxY - side, width: side, height: side)
        let center = capture.pixelPoint(capture.mouse, in: shot)
        let half = CGFloat(cells / 2)
        let source = CGRect(x: center.x - half, y: center.y - half, width: CGFloat(cells), height: CGFloat(cells))
        ctx.saveGState()
        NSBezierPath(roundedRect: zoomRect, xRadius: 8, yRadius: 8).addClip()
        NSColor.black.setFill()
        zoomRect.fill()
        // Near the screen's edge the crop is cut short; keep it aligned.
        let available = source.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        if !available.isNull, let pixels = shot.image.cropping(to: available) {
            let cell = side / CGFloat(cells)
            let drawn = CGRect(x: zoomRect.minX + (available.minX - source.minX) * cell,
                               y: zoomRect.maxY - (available.maxY - source.minY) * cell,
                               width: available.width * cell, height: available.height * cell)
            ctx.interpolationQuality = .none
            ctx.draw(pixels, in: drawn)
        }
        // Crosshair through the middle cell.
        let cell = side / CGFloat(cells)
        let mid = CGRect(x: zoomRect.midX - cell / 2, y: zoomRect.midY - cell / 2, width: cell, height: cell)
        Self.blue.withAlphaComponent(0.35).setFill()
        CGRect(x: zoomRect.minX, y: mid.minY, width: side, height: cell).fill()
        CGRect(x: mid.minX, y: zoomRect.minY, width: cell, height: side).fill()
        NSColor.white.setStroke()
        let centre = NSBezierPath(rect: mid)
        centre.lineWidth = 1
        centre.stroke()
        ctx.restoreGState()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let white: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let position = "\(Int(center.x)), \(Int(center.y))"
        (position as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 19), withAttributes: white)
        let copied = Date() < capture.colorCopiedUntil
        let hex = capture.hex(at: capture.mouse) ?? ""
        if let rgb = Capture.pixel(shot.image, at: center) {
            let swatch = CGRect(x: box.minX + 8, y: box.minY + 6, width: 10, height: 10)
            NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        }
        let colorText = copied ? "\(hex)  \(L("Copied"))" : "\(hex)   C"
        (colorText as NSString).draw(at: CGPoint(x: box.minX + 23, y: box.minY + 4), withAttributes: white)
    }
}

// MARK: - Toolbar

/// Glass, like the cards on the line: the tools that mark the selection
/// where it is, then pin, save, cancel and done. A second row with colors
/// and widths appears once marking starts.
struct CaptureToolbar: View {
    @ObservedObject var capture: Capture

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 2) {
                if let editor = capture.editor {
                    MarkingTools(model: editor)
                } else {
                    ForEach(CaptureToolbar.tools, id: \.self) { tool in
                        ToolButton(symbol: tool.symbol, help: "\(tool.title)  \(tool.key)") { capture.pick(tool) }
                    }
                }
                Divider().frame(height: 20).padding(.horizontal, 3)
                ToolButton(symbol: "pin", help: "\(L("Pin to Screen"))  ⌘P") { capture.finish(.pin) }
                ToolButton(symbol: "square.and.arrow.down", help: "\(L("Save As…"))  ⌘S") { capture.finish(.save) }
                ToolButton(symbol: "xmark", help: "\(L("Cancel"))  Esc") { capture.cancel() }
                ToolButton(symbol: "checkmark", selected: true, help: "\(L("Done"))  ↩") { capture.finish(.done) }
            }
            if let editor = capture.editor {
                StyleControls(model: editor)
                    .padding(.horizontal, 4)
            }
        }
        .padding(5)
        .glassFrame(cornerRadius: 11, materialOpacity: 0.85)
        .fixedSize()
    }

    static let tools = EditorModel.Tool.allCases.filter { $0 != .select }
}

/// The tools once marking has started: the current one lit, and undo.
private struct MarkingTools: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ForEach(CaptureToolbar.tools, id: \.self) { tool in
            ToolButton(symbol: tool.symbol, selected: model.tool == tool, help: "\(tool.title)  \(tool.key)") {
                model.tool = tool
            }
        }
        Divider().frame(height: 20).padding(.horizontal, 3)
        ToolButton(symbol: "arrow.uturn.backward", help: "\(L("Undo"))  ⌘Z") { model.undo() }
            .disabled(!model.canUndo)
        ToolButton(symbol: "arrow.uturn.forward", help: "\(L("Redo"))  ⇧⌘Z") { model.redo() }
            .disabled(!model.canRedo)
    }
}
