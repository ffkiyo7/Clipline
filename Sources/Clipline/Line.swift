import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "io.github.ffkiyo7.Clipline", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// The app it was captured from, when known.
    var source: Source?
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Clipline.isRecording(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
            && a.source == b.source
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// The photo under the pointer: it comes to the front, so its open tag
    /// is not hidden behind the next photo.
    @Published var hoveredID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false
    /// Something that can hang is being dragged.
    @Published var carrying = false
    /// The place opened for it under the pointer, as the photos make room.
    /// Only a gesture: what is dropped still hangs last, as the newest.
    @Published var gap: Int?

    /// Where the photo or clip in this slot hangs while a gap is open, and
    /// how many places there are then.
    func place(_ slot: Int) -> (index: Int, count: Int) {
        guard let gap else { return (slot, slots) }
        return (slot >= gap ? slot + 1 : slot, slots + 1)
    }
    /// How the source tags show, mirrored here so the cards redraw.
    @Published var tagStyle = Source.tagStyle

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]
    /// The source tags below the photos, which also catch the pointer.
    var tagRects: [UUID: CGRect] = [:]
    /// The note clip at the end of the line, which catches it too.
    var clipRect: CGRect?
    /// Whether the note clip hangs at the end of the line.
    @Published var noteClip = false
    /// Places taken on the line: the photos, and the note clip after them.
    var slots: Int { items.count + (noteClip ? 1 : 0) }
    /// The clip was clicked: open the notes below it, in screen coordinates.
    var onOpenNotes: ((NSRect) -> Void)?

    var maxItems = 8
    /// How many photos fit across the screen. With Keep on line set, the
    /// line can hold more, and the rest are reached by scrolling.
    var visibleCount = 8
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = UserDefaults.standard.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"
    private let sourcesKey = "peggedSources"

    init() {
        restore()
        Self.sweepUsed()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, source: Source? = nil, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        // Hung again before its file went to the Trash: it stays.
        Self.keep(url)
        var item = Pegged(url: url, thumb: thumb, source: source)
        item.flying = flying
        items.append(item)
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        tagRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// "Take everything down": every photo goes the way of its corner cross.
    func clear() {
        takeDown(items.filter { !$0.falling })
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])
    }

    /// Takes down everything on one side of a photo. Each one goes the way
    /// of its own corner button: to the Trash from Clipline's folder, and
    /// only off the line from anywhere else.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound.
    private func takeDown(_ live: [Pegged]) {
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0)
            }
        }
    }

    // MARK: Cutting down with the scissors

    /// Where the scissors sit on the rope, under the pointer, or nil while
    /// the pointer is not on the rope.
    @Published var scissorsX: CGFloat?
    /// The way the scissors last moved, which they face.
    @Published private(set) var scissorsFaceLeft = false
    /// The cut in progress, while the button is held.
    @Published private(set) var stroke: Stroke?
    /// The last cut, while it can still be undone.
    @Published private(set) var lastCut: Cut?
    /// Clips just cut, each with a spark where it snapped.
    @Published private(set) var snips: [Snip] = []
    /// The undo pill, which catches the pointer like the photos do.
    var undoRect: CGRect?

    /// How long a cut can be undone. Files from Clipline's folder wait as
    /// long before they go to the Trash.
    nonisolated static let undoDelay: TimeInterval = 6
    /// How far off the rope the pointer may wander and still cut.
    nonisolated static let cutReach: CGFloat = 40

    /// The first few times the scissors show, they say what they do.
    nonisolated static var cutsMade: Int {
        get { UserDefaults.standard.integer(forKey: "cutsMade") }
        set { UserDefaults.standard.set(newValue, forKey: "cutsMade") }
    }

    private var cutWidth: CGFloat = 0
    private var cutLastX: CGFloat = 0
    /// The photos in order when the cut began, to put them back in place.
    private var cutOrder: [UUID] = []
    private var cutTaken: [Cut.Taken] = []

    /// Where each hanging photo's clip grips the rope, on a line this wide,
    /// the same way the line view lays them out.
    func clips(width: CGFloat) -> [(id: UUID, x: CGFloat)] {
        items.indices.filter { !items[$0].falling }.map { i in
            let slot = place(i)
            return (id: items[i].id, x: Layout.x(index: slot.index, count: slot.count, width: width,
                                                visible: visibleCount, scroll: scroll))
        }
    }

    func beginCut(at x: CGFloat, width: CGFloat) {
        lastCut = nil
        cutWidth = width
        cutLastX = x
        cutOrder = items.filter { !$0.falling }.map(\.id)
        cutTaken = []
        stroke = Stroke(from: x, to: x)
        scissorsX = x
        snip(from: x, to: x)
    }

    func moveCut(to x: CGFloat, y: CGFloat) {
        guard var current = stroke else { return }
        if x != cutLastX { scissorsFaceLeft = x < cutLastX }
        current.to = x
        stroke = current
        scissorsX = x
        // Wandered off the rope, the scissors stop cutting until they are back.
        if abs(y - Layout.ropeY(x: x, width: cutWidth)) <= Self.cutReach { snip(from: cutLastX, to: x) }
        cutLastX = x
    }

    /// The button is let go. What was cut can be undone for a moment.
    func endCut() {
        guard let done = stroke else { return }
        stroke = nil
        guard !cutTaken.isEmpty else { return }
        let cut = Cut(taken: cutTaken, x: done.to)
        cutTaken = []
        lastCut = cut
        Self.cutsMade += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoDelay) { [weak self] in
            if self?.lastCut?.id == cut.id { self?.lastCut = nil }
        }
    }

    /// Every photo the cut puts back hangs where it was, swinging as it
    /// arrives. A file from Clipline's folder is taken off its way to the Trash.
    func undoCut() {
        guard let cut = lastCut else { return }
        lastCut = nil
        for taken in cut.taken.sorted(by: { $0.index < $1.index }) {
            guard FileManager.default.fileExists(atPath: taken.url.path),
                  !items.contains(where: { $0.url == taken.url && !$0.falling }) else { continue }
            Self.keep(taken.url)
            let hanging = items.indices.filter { !items[$0].falling }
            let at = Self.insertionIndex(for: taken.index, hanging: hanging, count: items.count)
            items.insert(Pegged(url: taken.url, thumb: taken.thumb, source: taken.source), at: at)
        }
        save()
        play("Tink", volume: 0.35)
    }

    /// Cuts every clip the scissors passed between two points on the rope.
    /// Each photo falls the way of its corner cross, except that a file from
    /// Clipline's folder waits for the undo before it goes to the Trash.
    private func snip(from a: CGFloat, to b: CGFloat) {
        let hanging = clips(width: cutWidth)
        let passed = Self.clipsPassed(hanging.map(\.x), from: a, to: b)
        for n in passed {
            let (id, x) = hanging[n]
            guard let item = items.first(where: { $0.id == id }) else { continue }
            cutTaken.append(Cut.Taken(url: item.url, thumb: item.thumb, source: item.source,
                                      index: cutOrder.firstIndex(of: id) ?? cutOrder.count))
            if isInInbox(id) { Self.trashLater(item.url, after: Self.undoDelay) }
            drop(id, quietly: true)
            let spark = Snip(x: x)
            snips.append(spark)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.snips.removeAll { $0.id == spark.id }
            }
        }
        if !passed.isEmpty { play("Pop", volume: 0.25) }
    }

    /// The clips at `xs` that a stroke from `a` to `b` passes, in the order
    /// it meets them. One just under where the stroke starts counts too.
    nonisolated static func clipsPassed(_ xs: [CGFloat], from a: CGFloat, to b: CGFloat,
                                        slack: CGFloat = 6) -> [Int] {
        let low = min(a, b) - slack, high = max(a, b) + slack
        let hit = xs.indices.filter { xs[$0] >= low && xs[$0] <= high }
            .sorted { xs[$0] < xs[$1] }
        return a <= b ? hit : hit.reversed()
    }

    /// Where a photo that was `place`th among the hanging ones goes back:
    /// before the one now in that place, or last.
    nonisolated static func insertionIndex(for place: Int, hanging: [Int], count: Int) -> Int {
        place < hanging.count ? hanging[place] : count
    }

    /// Dragged into an app, the photo has done its job: it is gone from the
    /// line at once, without falling, since it went where you dropped it.
    /// The app may still be reading the file, so a file from Clipline's
    /// folder only goes to the Trash a few minutes later.
    func used(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id && !$0.falling }) else { return }
        let inInbox = isInInbox(id)
        hitRects[id] = nil
        tagRects[id] = nil
        if hoveredID == id { hoveredID = nil }
        items.removeAll { $0.id == id }
        save()
        if inInbox { Self.trashLater(item.url) }
    }

    /// How long a used file waits before it goes to the Trash.
    private static let usedDelay: TimeInterval = 5 * 60
    /// Used and cut files still waiting, by path, with when they go. Kept
    /// across launches, so quitting in the meantime leaves nothing behind.
    private static let usedKey = "usedFiles"

    private static func trashLater(_ url: URL, after delay: TimeInterval = usedDelay) {
        var waiting = UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Double] ?? [:]
        let due = Date().addingTimeInterval(delay)
        waiting[url.path] = due.timeIntervalSince1970
        UserDefaults.standard.set(waiting, forKey: usedKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) { sweepUsed() }
    }

    private static func keep(_ url: URL) {
        guard var waiting = UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Double],
              waiting.removeValue(forKey: url.path) != nil else { return }
        UserDefaults.standard.set(waiting, forKey: usedKey)
    }

    /// Trashes the used files whose time has come, and waits for the rest.
    private static func sweepUsed() {
        guard var waiting = UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Double],
              !waiting.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for (path, due) in waiting where due <= now {
            waiting[path] = nil
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            keepClipboard(without: url)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                log.notice("Trashed used \(url.lastPathComponent, privacy: .public)")
            } catch {
                log.error("Could not trash used \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        UserDefaults.standard.set(waiting, forKey: usedKey)
        if let next = waiting.values.min() {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next - now + 1)) { sweepUsed() }
        }
    }

    /// A copy holds the image and its file. Many apps paste from the file,
    /// so once it is in the Trash they would find nothing there. Before a
    /// file goes, a clipboard still holding it keeps only the image.
    static func keepClipboard(without url: URL) {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems, items.count == 1, let item = items.first,
              let named = item.string(forType: .fileURL).flatMap(URL.init(string:)),
              named.standardizedFileURL == url.standardizedFileURL,
              let png = item.data(forType: .png) else { return }
        let entry = NSPasteboardItem()
        entry.setData(png, forType: .png)
        pb.clearContents()
        pb.writeObjects([entry])
        ClipboardWatcher.ownChangeCount = pb.changeCount
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if !item.isRecording, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        Self.keepClipboard(without: item.url)
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Clipline's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        if isInInbox(id) { trash(id, quietly: quietly) } else { drop(id, quietly: quietly) }
    }

    /// The oldest photo falling off a full line. Like the cross, a file from
    /// Clipline's folder goes to the Trash, or nothing would ever take it out
    /// of that folder. If the Trash refuses it, it still leaves the line.
    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        let most = CGFloat(max(0, slots - visibleCount)) * Layout.spacing
        let next = min(most, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
        scroll = 0
    }

    private func letGo(_ id: UUID) {
        if isInInbox(id), trash(id, quietly: true) { return }
        drop(id, quietly: true)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        Self.keepClipboard(without: item.url)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Editor.edit(item.url) { [weak self] url in self?.reloadThumbnail(for: url) }
        }
    }

    /// The system's Markup, still a menu item away.
    func systemMarkup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isRecording else { return }
        Markup.shared.edit(item.url)
    }

    /// Pins the photo to the screen, floating above every window.
    func pin(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isRecording else { return }
        Pin.show(item.url)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let live = items.filter { !$0.falling }
        UserDefaults.standard.set(live.map(\.url.path), forKey: storeKey)
        var sources: [String: Data] = [:]
        for item in live {
            if let source = item.source, let data = try? JSONEncoder().encode(source) { sources[item.url.path] = data }
        }
        UserDefaults.standard.set(sources, forKey: sourcesKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        let sources = UserDefaults.standard.dictionary(forKey: sourcesKey) as? [String: Data] ?? [:]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            let source = sources[path].flatMap { try? JSONDecoder().decode(Source.self, from: $0) }
            items.append(Pegged(url: url, thumb: thumb, source: source))
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// One stroke of the scissors along the rope, in the line's coordinates.
struct Stroke: Equatable {
    var from: CGFloat
    var to: CGFloat
}

/// Photos cut down in one stroke, kept for a moment so it can be undone.
struct Cut: Identifiable {
    struct Taken {
        let url: URL
        let thumb: NSImage
        let source: Source?
        /// Its place among the hanging photos when the cut began.
        let index: Int
    }

    let id = UUID()
    let taken: [Taken]
    /// Where along the line the stroke ended.
    let x: CGFloat
}

/// A clip that just snapped.
struct Snip: Identifiable {
    let id = UUID()
    let x: CGFloat
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
