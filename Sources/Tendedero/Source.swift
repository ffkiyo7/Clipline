import AppKit

/// Where a capture came from: the app, and the window title when macOS lets
/// us read it. Shown on the tag that hangs from each photo.
struct Source: Codable, Equatable {
    var bundleID: String?
    var appName: String
    /// Window titles need Screen Recording access. Without it this is nil
    /// and the tag only names the app.
    var windowTitle: String?

    /// The app's icon, cached: every photo from the same app shares one.
    @MainActor var icon: NSImage? {
        guard let bundleID else { return nil }
        if let cached = Source.icons[bundleID] { return cached }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        Source.icons[bundleID] = icon
        return icon
    }

    @MainActor private static var icons: [String: NSImage] = [:]

    // MARK: Finding it

    /// Screenshot apps that take focus while capturing. When one of them is
    /// in front, the app that was captured is the window under the pointer.
    private static let captureTools: Set<String> = [
        "com.Snipaste", "com.snipaste.Snipaste", "cc.ffitch.shottr", "com.pixpin.pixpin",
        "pl.maketheweb.cleanshotx", "com.apple.screencaptureui", "com.apple.Screenshot",
    ]

    /// A capture whose area is known (system screenshots record it): the
    /// frontmost normal window over the middle of that area. Otherwise the
    /// frontmost app, or the window under the pointer when the frontmost app
    /// is the screenshot tool itself.
    @MainActor static func detect(captureRect: CGRect?) -> Source? {
        if let rect = captureRect {
            return window(at: CGPoint(x: rect.midX, y: rect.midY))
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !captureTools.contains(front.bundleIdentifier ?? "") {
            let appName = front.localizedName ?? ""
            return Source(bundleID: front.bundleIdentifier, appName: appName,
                          windowTitle: distinct(title(ofFrontWindowOf: front.processIdentifier), from: appName))
        }
        return window(at: NSEvent.mouseLocation)
    }

    /// The topmost ordinary window containing a point in AppKit screen
    /// coordinates, skipping Tendedero and the screenshot tools.
    @MainActor private static func window(at point: CGPoint) -> Source? {
        guard let main = NSScreen.screens.first else { return nil }
        // Window bounds are measured from the top of the main screen.
        let cgPoint = CGPoint(x: point.x, y: main.frame.maxY - point.y)
        for info in windows() {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(cgPoint),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid),
                  !captureTools.contains(app.bundleIdentifier ?? "") else { continue }
            let appName = app.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? ""
            return Source(bundleID: app.bundleIdentifier, appName: appName,
                          windowTitle: distinct(nonEmpty(info[kCGWindowName as String] as? String), from: appName))
        }
        return nil
    }

    private static func title(ofFrontWindowOf pid: pid_t) -> String? {
        let own = windows().first { $0[kCGWindowOwnerPID as String] as? pid_t == pid }
        return nonEmpty(own?[kCGWindowName as String] as? String)
    }

    /// On-screen windows in the normal layer, front to back.
    private static func windows() -> [[String: Any]] {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.filter {
            $0[kCGWindowLayer as String] as? Int == 0
                && $0[kCGWindowOwnerPID as String] as? pid_t != me
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
    }

    /// A window named after its app adds nothing to the tag.
    private static func distinct(_ title: String?, from appName: String) -> String? {
        guard let title, title.caseInsensitiveCompare(appName) != .orderedSame else { return nil }
        return title
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: How the tag shows

    enum TagStyle: String, CaseIterable {
        case icon, name, hidden
    }

    /// Source tags, from the menu bar. Icon only out of the box.
    static var tagStyle: TagStyle {
        get { TagStyle(rawValue: UserDefaults.standard.string(forKey: "sourceTag") ?? "") ?? .icon }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sourceTag") }
    }
}
