import XCTest
@testable import Clipline

final class FullScreenTests: XCTestCase {
    private func display(_ id: String, type: Int) -> [String: Any] {
        ["Display Identifier": id, "Current Space": ["type": type]]
    }

    func testOneEntryForEveryScreen() {
        XCTAssertTrue(FullScreen.isFullScreen([display("Main", type: 4)], display: "A"))
        XCTAssertFalse(FullScreen.isFullScreen([display("Main", type: 0)], display: "A"))
        XCTAssertTrue(FullScreen.isFullScreen([display("Main", type: 4)], display: nil))
    }

    func testSeparateSpaces() {
        let displays = [display("A", type: 0), display("B", type: 4)]
        XCTAssertFalse(FullScreen.isFullScreen(displays, display: "A"))
        XCTAssertTrue(FullScreen.isFullScreen(displays, display: "B"))
        XCTAssertFalse(FullScreen.isFullScreen(displays, display: "C"))
        XCTAssertFalse(FullScreen.isFullScreen(displays, display: nil))
    }

    func testUnexpectedAnswersAreNotFullScreen() {
        XCTAssertFalse(FullScreen.isFullScreen([], display: "A"))
        XCTAssertFalse(FullScreen.isFullScreen([["Display Identifier": "A"]], display: "A"))
        XCTAssertFalse(FullScreen.isFullScreen([["Current Space": ["type": "4"]]], display: "A"))
        XCTAssertFalse(FullScreen.isFullScreen([["Current Space": "full"]], display: "A"))
    }
}
