import XCTest
@testable import Clipline

/// The screenshot settings, in memory.
private final class FakeSettings: ScreenshotSettings {
    var values: [String: Any] = [:]
    subscript(key: String) -> Any? {
        get { values[key] }
        set { values[key] = newValue }
    }
    func synchronize() {}
}

final class InboxTests: XCTestCase {
    private var settings: FakeSettings!
    private var defaults: UserDefaults!
    private let folder = Inbox.folder.path

    override func setUp() {
        settings = FakeSettings()
        let suite = "CliplineTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private func apply() { Inbox.apply(to: settings, defaults: defaults) }
    private func restore() { Inbox.restore(to: settings, defaults: defaults) }

    private func assertTakenOver(file: StaticString = #filePath, line: UInt = #line) {
        for key in ["location", "location-screenshot", "location-screenrecording"] {
            XCTAssertEqual(settings[key] as? String, folder, key, file: file, line: line)
        }
        for key in ["target", "target-screenshot", "target-screenrecording"] {
            XCTAssertEqual(settings[key] as? String, "file", key, file: file, line: line)
        }
        XCTAssertEqual(settings["show-thumbnail"] as? Bool, false, file: file, line: line)
    }

    private let userSettings: [String: Any] = [
        "location": "~/Pictures/Shots",
        "location-screenshot": "~/Pictures/Shots",
        "location-screenrecording": "~/Movies",
        "show-thumbnail": true,
        "target": "clipboard",
        "target-screenshot": "clipboard",
        "target-screenrecording": "file",
    ]

    private func assertSettings(_ expected: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NSDictionary(dictionary: settings.values), NSDictionary(dictionary: expected), file: file, line: line)
    }

    func testRestoresWhatWasThere() {
        settings.values = userSettings
        apply()
        assertTakenOver()
        restore()
        assertSettings(userSettings)
    }

    func testRestoresMacOSDefaults() {
        apply()
        assertTakenOver()
        restore()
        assertSettings([:])
    }

    func testKeepsWhatTheUserChangedMeanwhile() {
        settings.values = userSettings
        apply()
        // From the Options menu of Cmd+Shift+5 while Clipline had them.
        settings["location-screenshot"] = "~/Documents"
        settings["show-thumbnail"] = true
        restore()
        var expected = userSettings
        expected["location-screenshot"] = "~/Documents"
        assertSettings(expected)
    }

    func testRestoringTwiceOrWithoutApplyingChangesNothing() {
        settings.values = userSettings
        restore()
        assertSettings(userSettings)

        apply()
        restore()
        settings["show-thumbnail"] = false // the user turns it off afterwards
        restore()
        var expected = userSettings
        expected["show-thumbnail"] = false
        assertSettings(expected)
    }

    func testApplyingAgainAfterACrashKeepsTheUsersSettings() {
        settings.values = userSettings
        apply()
        // The app was killed: nothing was restored. Next launch applies again.
        apply()
        assertTakenOver()
        restore()
        assertSettings(userSettings)
    }

    func testOurFolderIsNeverSavedAsTheUsers() {
        // Left applied, and what was saved is gone.
        settings.values = ["location": folder, "location-screenshot": folder, "location-screenrecording": "~/Movies"]
        apply()
        restore()
        assertSettings(["location-screenrecording": "~/Movies"])
    }

    func testSettingsSavedByAnEarlierVersion() {
        // Before recordings and targets were saved, macOS had these from the
        // user, and Clipline had only taken over the location and thumbnail.
        settings.values = [
            "location": folder, "location-screenshot": folder, "show-thumbnail": false,
            "location-screenrecording": "~/Movies", "target": "preview",
        ]
        defaults.set(["location": "~/Desktop/Shots", "thumbnail": true], forKey: "inboxSavedSettings")
        apply()
        assertTakenOver()
        restore()
        assertSettings([
            "location": "~/Desktop/Shots", "show-thumbnail": true,
            "location-screenrecording": "~/Movies", "target": "preview",
        ])
    }

    func testFolderWithTildeOrTrailingSlashIsOurs() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard folder.hasPrefix(home + "/") else { return }
        let tilde = "~" + folder.dropFirst(home.count) + "/"
        settings.values = ["location": tilde, "location-screenshot": tilde]
        apply()
        restore()
        assertSettings([:])
    }
}
