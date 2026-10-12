import Foundation

/// Inbox mode: Clipline takes over where screenshots go.
///
/// It changes the macOS screenshot settings in the Options menu of
/// Cmd+Shift+5: the floating thumbnail is turned off, so the file is written
/// at once instead of five seconds later, and captures are saved as files in
/// Clipline's own folder, so the Desktop only gets what you keep. Saving to
/// the clipboard or Preview would leave nothing to hang, and a click on the
/// line copies anyway.
/// Screen recordings go there too, and hang on the line like screenshots.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching.
enum Inbox {
    /// macOS 26 and earlier read "location". macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    /// macOS 27 also keeps screen recordings apart, in
    /// "location-screenrecording"; earlier versions send them wherever
    /// "location" points.
    /// Whether a capture is saved as a file or sent to the clipboard, Preview
    /// and so on: macOS 26 and earlier read "target"; macOS 27 has one for
    /// screenshots and one for recordings.
    ///
    /// Each setting is saved under a name of its own. Recordings and the
    /// targets came later, so settings saved by an earlier version may lack
    /// them; a flag says when they were saved.
    private static let managed: [Managed] = [
        Managed(key: "location", savedAs: "location", group: nil, value: .folder),
        Managed(key: "location-screenshot", savedAs: "locationScreenshot", group: nil, value: .folder),
        Managed(key: "show-thumbnail", savedAs: "thumbnail", group: nil, value: .bool(false)),
        Managed(key: "location-screenrecording", savedAs: "locationRecording", group: "recordingSaved", value: .folder),
        Managed(key: "target", savedAs: "target", group: "targetSaved", value: .string("file")),
        Managed(key: "target-screenshot", savedAs: "targetScreenshot", group: "targetSaved", value: .string("file")),
        Managed(key: "target-screenrecording", savedAs: "targetRecording", group: "targetSaved", value: .string("file")),
    ]

    private struct Managed {
        enum Value { case folder, string(String), bool(Bool) }
        let key: String
        let savedAs: String
        /// The flag that says this one was saved, for the later ones.
        let group: String?
        let value: Value

        var ours: Any {
            switch value {
            case .folder: Inbox.folder.path
            case .string(let v): v
            case .bool(let v): v
            }
        }

        /// Whether the setting still holds what Clipline put there.
        func isOurs(_ current: Any?) -> Bool {
            switch value {
            case .folder: (current as? String).map(Inbox.isFolder) ?? false
            case .string(let v): (current as? String) == v
            case .bool(let v): (current as? Bool) == v
            }
        }

        func wasSaved(in saved: [String: Any]) -> Bool {
            group.map { saved[$0] != nil } ?? true
        }
    }

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    /// Clipline's folder holds the screenshots and the copied text. The
    /// end-to-end tests point it at a folder of their own.
    static let folder: URL = {
        if let dir = ProcessInfo.processInfo.environment["CLIPLINE_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("Screenshots", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clipline/Screenshots", isDirectory: true)
    }()

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    private static func isFolder(_ path: String) -> Bool {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            == folder.standardizedFileURL
    }

    static func apply(to settings: ScreenshotSettings = SystemScreenshotSettings(),
                      defaults: UserDefaults = .standard) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A setting that still holds our value after a crash, or after the
        // app was killed before it could restore, is not the user's: what was
        // saved for it before stays. Anything else is the user's own now.
        let before = defaults.dictionary(forKey: savedKey)
        var saved: [String: Any] = [:]
        for m in managed {
            let current = settings[m.key]
            if let before, m.wasSaved(in: before), m.isOurs(current) {
                saved[m.savedAs] = before[m.savedAs]
            } else if case .folder = m.value, m.isOurs(current) {
                // Nothing saved for it: back to the macOS default, never to
                // our folder once Clipline is no longer watching it.
                saved[m.savedAs] = nil
            } else {
                saved[m.savedAs] = current
            }
            if let group = m.group { saved[group] = true }
        }
        defaults.set(saved, forKey: savedKey)
        for m in managed { settings[m.key] = m.ours }
        settings.synchronize()
    }

    /// Puts back what was there before. A setting the user changed while
    /// Clipline had them, from the Options menu of Cmd+Shift+5 for example,
    /// is theirs and stays as it is.
    static func restore(to settings: ScreenshotSettings = SystemScreenshotSettings(),
                        defaults: UserDefaults = .standard) {
        guard let saved = defaults.dictionary(forKey: savedKey) else { return }
        for m in managed where m.isOurs(settings[m.key]) {
            settings[m.key] = saved[m.savedAs]
        }
        settings.synchronize()
        defaults.removeObject(forKey: savedKey)
    }

    /// Saves an image that has no file of its own, like a copied picture, in
    /// Clipline's folder: "<prefix> 2026-10-12 at 09.41.42.png".
    static func keep(_ png: Data, prefix: String) throws -> URL {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(prefix) \(f.string(from: Date()))"
        var url = folder.appendingPathComponent("\(name).png")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).png")
            n += 1
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            // What people copy can be private: only they can read it.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }
}

/// The macOS screenshot settings, as Inbox reads and writes them. A nil value
/// is no setting at all: macOS uses its default.
protocol ScreenshotSettings {
    subscript(key: String) -> Any? { get nonmutating set }
    func synchronize()
}

/// Writes through cfprefsd, so the screenshot service sees it at once.
struct SystemScreenshotSettings: ScreenshotSettings {
    private let domain = "com.apple.screencapture" as CFString

    subscript(key: String) -> Any? {
        get { CFPreferencesCopyAppValue(key as CFString, domain) }
        nonmutating set { CFPreferencesSetAppValue(key as CFString, newValue as CFPropertyList?, domain) }
    }

    func synchronize() {
        CFPreferencesAppSynchronize(domain)
    }
}
