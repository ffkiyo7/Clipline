#if os(macOS)
import AppKit
import ApplicationServices
import XCTest

/// Each test gets a fresh app with empty settings and folders of its own.
/// Whatever happens, the screenshot settings and the clipboard are put back
/// as they were, and the test's folders are removed.
class E2ETestCase: XCTestCase {
    var app: TestApp!
    var root: URL!
    var finderWindows: [AX] = []
    let token = String(UUID().uuidString.prefix(8))
    private var settingsBefore: ScreenshotSettings!
    private var pasteboard: PasteboardSnapshot!

    override func setUpWithError() throws {
        try E2E.checkPrerequisites()
        continueAfterFailure = false
        settingsBefore = ScreenshotSettings.current()
        pasteboard = PasteboardSnapshot()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CliplineE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The same spelling the app will use, /private/var rather than /var.
        root = folder.resolvingSymlinksInPath()
        TestApp.resetSettings()
        app = try TestApp(root: root)
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        try? app.terminate()
        if app.isRunning { try? app.crash() }
        finderWindows.forEach(Finder.close)
        settingsBefore.restore()
        pasteboard.restore()
        Prefs.removeAll(in: E2E.bundleID)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(E2E.bundleID).plist")
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: root)
    }

    var originalSettings: ScreenshotSettings { settingsBefore }

    // MARK: Doing what a person does

    /// ⌘⇧3, the system's own screenshot. Returns the file's name once it
    /// hangs on the line.
    @discardableResult
    func takeScreenshot() throws -> String {
        let before = app.files(in: app.screenshots)
        pause(1.1) // a new second, so a new name
        Input.key(20, flags: [.maskCommand, .maskShift]) // 3
        var new: [String] = []
        try waitUntil("⌘⇧3 to save a screenshot in Clipline's folder. Is it on in System Settings → Keyboard → Keyboard Shortcuts → Screenshots?",
                      timeout: 15) {
            new = app.files(in: app.screenshots).subtracting(before).filter { $0.hasSuffix(".png") }.sorted()
            return !new.isEmpty
        }
        // More than one display saves one file each; the first will do.
        let name = new[0]
        try waitUntil("\(name) to hang on the line") { isHanging(name) }
        return name
    }

    /// As if copied in any app.
    func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func isHanging(_ name: String) -> Bool {
        app.hanging.contains { URL(fileURLWithPath: $0).lastPathComponent == name }
    }

    func waitForTakeover() throws {
        try waitUntil("inbox mode to take over the screenshot settings") {
            ScreenshotSettings.current().isTakenOver(by: app.screenshots)
        }
    }

    /// Clicks the cross in the photo's top left corner.
    func discard(_ name: String) throws {
        try app.showLine()
        let frame = try XCTUnwrap(app.photo(name).frame)
        Input.move(to: frame.center)
        pause(0.3)
        Input.click(at: CGPoint(x: frame.minX + 6, y: frame.minY + 6))
    }

    func noteCount() -> String? {
        app.element.first { $0.identifier == "clipline.noteCount" }?.value
    }
}

// MARK: - 1. Screenshot, hang, copy, drag and drop, discard

