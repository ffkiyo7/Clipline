#if os(macOS)
import AppKit
import ApplicationServices
import XCTest

// End-to-end tests drive the real app the way a person does: they take
// screenshots with the system shortcut, press Clipline's shortcut, click and
// drag with the mouse, and copy text. They run against a copy of the built
// app with a bundle identifier of its own, so its settings never mix with
// yours, and a temporary folder in place of Clipline's own. The macOS
// screenshot settings are put back after every test.
//
// They only run when asked, since they take over the keyboard and the mouse:
//
//     scripts/build-app.sh
//     CLIPLINE_E2E=1 swift test --filter CliplineE2ETests
//
// What they need: Accessibility access for the app running them (Terminal,
// iTerm or Xcode), the standard ⌘⇧3 screenshot shortcut, and Clipline
// itself not running.

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum E2E {
    static let bundleID = "io.github.ffkiyo7.Clipline.e2e"
    static let realBundleID = "io.github.ffkiyo7.Clipline"

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var builtApp: URL {
        if let path = ProcessInfo.processInfo.environment["CLIPLINE_APP"] { return URL(fileURLWithPath: path) }
        return packageRoot.appendingPathComponent("build/Clipline.app")
    }

    /// Skipped unless asked for; once asked, anything missing is a failure
    /// that says what to do, never a quiet pass.
    static func checkPrerequisites() throws {
        guard ProcessInfo.processInfo.environment["CLIPLINE_E2E"] == "1" else {
            throw XCTSkip("End-to-end tests drive the mouse and keyboard. Run them with CLIPLINE_E2E=1.")
        }
        guard FileManager.default.fileExists(atPath: builtApp.path) else {
            throw E2EError("No app at \(builtApp.path). Run scripts/build-app.sh first, or set CLIPLINE_APP.")
        }
        guard AXIsProcessTrusted() else {
            throw E2EError("The app running the tests needs Accessibility access: System Settings → Privacy & Security → Accessibility.")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: realBundleID).isEmpty else {
            throw E2EError("Quit Clipline first: it would record the test's copied text and fight over the screenshot settings.")
        }
    }

    private static var prepared: URL?

    /// A copy of the built app under its own bundle identifier, signed again
    /// so macOS runs it.
    static func preparedApp() throws -> URL {
        if let prepared, FileManager.default.fileExists(atPath: prepared.path) { return prepared }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CliplineE2E-app-\(getpid())")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("Clipline E2E.app")
        try FileManager.default.copyItem(at: builtApp, to: app)
        try shell("/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier \(bundleID)",
                  app.appendingPathComponent("Contents/Info.plist").path)
        try shell("/usr/bin/codesign", "--force", "--deep", "--sign", "-", app.path)
        prepared = app
        return app
    }

    /// The test app's settings, file and all. Only through cfprefsd: a file
    /// removed behind its back is written again.
    static func removeSettings() {
        _ = try? shell("/usr/bin/defaults", "delete", bundleID)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(bundleID).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    static func removePreparedApp() {
        guard let prepared else { return }
        try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent())
        self.prepared = nil
    }

    @discardableResult
    static func shell(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw E2EError("\(tool) \(arguments.joined(separator: " ")) failed: \(output)")
        }
        return output
    }
}

// MARK: - Waiting

/// Lets the run loop turn, so nothing in the test process is starved.
func pause(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// Polls until the condition holds, or fails with what was awaited.
func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        pause(0.1)
    }
    if try condition() { return }
    throw E2EError("Timed out after \(Int(timeout)) s waiting for: \(what)")
}

// MARK: - Preferences of another app

