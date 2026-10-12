import Foundation

/// Clipline began as a fork of Tendedero, under Tendedero's name and bundle
/// identifier. The first launch as Clipline carries everything over: the
/// settings, Tendedero's folder with the screenshots and copied text in it,
/// and macOS's screenshot location when it pointed there. Tendedero's own
/// settings are left as they were.
enum Migration {
    private static let doneKey = "migratedFromTendedero"
    private static let oldDomain = "app.tendedero.Tendedero"

    /// Before anything reads the settings.
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("Tendedero", isDirectory: true)
        let newFolder = support.appendingPathComponent("Clipline", isDirectory: true)
        if fm.fileExists(atPath: oldFolder.path) && !fm.fileExists(atPath: newFolder.path) {
            do {
                try fm.moveItem(at: oldFolder, to: newFolder)
            } catch {
                log.error("Could not move Tendedero's folder: \(error.localizedDescription, privacy: .public)")
            }
        }
        let moved = fm.fileExists(atPath: newFolder.path) && !fm.fileExists(atPath: oldFolder.path)

        /// A path in the old folder, now in the new one.
        func fix(_ path: String) -> String {
            let prefix = oldFolder.path + "/"
            guard moved, path.hasPrefix(prefix) else { return path }
            return newFolder.path + "/" + path.dropFirst(prefix.count)
        }

        for (key, value) in old where defaults.object(forKey: key) == nil {
            switch value {
            case let paths as [String] where key == "pegged":
                defaults.set(paths.map(fix), forKey: key)
            case let byPath as [String: Any] where key == "peggedSources" || key == "usedFiles":
                defaults.set(Dictionary(byPath.map { (fix($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }), forKey: key)
            default:
                defaults.set(value, forKey: key)
            }
        }

        // Screenshots kept going to the old folder: they go to the new one.
        if moved {
            let domain = "com.apple.screencapture" as CFString
            let oldScreenshots = oldFolder.appendingPathComponent("Screenshots").path
            let newScreenshots = newFolder.appendingPathComponent("Screenshots").path
            for key in ["location", "location-screenshot", "location-screenrecording"] {
                guard let current = CFPreferencesCopyAppValue(key as CFString, domain) as? String,
                      URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL.path == oldScreenshots
                else { continue }
                CFPreferencesSetAppValue(key as CFString, newScreenshots as CFString, domain)
            }
            CFPreferencesAppSynchronize(domain)
        }
        log.notice("Carried over Tendedero's settings; folder moved: \(moved, privacy: .public)")
    }
}
