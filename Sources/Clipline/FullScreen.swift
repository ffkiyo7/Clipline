import AppKit

// The window server knows the type of the Space each display is showing.
// These calls are private but stable for a decade, need no permission, and
// are what window managers like yabai rely on. A full screen Space is type 4.
//
// They are looked up when first needed rather than linked: should a future
// macOS drop or rename them, Clipline still launches and the line simply
// does not keep away from full screen apps.
private typealias MainConnectionID = @convention(c) () -> Int32
private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

enum FullScreen {
    private static let fullScreenSpaceType = 4

    /// Whether the line also comes down over full screen apps, so screenshots
    /// stay within reach while you work in one. Off unless turned on: a video
    /// or a presentation should not get a clothesline across the top.
    static var showLineOver: Bool {
        get { UserDefaults.standard.bool(forKey: "showOverFullScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "showOverFullScreen") }
    }

    /// True when the line should keep away from the given screen.
    static func blocksLine(on screen: NSScreen) -> Bool {
        !showLineOver && isActive(on: screen)
    }

    /// True when the given screen is currently showing a full screen app,
    /// like a video or a presentation. False when macOS does not say.
    static func isActive(on screen: NSScreen) -> Bool {
        guard let spaces = windowServer,
              let displays = spaces.copy(spaces.connection())?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        return isFullScreen(displays, display: uuidString(for: screen))
    }

    /// Reads the window server's answer: one entry per display, or a single
    /// one covering every screen when "Displays have separate Spaces" is off.
    /// Anything unexpected counts as not full screen.
    static func isFullScreen(_ displays: [[String: Any]], display uuid: String?) -> Bool {
        let entry: [String: Any]?
        if displays.count == 1 {
            entry = displays.first
        } else {
            entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
        }
        let current = entry?["Current Space"] as? [String: Any]
        return (current?["type"] as? Int) == fullScreenSpaceType
    }

    private static let windowServer: (connection: MainConnectionID, copy: CopyManagedDisplaySpaces)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else {
            log.notice("The window server does not say which Spaces are full screen; the line will not keep away from them")
            return nil
        }
        return (unsafeBitCast(connection, to: MainConnectionID.self),
                unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
    }()

    private static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
