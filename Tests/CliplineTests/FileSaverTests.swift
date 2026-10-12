import XCTest
@testable import Clipline

final class FileSaverTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CliplineTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        // In a folder that does not exist yet: the saver makes it.
        return folder.appendingPathComponent("sub/file.json")
    }

    func testTheNewestSaveWins() throws {
        let url = try temporaryFile()
        let saver = FileSaver(url: url)
        for i in 0..<500 { saver.save(Data("\(i)".utf8)) }
        saver.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "499")
    }

    func testSavesFromManyThreadsEndWithTheLastOne() throws {
        let url = try temporaryFile()
        let saver = FileSaver(url: url)
        DispatchQueue.concurrentPerform(iterations: 200) { i in saver.save(Data("\(i)".utf8)) }
        saver.save(Data("last".utf8))
        saver.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "last")
    }

    func testFlushWritesWhatIsWaiting() throws {
        let url = try temporaryFile()
        let saver = FileSaver(url: url)
        saver.save(Data("a".utf8))
        saver.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a")
        // Nothing waiting: flushing again changes nothing.
        saver.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a")
    }

    func testPermissions() throws {
        let url = try temporaryFile()
        let saver = FileSaver(url: url, permissions: 0o600)
        saver.save(Data("private".utf8))
        saver.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testErrorsAreReported() throws {
        let url = try temporaryFile()
        // A file where the folder should be.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent().deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: url.deletingLastPathComponent())
        let failed = expectation(description: "error")
        let saver = FileSaver(url: url) { _ in failed.fulfill() }
        saver.save(Data("x".utf8))
        saver.flush()
        wait(for: [failed], timeout: 1)
    }
}