enum Prefs {
    static func get(_ key: String, in domain: String) -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    static func set(_ key: String, _ value: Any?, in domain: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    static func removeAll(in domain: String) {
        CFPreferencesAppSynchronize(domain as CFString)
        let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String] ?? []
        for key in keys { CFPreferencesSetAppValue(key as CFString, nil, domain as CFString) }
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// The macOS screenshot settings Clipline takes over, as they were.
struct ScreenshotSettings: Equatable {
    static let domain = "com.apple.screencapture"
    static let keys = ["location", "location-screenshot", "location-screenrecording", "show-thumbnail",
                       "target", "target-screenshot", "target-screenrecording"]

    let values: [String: NSObject]

    static func current() -> ScreenshotSettings {
        var values: [String: NSObject] = [:]
        for key in keys { values[key] = Prefs.get(key, in: domain) as? NSObject }
        return ScreenshotSettings(values: values)
    }

    func restore() {
        for key in Self.keys { CFPreferencesSetAppValue(key as CFString, values[key], Self.domain as CFString) }
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }

    /// Every one pointing at the folder, saving files, without the thumbnail.
    func isTakenOver(by folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        func isFolder(_ key: String) -> Bool {
            (values[key] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path == path } ?? false
        }
        return isFolder("location") && isFolder("location-screenshot") && isFolder("location-screenrecording")
            && ["target", "target-screenshot", "target-screenrecording"].allSatisfy { values[$0] as? String == "file" }
            && values["show-thumbnail"] as? Bool == false
    }
}

/// What is on the clipboard, to put back after a test.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { data[type] = item.data(forType: type) }
            return data
        }
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}

// MARK: - The app under test

final class TestApp {
    /// Clipline's folder for this test: screenshots and copied text.
    let dataFolder: URL
    /// Stands in for the Desktop.
    let desktopFolder: URL
    var screenshots: URL { dataFolder.appendingPathComponent("Screenshots", isDirectory: true) }
    var clipboardFile: URL { dataFolder.appendingPathComponent("Clipboard.json") }
    private(set) var process: Process?

    /// ⌃⌥⇧K shows and hides the line, out of the way of everyday shortcuts.
    static let lineShortcut = (keyCode: CGKeyCode(40), flags: CGEventFlags([.maskControl, .maskAlternate, .maskShift]))

