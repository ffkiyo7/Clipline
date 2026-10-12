import AppKit
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var captureKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    /// A new screenshot opens straight in Markup, so marking it up does not
    /// wait for a long press. Off out of the box.
    static var marksUpNew: Bool {
        get { UserDefaults.standard.bool(forKey: "markUpNew") }
        set { UserDefaults.standard.set(newValue, forKey: "markUpNew") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = LineHost(rootView: LineView(line: line))
        host.sizingOptions = []
        host.onDrop = { [weak self] urls in self?.hangDropped(urls) }
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher(
            onImage: { [weak self] url in self?.hangCapture(url) },
            onText: { text, source in Notes.shared.add(text, source: source) })
        clipboardWatcher.update()

        registerShortcut()

        setUpStatusItem()
        watchMenuBarClicks()

        Capture.onCaptured = { [weak self] url, source in self?.hangCapture(url, source: source) }
        watchDrags()
        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.onOpenNotes = { rect in NotesPanel.toggle(below: rect) }
        // Copied text only grows the clip's stack: the line stays where it is.
        Notes.shared.$all
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.notesChanged() }
            .store(in: &cancellables)

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Clipline handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Clipline quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Clipline") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        clipboardWatcher.update()
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose. The note
    /// clip counts: with notes in it, the line waits up there to be pulled
    /// down, though copying never brings it down by itself.
    private func itemsChanged() {
        guard line.liveCount == 0, !line.noteClip, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.line.noteClip, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    private func notesChanged() {
        let shows = Notes.isEnabled && !Notes.shared.all.isEmpty
        if line.noteClip != shows {
            line.noteClip = shows
            updateCapacity()
        }
        if shows && !wanted {
            wanted = true
            refresh()
        } else if !shows {
            itemsChanged()
        }
    }

    private func setNotes(_ on: Bool) {
        Notes.isEnabled = on
        clipboardWatcher.update()
        notesChanged()
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    /// `known`: the window it shows, when Clipline took the screenshot itself.
    private func hangCapture(_ url: URL, source known: Source? = nil) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen)
        let source = known ?? Source.detect(captureRect: from)
        guard let id = line.hang(url, source: source, flying: from != nil) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        // Markup opens once the photo has landed, not over the flight.
        if Self.marksUpNew && !isRecording(url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + CaptureFlight.duration + 0.1) { [weak self] in
                self?.line.markup(id)
            }
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    // MARK: Dragging onto the line

    /// Images dropped on the line hang in order, the newest last like any
    /// other, and the gap that opened for them closes.
    private func hangDropped(_ urls: [URL]) {
        line.gap = nil
        for url in urls { line.hang(url, quietly: url != urls.first) }
    }

    /// Notices a drag that could end on the line, from any app, so the line
    /// can come down to take it. The drag
    /// pasteboard changes when a drag starts; a cheap look a few times a
    /// second is enough, since the line only needs to be there by the time
    /// the pointer reaches the top of the screen.
    private func watchDrags() {
        var idleCount = NSPasteboard(name: .drag).changeCount
        var checked = (count: idleCount, canHang: false)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pb = NSPasteboard(name: .drag)
                let down = NSEvent.pressedMouseButtons & 1 != 0
                if !down { idleCount = pb.changeCount }
                var carrying = false
                if down, pb.changeCount != idleCount, !GrabView.isDragging {
                    if checked.count != pb.changeCount {
                        checked = (pb.changeCount, LineHost.canHang(pb))
                    }
                    carrying = checked.canHang
                }
                self.setCarrying(carrying)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setCarrying(_ on: Bool) {
        guard on != line.carrying else { return }
        line.carrying = on
        if on {
            // An empty line waits, tucked away, for the pointer to reach the top.
            if !wanted {
                wanted = true
                refresh()
            }
        } else {
            hotZoneSince = nil
            line.gap = nil
            itemsChanged()
        }
    }

    /// While an image is carried over the line, the photos part where it
    /// would go: the place nearest the pointer, between two of them.
    private func updateGap(_ mouse: NSPoint) {
        var gap: Int?
        if line.carrying, !line.items.isEmpty, NSMouseInRect(mouse, panel.frame, false) {
            let x = mouse.x - panel.frame.minX
            let count = line.slots + 1
            gap = (0..<count).min { a, b in
                abs(Layout.x(index: a, count: count, width: panel.frame.width,
                             visible: line.visibleCount, scroll: line.scroll) - x)
                    < abs(Layout.x(index: b, count: count, width: panel.frame.width,
                                   visible: line.visibleCount, scroll: line.scroll) - x)
            }
        }
        if line.gap != gap { line.gap = gap }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.slots, width: width,
                         visible: line.visibleCount, scroll: line.scroll)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent { panel.orderFrontRegardless() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = line.noteClip
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.12

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// Only the middle of the menu bar brings the line down, so reaching for
    /// a menu or an icon never does. On by default.
    static var opensFromMiddleOnly: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarWholeWidth") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarWholeWidth") }
    }

    /// The part of the menu bar that brings the line down. With a notch it is
    /// the notch and a little either side, where there are never menus or
    /// icons; otherwise the middle 30% of the bar. Only its upper part
    /// counts: the pointer stops there against the top edge, while a quick
    /// reach for a browser tab just below the bar does not get that high.
    static func revealZone(of screen: NSScreen) -> NSRect {
        var band = menuBarBand(of: screen)
        band.size.height = (band.height * 0.45).rounded()
        band.origin.y = screen.frame.maxY - band.height
        guard opensFromMiddleOnly else { return band }
        // Only the widths of the areas beside the notch are used, so it does
        // not matter whether their origins are local to the screen or global.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           left.width + right.width < screen.frame.width {
            let minX = screen.frame.minX + left.width - 40, maxX = screen.frame.maxX - right.width + 40
            return NSRect(x: minX, y: band.minY, width: maxX - minX, height: band.height)
        }
        let width = max(240, band.width * 0.3)
        return NSRect(x: band.midX - width / 2, y: band.minY, width: width, height: band.height)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.15

    private func tick() {
        // While taking a screenshot the line stays where it is.
        if Capture.isActive {
            hotZoneSince = nil
            awaySince = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            // Carrying an image or a pin, it always does.
            if Self.opensFromMenuBar || line.carrying, let screen = screenUnderPointer, inMenuBar,
               !menuBarSuppressed || line.carrying,
               NSMouseInRect(mouse, Self.revealZone(of: screen), false),
               !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu || NotesPanel.isOpen
            || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        // A drag from another app only finds a window that takes the mouse.
        if line.carrying {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            updateGap(mouse)
            return
        }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
            || line.tagRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
            || (line.noteClip && line.clipRect?.insetBy(dx: -4, dy: -4).contains(flipped) == true)
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.slots > line.visibleCount, Line.keepOnLine != nil {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        captureKey = nil
        if let shortcut = Shortcut.current {
            hotKey = HotKey(shortcut, id: 1) { [weak self] in self?.toggle() }
        }
        if let shortcut = Shortcut.capture {
            captureKey = HotKey(shortcut, id: 2) { Capture.start() }
            if captureKey == nil {
                log.error("The screenshot shortcut \(shortcut.display, privacy: .public) is taken by another app")
            }
        }
    }

    /// `capture`: the screenshot's shortcut rather than the line's.
    private func changeShortcut(capture: Bool = false) {
        // Off while recording, so pressing the current one records it
        // instead of showing the line.
        hotKey = nil
        captureKey = nil
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = capture ? Shortcut.capture : Shortcut.current
                if capture { Shortcut.capture = result } else { Shortcut.current = result }
                self.registerShortcut()
                // Taken by another app, or by the other shortcut: keep the
                // one that worked.
                if result != nil && (capture ? self.captureKey : self.hotKey) == nil {
                    NSSound.beep()
                    if capture { Shortcut.capture = previous } else { Shortcut.current = previous }
                }
            }
            self.registerShortcut()
        }
    }

    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        // The note clip takes one of the places.
        let photos = fits - (line.noteClip ? 1 : 0)
        line.maxItems = max(photos, Line.keepOnLine ?? photos)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let description = on ? L("Clipline, hanging copied images") : "Clipline"
        let image = NSImage(systemSymbolName: on ? "tshirt.fill" : "tshirt", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        let captureItem = ClosureMenuItem(L("Take Screenshot")) {
            // Once the menu has closed, so it is not in the picture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Capture.start() }
        }
        if let shortcut = Shortcut.capture, shortcut.key.count == 1 {
            captureItem.keyEquivalent = shortcut.key
            captureItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(captureItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        if Pin.count > 0 {
            menu.addItem(ClosureMenuItem(L("Close All Pins")) { Pin.closeAll() })
        }

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Images you copy hang on the line too")
        menu.addItem(clipboard)

        let notesItem = ClosureMenuItem(L("Keep copied text")) { [weak self] in
            self?.setNotes(!Notes.isEnabled)
        }
        notesItem.state = Notes.isEnabled ? .on : .off
        notesItem.toolTip = L("Text you copy goes into the clip at the end of the line")
        menu.addItem(notesItem)

        let markUpNew = ClosureMenuItem(L("Mark up new screenshots")) {
            AppDelegate.marksUpNew.toggle()
        }
        markUpNew.state = Self.marksUpNew ? .on : .off
        markUpNew.toolTip = L("Each new screenshot opens in Markup as soon as it hangs")
        menu.addItem(markUpNew)

        let tagItem = NSMenuItem(title: L("Source tags"), action: nil, keyEquivalent: "")
        let tags = NSMenu()
        for (style, title) in [(Source.TagStyle.name, L("App name")), (.icon, L("App icon only")), (.hidden, L("Hidden"))] {
            let item = ClosureMenuItem(title) { [weak self] in
                Source.tagStyle = style
                self?.line.tagStyle = style
            }
            item.state = Source.tagStyle == style ? .on : .off
            tags.addItem(item)
        }
        tagItem.submenu = tags
        menu.addItem(tagItem)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        options.autoenablesItems = false
        let hover = ClosureMenuItem(L("When the pointer rests in the menu bar")) {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let middle = ClosureMenuItem(L("Only in the middle of the menu bar")) {
            AppDelegate.opensFromMiddleOnly.toggle()
        }
        middle.state = Self.opensFromMiddleOnly ? .on : .off
        middle.isEnabled = Self.opensFromMenuBar
        middle.indentationLevel = 1
        options.addItem(middle)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let keepItem = NSMenuItem(title: L("Keep on line"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        let fit = ClosureMenuItem(L("As many as fit")) { [weak self] in self?.setKeep(nil) }
        fit.state = Line.keepOnLine == nil ? .on : .off
        keeps.addItem(fit)
        for n in Line.keepChoices {
            let item = ClosureMenuItem(String(format: L("%d photos"), n)) { [weak self] in self?.setKeep(n) }
            item.state = Line.keepOnLine == n ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcuts.addItem(.separator())
        let captureCurrent = NSMenuItem(
            title: String(format: L("Take Screenshot: %@"), Shortcut.capture?.display ?? L("None")),
            action: nil, keyEquivalent: "")
        captureCurrent.isEnabled = false
        shortcuts.addItem(captureCurrent)
        shortcuts.addItem(ClosureMenuItem(L("Change Screenshot Shortcut…")) { [weak self] in
            self?.changeShortcut(capture: true)
        })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let elements = ClosureMenuItem(L("Find Buttons and Panels in Screenshots")) {
            Elements.isEnabled = !Elements.isActive
            if Elements.isEnabled && !Elements.isTrusted { Elements.askForAccess() }
        }
        elements.state = Elements.isActive ? .on : .off
        menu.addItem(elements)

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // The app never connects to anything, so it cannot tell when a new
        // version is out. The website can: it is opened with this version
        // and language, and says whether there is a newer one.
        menu.addItem(ClosureMenuItem(L("Check for Updates…")) {
            NSWorkspace.shared.open(AppDelegate.updatesURL)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Clipline"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// The latest release of this fork on GitHub.
    private static let updatesURL = URL(string: "https://github.com/ffkiyo7/Clipline/releases/latest")!

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Clipline to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}
