import AppKit

/// A photo pinned to the screen: a small borderless window that floats above
/// everything, like a sticky note made of the screenshot. Drag it anywhere,
/// scroll to zoom, Option-scroll for opacity, double-click or Esc to close.
@MainActor
final class Pin: NSPanel {
    private static var open: [Pin] = []

    private let image: NSImage
    private let url: URL
    /// The image's size at 100%, in points.
    private let natural: NSSize
    private var zoom: CGFloat = 1

    /// Pins a copy of the image. The pin keeps its own copy in memory, so it
    /// stays up even if the file is discarded from the line afterwards.
    static func show(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { NSSound.beep(); return }
        let pin = Pin(image: image, url: url)
        open.append(pin)
        pin.makeKeyAndOrderFront(nil)
    }

    static func closeAll() {
        open.forEach { $0.close() }
    }

    static var count: Int { open.count }

    private init(image: NSImage, url: URL) {
        self.image = image
        self.url = url
        let screen = Self.screen(for: url)
        natural = Self.naturalSize(of: image, on: screen)

        // Over the spot it was captured from when that is known, as if it
        // lifted off the screen; otherwise centred under the pointer.
        var frame: NSRect
        if let rect = captureRect(of: url) {
            frame = NSRect(origin: rect.origin, size: natural)
        } else {
            let mouse = NSEvent.mouseLocation
            frame = NSRect(x: mouse.x - natural.width / 2, y: mouse.y - natural.height / 2,
                           width: natural.width, height: natural.height)
        }
        // A pin larger than most of the screen starts smaller.
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let fit = min(1, visible.width * 0.8 / natural.width, visible.height * 0.8 / natural.height)
        zoom = fit
        frame.size = NSSize(width: natural.width * fit, height: natural.height * fit)
        if !visible.isEmpty {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }

        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let content = PinView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 4
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        content.pin = self
        // Drawn by the layer, so every click reaches the view below.
        content.layer?.contents = image
        content.layer?.contentsGravity = .resize
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        Self.open.removeAll { $0 === self }
    }

    // MARK: Size

    /// Screenshots record their resolution, so their size in points is right
    /// as it is. A copied image often says 72 dpi while holding the screen's
    /// pixels; it is shown at one pixel per pixel of the screen.
    private static func naturalSize(of image: NSImage, on screen: NSScreen?) -> NSSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0 else { return image.size }
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if CGFloat(rep.pixelsWide) == image.size.width && scale > 1 {
            return NSSize(width: image.size.width / scale, height: image.size.height / scale)
        }
        return image.size
    }

    private static func screen(for url: URL) -> NSScreen? {
        if let rect = captureRect(of: url) {
            return NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }

    /// Zooms around the pointer, so the spot you are looking at stays put.
    func setZoom(_ value: CGFloat, around point: NSPoint? = nil) {
        let next = min(8, max(0.1, value))
        guard next != zoom else { return }
        let old = frame
        let size = NSSize(width: natural.width * next, height: natural.height * next)
        let anchor = point ?? NSPoint(x: old.midX, y: old.midY)
        let fx = (anchor.x - old.minX) / old.width, fy = (anchor.y - old.minY) / old.height
        let origin = NSPoint(x: anchor.x - size.width * fx, y: anchor.y - size.height * fy)
        zoom = next
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func zoom(by factor: CGFloat, around point: NSPoint) {
        setZoom(zoom * factor, around: point)
    }

    func adjustOpacity(by delta: CGFloat) {
        alphaValue = min(1, max(0.15, alphaValue + delta))
    }

    // MARK: Actions

    func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.png]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: target, options: .atomic)) != nil else { NSSound.beep(); return }
        }
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.copyImage() })
        menu.addItem(ClosureMenuItem(L("Save As…")) { [weak self] in self?.saveAs() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Actual Size")) { [weak self] in self?.setZoom(1) })
        let opacity = NSMenuItem(title: L("Opacity"), action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for percent in [100, 80, 60, 40] {
            let item = ClosureMenuItem("\(percent)%") { [weak self] in self?.alphaValue = CGFloat(percent) / 100 }
            item.state = Int((alphaValue * 100).rounded()) == percent ? .on : .off
            levels.addItem(item)
        }
        opacity.submenu = levels
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Close")) { [weak self] in self?.close() })
        if Self.open.count > 1 {
            menu.addItem(ClosureMenuItem(L("Close All Pins")) { Pin.closeAll() })
        }
        return menu
    }
}

/// The pin's content: the image, plus the gestures.
private final class PinView: NSView {
    weak var pin: Pin?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pin?.close(); return }
        window?.makeKey()
        window?.performDrag(with: event)
    }

    /// Scrolling zooms, Option-scrolling changes the opacity. A pinch on a
    /// trackpad zooms too.
    override func scrollWheel(with event: NSEvent) {
        guard let pin else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 50 : event.scrollingDeltaY / 5
        if event.modifierFlags.contains(.option) {
            pin.adjustOpacity(by: delta / 4)
        } else {
            pin.zoom(by: 1 + max(-0.5, min(0.5, delta * 0.5)), around: NSEvent.mouseLocation)
        }
    }

    override func magnify(with event: NSEvent) {
        pin?.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let pin else { return }
        NSMenu.popUpContextMenu(pin.menu(), with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        guard let pin else { return }
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, command, event.charactersIgnoringModifiers) {
        case (53, _, _): pin.close() // Esc
        case (_, true, "c"): pin.copyImage()
        case (_, true, "s"): pin.saveAs()
        case (_, true, "w"): pin.close()
        case (_, false, "0"): pin.setZoom(1)
        default: super.keyDown(with: event)
        }
    }
}
