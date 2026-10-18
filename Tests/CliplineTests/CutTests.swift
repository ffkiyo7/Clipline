import XCTest
@testable import Clipline

/// Which clips a stroke of the scissors cuts, and where cut photos go back.
final class CutTests: XCTestCase {
    private let clips: [CGFloat] = [100, 274, 448, 622]

    func testCutsTheClipsPassedInOrder() {
        XCTAssertEqual(Line.clipsPassed(clips, from: 80, to: 500), [0, 1, 2])
        XCTAssertEqual(Line.clipsPassed(clips, from: 500, to: 80), [2, 1, 0])
    }

    func testAStrokeBetweenClipsCutsNothing() {
        XCTAssertEqual(Line.clipsPassed(clips, from: 120, to: 250), [])
    }

    func testPressingRightOnAClipCutsIt() {
        XCTAssertEqual(Line.clipsPassed(clips, from: 276, to: 276), [1])
        XCTAssertEqual(Line.clipsPassed(clips, from: 290, to: 290), [])
    }

    func testCutPhotosGoBackWhereTheyHung() {
        // Five photos hung; the second and fourth were cut, leaving three.
        var order = ["a", "c", "e"]
        for (place, name) in [(1, "b"), (3, "d")] {
            let at = Line.insertionIndex(for: place, hanging: Array(order.indices), count: order.count)
            order.insert(name, at: at)
        }
        XCTAssertEqual(order, ["a", "b", "c", "d", "e"])
    }

    func testAPhotoCutFromTheEndGoesBackLast() {
        XCTAssertEqual(Line.insertionIndex(for: 4, hanging: [0, 1, 2], count: 3), 3)
    }

    func testFallingPhotosStayBehindTheOnesPutBack() {
        // Index 1 is still falling, so the second hanging photo is at 2.
        XCTAssertEqual(Line.insertionIndex(for: 1, hanging: [0, 2, 3], count: 4), 2)
    }
}