final class LineFlowTests: E2ETestCase {
    func testScreenshotHangsIsCopiedDraggedDroppedAndDiscarded() throws {
        try app.launch()
        try waitForTakeover()

        // Screenshots taken the usual way hang on the line.
        let first = try takeScreenshot()
        let second = try takeScreenshot()

        // A click copies the picture and its file.
        try app.showLine()
        let firstFrame = try XCTUnwrap(app.photo(first).frame)
        Input.click(at: firstFrame.center)
        try waitUntil("the screenshot to be on the clipboard") {
            guard let item = NSPasteboard.general.pasteboardItems?.first, item.types.contains(.png),
                  let link = item.string(forType: .fileURL), let url = URL(string: link) else { return false }
            return url.lastPathComponent == first
        }

        // Dragged into a Finder folder, it moves there and leaves the line.
        let kept = root.appendingPathComponent("Kept \(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let window = try Finder.open(kept)
        finderWindows.append(window)
        try app.showLine()
        let secondFrame = try XCTUnwrap(app.photo(second).frame)
        let windowFrame = try XCTUnwrap(window.frame)
        Input.drag(from: secondFrame.center, through: [(point: windowFrame.center, rest: 0.6)])
        try waitUntil("the screenshot to move into the Finder folder") {
            app.files(in: kept).contains(second) && !app.files(in: app.screenshots).contains(second)
        }
        try waitUntil("the moved screenshot to leave the line") { !isHanging(second) }

        // Dragged from Finder onto the line, a file hangs where it is.
        let itemFrame = try XCTUnwrap(Finder.item(named: second, in: window).frame)
        Input.drag(from: itemFrame.center,
                   through: [(point: Screen.revealPoint, rest: 0.8), (point: Screen.lineBand, rest: 0.8)])
        try waitUntil("the file dropped on the line to hang") {
            app.hanging.contains { $0 == kept.appendingPathComponent(second).path }
        }

        // The cross sends a screenshot in Clipline's folder to the Trash.
        try discard(first)
        try waitUntil("the discarded screenshot to leave its folder and the line") {
            !app.files(in: app.screenshots).contains(first) && !isHanging(first)
        }

        // A file from anywhere else only comes off the line; the file stays.
        try discard(second)
        try waitUntil("the file from elsewhere to come off the line") { !isHanging(second) }
        XCTAssertTrue(app.files(in: kept).contains(second), "a file from outside Clipline's folder must never be deleted")
    }
}

// MARK: - 2. Copied text: recorded, saved, brought back

final class CopiedTextTests: E2ETestCase {
    func testCopiedTextIsRecordedSavedAndComesBack() throws {
        try app.launch()
        let older = "Clipline E2E older \(token)", newer = "Clipline E2E newer \(token)"
        copyText(older)
        pause(1)
        copyText(newer)
        try waitUntil("both copies to be saved, newest first") { app.savedNotes() == [newer, older] }

        // The clip on the line counts them, and opens the list.
        try app.showLine()
        try waitUntil("the note clip to count 2") { noteCount() == "2" }
        let clip = try XCTUnwrap(app.element.first { $0.identifier == "clipline.noteCount" }?.frame)
        Input.click(at: clip.center)

        // Picking the older one copies it again and moves it to the top.
        var row: AX?
        try waitUntil("the older note in the list") {
            row = app.element.first { $0.role == kAXStaticTextRole && $0.value == older }
            return row?.frame != nil
        }
        let rowFrame = try XCTUnwrap(row?.frame)
        Input.click(at: rowFrame.center)
        try waitUntil("the picked note on the clipboard") { NSPasteboard.general.string(forType: .string) == older }
        try waitUntil("the picked note to move to the top") { app.savedNotes() == [older, newer] }

        // After quitting and opening again, the same notes, in the same order.
        try app.quit()
        XCTAssertEqual(app.savedNotes(), [older, newer])
        try app.launch()
        try app.showLine()
        try waitUntil("the note clip to count 2 after the restart") { noteCount() == "2" }
        XCTAssertEqual(app.savedNotes(), [older, newer])
    }

    func testAnUnreadableHistoryFileIsSetAsideNotOverwritten() throws {
        let damaged = Data("{ not the notes".utf8)
        try damaged.write(to: app.clipboardFile)
        try app.launch()
        let text = "Clipline E2E after damage \(token)"
        copyText(text)
        try waitUntil("the new copy to be saved") { app.savedNotes() == [text] }
        let aside = app.files(in: app.dataFolder).filter { $0.hasPrefix("Clipboard.unreadable-") }
        XCTAssertEqual(aside.count, 1, "the damaged file should be kept aside")
        if let name = aside.first {
            XCTAssertEqual(try Data(contentsOf: app.dataFolder.appendingPathComponent(name)), damaged)
        }
    }

