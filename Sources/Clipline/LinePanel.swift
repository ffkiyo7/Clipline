import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    /// Two-finger swipes and the scroll wheel, for moving along a long line.
    var onScroll: ((NSEvent) -> Void)?
    /// The left button on the rope, for the scissors. Returns whether it
    /// took the event; otherwise it goes on to the photos as usual.
    var onRopeMouse: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
                  onRopeMouse?(event) == true {
            return
        } else {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