    init(root: URL) throws {
        dataFolder = root.appendingPathComponent("Data", isDirectory: true)
        desktopFolder = root.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktopFolder, withIntermediateDirectories: true)
    }

    /// A first launch that has already been through the welcome and the
    /// inbox offer, with inbox mode on.
    static func resetSettings() {
        Prefs.removeAll(in: E2E.bundleID)
        let modifiers = NSEvent.ModifierFlags([.control, .option, .shift]).rawValue
        let initial: [String: Any] = [
            "migratedFromTendedero": true,
            "welcomed": true,
            "inboxOffered": true,
            "inboxEnabled": true,
            "soundOff": true,
            "shortcut": ["keyCode": 40, "modifiers": modifiers, "key": "k"] as [String: Any],
            // No screenshot shortcut of Clipline's own.
            "captureShortcut": [String: Any](),
        ]
        for (key, value) in initial { CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, E2E.bundleID as CFString) }
        CFPreferencesAppSynchronize(E2E.bundleID as CFString)
    }

    var pid: pid_t { process?.processIdentifier ?? 0 }
    var isRunning: Bool { process?.isRunning ?? false }

    func launch() throws {
        let app = try E2E.preparedApp()
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/Clipline")
        process.arguments = ["-AppleLanguages", "(en)"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLIPLINE_DATA_DIR"] = dataFolder.path
        environment["CLIPLINE_DESKTOP_DIR"] = desktopFolder.path
        process.environment = environment
        try process.run()
        self.process = process
        try waitUntil("Clipline to finish launching") {
            NSRunningApplication(processIdentifier: process.processIdentifier)?.isFinishedLaunching == true
        }
        // The watchers start a moment after launch.
        pause(1)
    }

    /// Quit as from the menu, or when logging out.
    func quit() throws {
        guard let process, let app = NSRunningApplication(processIdentifier: process.processIdentifier) else {
            throw E2EError("Clipline is not running")
        }
        guard app.terminate() else { throw E2EError("Clipline did not accept Quit") }
        try waitUntil("Clipline to quit") { !process.isRunning }
    }

    /// `kill`: the signal handler puts the settings back.
    func terminate() throws {
        guard let process, process.isRunning else { return }
        process.terminate()
        try waitUntil("Clipline to stop on SIGTERM") { !process.isRunning }
    }

    /// A crash: nothing gets the chance to clean up.
    func crash() throws {
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        try waitUntil("Clipline to be killed") { !process.isRunning }
    }

    // MARK: What it keeps

    /// The paths hanging on the line, as saved for the next launch.
    var hanging: [String] {
        Prefs.get("pegged", in: E2E.bundleID) as? [String] ?? []
    }

    /// The copied text, newest first, as saved in its file.
    func savedNotes() -> [String] {
        guard let data = try? Data(contentsOf: clipboardFile),
              let notes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return notes.compactMap { $0["text"] as? String }
    }

    func files(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? [])
    }

    // MARK: Its windows

    /// What the app looks like now, for a failure message.
    func describeState() -> String {
        var lines = ["State of Clipline E2E (pid \(pid), running: \(isRunning)):"]
        lines.append("  frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        if let focused = element.attribute(kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let window = AX(element: focused as! AXUIElement)
            lines.append("  focused window: \(window.role ?? "?") \(window.frame.map { "\($0)" } ?? "")")
        } else {
            lines.append("  focused window: none")
        }
        if let focused = element.attribute(kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let control = AX(element: focused as! AXUIElement)
            lines.append("  focused element: \(control.role ?? "?") \(control.value ?? "")")
        }
        for window in element.windows {
            let main = window.attribute(kAXMainAttribute) as? Bool
            let focused = window.attribute(kAXFocusedAttribute) as? Bool
            lines.append("  AX window: \(window.role ?? "?")/\(window.attribute(kAXSubroleAttribute) as? String ?? "?") "
                + "\(window.frame.map { "\($0)" } ?? "") main: \(main.map { "\($0)" } ?? "?") focused: \(focused.map { "\($0)" } ?? "?")")
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in windows where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            lines.append("  on screen: layer \(info[kCGWindowLayer as String] ?? "?") \(info[kCGWindowBounds as String] ?? "")")
        }
        lines.append("  line is down: \(lineIsDown)")
        lines.append("  hanging: \(hanging.map { URL(fileURLWithPath: $0).lastPathComponent })")
        lines.append("  hanging paths: \(hanging)")
        lines.append("  saved notes: \(savedNotes())")
        lines.append("  clipboard types: \(NSPasteboard.general.types?.map(\.rawValue) ?? []), text: \(NSPasteboard.general.string(forType: .string)?.prefix(80) ?? "none")")
        return lines.joined(separator: "\n")
    }

    var element: AX { AX.application(pid) }

    /// Whether the line is down: its strip is on screen, floating at the top.
    var lineIsDown: Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.floatingWindow)),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.width > 400
        }
    }

    func pressLineShortcut() {
        Input.key(Self.lineShortcut.keyCode, flags: Self.lineShortcut.flags)
    }

    /// Brings the line down with the shortcut, unless it is already down.
    func showLine() throws {
        if !lineIsDown { pressLineShortcut() }
        try waitUntil("the line to come down") { lineIsDown }
        pause(0.5) // the slide down
    }

    /// The photo of a file, once it hangs and the line is down.
    func photo(_ name: String, timeout: TimeInterval = 10) throws -> AX {
        var found: AX?
        try waitUntil("\(name) to hang on the line", timeout: timeout) {
            found = element.first { $0.identifier == "clipline.photo." + name }
            return found?.frame != nil
        }
        return found!
    }
}

// MARK: - Accessibility

struct AX {
    let element: AXUIElement

    static func application(_ pid: pid_t) -> AX {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        return AX(element: app)
    }

    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    var children: [AX] { (attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []).map(AX.init) }
    var windows: [AX] { (attribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).map(AX.init) }
    var role: String? { attribute(kAXRoleAttribute) as? String }
    var identifier: String? { attribute(kAXIdentifierAttribute) as? String }
    var title: String? { attribute(kAXTitleAttribute) as? String }
    var value: String? { attribute(kAXValueAttribute) as? String }
    var filename: String? { attribute(kAXFilenameAttribute) as? String }