    /// What used to go wrong: saves could land out of order, and quitting
    /// dropped one still waiting. Copy quickly, quit at once, lose nothing.
    func testQuittingRightAfterCopyingLosesNothing() throws {
        try app.launch()
        let texts = (1...12).map { "Clipline E2E burst \($0) \(token)" }
        for text in texts {
            copyText(text)
            pause(0.6) // the clipboard is looked at twice a second
        }
        try app.terminate()
        XCTAssertEqual(app.savedNotes(), Array(texts.reversed()))
    }
}

// MARK: - 3. The shortcut, and the line coming down and going up

final class ShowingTheLineTests: E2ETestCase {
    func testShortcutAndMenuBarBringTheLineDownAndUp() throws {
        try app.launch()
        XCTAssertFalse(app.lineIsDown, "the line starts tucked away")

        app.pressLineShortcut()
        try waitUntil("the shortcut to bring the line down") { app.lineIsDown }
        try waitUntil("the empty line's hint") {
            app.element.first { $0.value == "Take a screenshot and it will hang here" } != nil
        }
        app.pressLineShortcut()
        try waitUntil("the shortcut to put the line away") { !app.lineIsDown }

        // With something on it, resting the pointer at the top of the screen
        // brings it down, and moving away puts it back.
        copyText("Clipline E2E \(token)")
        try waitUntil("the copy to be saved") { !app.savedNotes().isEmpty }
        Input.move(to: Screen.main.center)
        pause(0.5)
        Input.move(to: Screen.revealPoint)
        try waitUntil("resting at the top to bring the line down") { app.lineIsDown }
        Input.move(to: Screen.main.center)
        try waitUntil("the line to go back up when the pointer leaves") { !app.lineIsDown }
    }
}

// MARK: - 4. The macOS screenshot settings

final class ScreenshotSettingsTests: E2ETestCase {
    func testTakenOverAndGivenBackKeepingWhatYouChanged() throws {
        try app.launch()
        try waitForTakeover()
        // Screenshots now land in Clipline's folder.
        try takeScreenshot()

        // Meanwhile the floating thumbnail is turned back on, as from the
        // Options menu of ⌘⇧5.
        Prefs.set("show-thumbnail", true, in: ScreenshotSettings.domain)

        try app.quit()
        var expected = originalSettings.values
        expected["show-thumbnail"] = NSNumber(value: true)
        XCTAssertEqual(ScreenshotSettings.current(), ScreenshotSettings(values: expected),
                       "everything else comes back as it was, and the thumbnail stays as you set it")
    }

    func testGivenBackAfterACrash() throws {
        try app.launch()
        try waitForTakeover()
        try app.crash()
        XCTAssertTrue(ScreenshotSettings.current().isTakenOver(by: app.screenshots), "a crash cannot give them back")

        // Next time it starts, and then stops, they come back as they were
        // before the crash, not as Clipline's own.
        try app.launch()
        try waitForTakeover()
        try app.terminate()
        XCTAssertEqual(ScreenshotSettings.current(), originalSettings)
    }
}

// MARK: - 5. After a restart

final class RestartTests: E2ETestCase {
    func testEverythingIsAsItWasAfterARestart() throws {
        try app.launch()
        try waitForTakeover()
        let shot = try takeScreenshot()
        let text = "Clipline E2E restart \(token)"
        copyText(text)
        try waitUntil("the copy to be saved") { app.savedNotes() == [text] }
        let hanging = app.hanging

        try app.quit()
        XCTAssertEqual(ScreenshotSettings.current(), originalSettings, "quitting gives the settings back")

        try app.launch()
        try waitForTakeover()
        XCTAssertEqual(app.hanging, hanging)
        XCTAssertEqual(app.savedNotes(), [text])
        try app.showLine()
        _ = try app.photo(shot)
        try waitUntil("the note clip to be back") { noteCount() == "1" }
    }
}
#endif
