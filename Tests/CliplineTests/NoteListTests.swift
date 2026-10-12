import XCTest
@testable import Clipline

final class NoteListTests: XCTestCase {
    private func add(_ text: String, to notes: inout [Note], limit: Int = 200, maxLength: Int = 200_000,
                     date: Date = Date()) -> Bool {
        NoteList.add(text, source: nil, date: date, to: &notes, limit: limit, maxLength: maxLength)
    }

    func testNewestFirst() {
        var notes: [Note] = []
        XCTAssertTrue(add("one", to: &notes))
        XCTAssertTrue(add("two", to: &notes))
        XCTAssertEqual(notes.map(\.text), ["two", "one"])
    }

    func testBlankAndTooLongAreNotNotes() {
        var notes: [Note] = []
        XCTAssertFalse(add("", to: &notes))
        XCTAssertFalse(add(" \n\t ", to: &notes))
        XCTAssertFalse(add("12345", to: &notes, maxLength: 4))
        XCTAssertTrue(add("1234", to: &notes, maxLength: 4))
        XCTAssertEqual(notes.map(\.text), ["1234"])
    }

    func testCopyingAgainMovesToTopAndKeepsIdentityAndPin() {
        var notes: [Note] = []
        _ = add("a", to: &notes)
        _ = add("b", to: &notes)
        notes[1].pinned = true
        let id = notes[1].id
        let later = Date(timeIntervalSinceNow: 60)
        _ = add("a", to: &notes, date: later)
        XCTAssertEqual(notes.map(\.text), ["a", "b"])
        XCTAssertEqual(notes[0].id, id)
        XCTAssertTrue(notes[0].pinned)
        XCTAssertEqual(notes[0].date, later)
    }

    func testTrimKeepsPinnedAndNewestUnpinned() {
        var notes: [Note] = []
        _ = add("old pinned", to: &notes, limit: 2)
        notes[0].pinned = true
        for text in ["1", "2", "3", "4"] { _ = add(text, to: &notes, limit: 2) }
        XCTAssertEqual(notes.map(\.text), ["4", "3", "old pinned"])
    }

    func testSortedPutsPinnedFirst() {
        var notes: [Note] = []
        for text in ["1", "2", "3"] { _ = add(text, to: &notes) }
        notes[2].pinned = true // "1"
        XCTAssertEqual(NoteList.sorted(notes).map(\.text), ["1", "3", "2"])
    }

    func testBump() {
        var notes: [Note] = []
        for text in ["1", "2", "3"] { _ = add(text, to: &notes) }
        let id = notes[2].id
        let date = Date(timeIntervalSinceNow: 60)
        XCTAssertEqual(NoteList.bump(id, date: date, in: &notes)?.text, "1")
        XCTAssertEqual(notes.map(\.text), ["1", "3", "2"])
        XCTAssertEqual(notes[0].date, date)
        XCTAssertNil(NoteList.bump(UUID(), in: &notes))
        XCTAssertEqual(notes.count, 3)
    }

    // MARK: File

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CliplineTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsWhatWasSaved() throws {
        let file = try temporaryFolder().appendingPathComponent("Clipboard.json")
        var notes: [Note] = []
        _ = add("hello", to: &notes)
        notes[0].source = Source(bundleID: "com.example", appName: "Example", windowTitle: nil)
        try JSONEncoder().encode(notes).write(to: file)
        XCTAssertEqual(NoteList.read(from: file), notes)
    }

    func testMissingFileIsNoNotes() throws {
        let file = try temporaryFolder().appendingPathComponent("Clipboard.json")
        XCTAssertEqual(NoteList.read(from: file), [])
    }

    func testUnreadableFileIsMovedAsideNotLost() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("Clipboard.json")
        let garbage = Data("not json".utf8)
        try garbage.write(to: file)
        var errors: [String] = []
        XCTAssertEqual(NoteList.read(from: file) { errors.append($0) }, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].hasPrefix("Clipboard.unreadable-") && kept[0].hasSuffix(".json"), kept[0])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(kept[0])), garbage)
        XCTAssertEqual(errors.count, 1)
    }
}