    /// In screen coordinates with the origin at the top left, as for CGEvent.
    var frame: CGRect? {
        guard let position = attribute(kAXPositionAttribute), let size = attribute(kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    func set(frame: CGRect) {
        var origin = frame.origin, size = frame.size
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    func press() {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// Breadth first, so the nearest match wins, within a bound: SwiftUI
    /// trees are deep.
    func first(maxNodes: Int = 6000, where match: (AX) -> Bool) -> AX? {
        var queue = [self], visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let next = queue.removeFirst()
            visited += 1
            if match(next) { return next }
            queue.append(contentsOf: next.children)
        }
        return nil
    }
}

// MARK: - Keyboard and mouse

enum Input {
    /// A source of its own, so the events neither take on nor change the
    /// modifier keys the system thinks are held.
    private static let source = CGEventSource(stateID: .privateState)

    private static let modifiers: [(flag: CGEventFlags, code: CGKeyCode)] = [
        (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59),
    ]

    /// Presses the modifier keys one by one, the key, then lets go of them
    /// in reverse, as fingers do. Flags set on the key alone once left
    /// Control held system wide, turning every later click into a right click.
    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let held = modifiers.filter { flags.contains($0.flag) }
        var current: CGEventFlags = []
        for modifier in held {
            current.insert(modifier.flag)
            post(modifier.code, down: true, flags: current, modifier: true)
        }
        post(code, down: true, flags: current)
        post(code, down: false, flags: current)
        for modifier in held.reversed() {
            current.remove(modifier.flag)
            post(modifier.code, down: false, flags: current, modifier: true)
        }
    }

    /// Lets go of every modifier key, whatever happened before. Run after
    /// each test, so a test that stopped halfway leaves nothing held.
    static func releaseModifiers() {
        for modifier in modifiers { post(modifier.code, down: false, flags: [], modifier: true) }
    }

    private static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if modifier { event.type = .flagsChanged }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        pause(0.04)
    }

    private static func mouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        // A plain click: no modifier key, whatever the system thinks.
        event?.flags = []
        if type == .leftMouseDown || type == .leftMouseUp {
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event?.post(tap: .cghidEventTap)
    }

    static func move(to point: CGPoint) {
        mouse(.mouseMoved, at: point)
        pause(0.05)
    }

    /// Hovers first: the line only takes the mouse once the pointer is over
    /// a photo.
    static func click(at point: CGPoint) {
        move(to: point)
        pause(0.35)
        mouse(.leftMouseDown, at: point)
        pause(0.08)
        mouse(.leftMouseUp, at: point)
        pause(0.2)
    }

    /// Presses at the start, moves through each stop, resting there for its
    /// time, and lets go at the last one.
    static func drag(from start: CGPoint, through stops: [(point: CGPoint, rest: TimeInterval)]) {
        move(to: start)
        pause(0.35)
        mouse(.leftMouseDown, at: start)
        pause(0.15)
        var current = start
        for stop in stops {
            let steps = 25
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: current.x + (stop.point.x - current.x) * t, y: current.y + (stop.point.y - current.y) * t)
                mouse(.leftMouseDragged, at: p)
                pause(0.015)
            }
            current = stop.point
            pause(stop.rest)
        }
        mouse(.leftMouseUp, at: current)
        pause(0.3)
    }
}

// MARK: - Screens and Finder

enum Screen {
    /// The main screen in CGEvent coordinates.
    static var main: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    static var menuBarHeight: CGFloat {
        guard let screen = NSScreen.screens.first else { return 24 }
        return max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Resting here brings the line down, which a drag needs.
    static var revealPoint: CGPoint { CGPoint(x: main.midX, y: main.minY + 2) }

    /// Inside the line's strip, below the menu bar, between the photos.
    static var lineBand: CGPoint { CGPoint(x: main.midX, y: main.minY + menuBarHeight + 45) }
}

enum Finder {
    static var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }

    /// Opens a Finder window on the folder, placed where the line is not.
    static func open(_ folder: URL) throws -> AX {
        NSWorkspace.shared.open(folder)
        var window: AX?
        try waitUntil("a Finder window on \(folder.lastPathComponent)") {
            guard let pid else { return false }
            window = AX.application(pid).windows.first { $0.title == folder.lastPathComponent }
            return window != nil
        }
        let screen = Screen.main
        window!.set(frame: CGRect(x: screen.minX + 120, y: screen.minY + 330, width: 640, height: 380))
        pause(0.5)
        return window!
    }

    static func item(named name: String, in window: AX) throws -> AX {
        var found: AX?
        try waitUntil("\(name) to show in Finder") {
            // Finder hides the extension unless "Show all filename
            // extensions" is on, in list view as in icon view.
            let shown = [name, (name as NSString).deletingPathExtension]
            found = window.first {
                $0.filename == name || ($0.role == kAXTextFieldRole && $0.value.map(shown.contains) == true)
            }
            return found?.frame != nil
        }
        return found!
    }

    static func close(_ window: AX) {
        if let button = window.attribute(kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() {
            AX(element: button as! AXUIElement).press()
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
