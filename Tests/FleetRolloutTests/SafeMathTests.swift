import XCTest
@testable import FleetRollout

final class SafeMathTests: XCTestCase {

    func testAdditionSaturatesInsteadOfTrapping() {
        XCTAssertEqual(SafeMath.addingSaturating(Int.max, 1), Int.max)
        XCTAssertEqual(SafeMath.addingSaturating(Int.min, -1), Int.min)
        XCTAssertEqual(SafeMath.addingSaturating(2, 3), 5)
    }

    func testMultiplicationSaturatesWithCorrectSign() {
        XCTAssertEqual(SafeMath.multiplyingSaturating(Int.max, 2), Int.max)
        XCTAssertEqual(SafeMath.multiplyingSaturating(Int.max, -2), Int.min)
        XCTAssertEqual(SafeMath.multiplyingSaturating(Int.min, -1), Int.max)
        XCTAssertEqual(SafeMath.multiplyingSaturating(-3, -4), 12)
    }

    func testDivisionCoversBothTrappingCases() {
        XCTAssertNil(SafeMath.dividing(1, by: 0))
        XCTAssertNil(SafeMath.dividing(Int.min, by: -1))
        XCTAssertEqual(SafeMath.dividing(9, by: 2), 4)
        XCTAssertNil(SafeMath.remainder(1, 0))
        XCTAssertNil(SafeMath.remainder(Int.min, -1))
        XCTAssertEqual(SafeMath.remainder(9, 2), 1)
    }

    func testDoubleToIntNeverTraps() {
        XCTAssertEqual(SafeMath.clampedInt(.nan), 0)
        XCTAssertEqual(SafeMath.clampedInt(.infinity), Int.max)
        XCTAssertEqual(SafeMath.clampedInt(-.infinity), Int.min)
        XCTAssertEqual(SafeMath.clampedInt(1e300), Int.max)
        XCTAssertEqual(SafeMath.clampedInt(-1e300), Int.min)
        XCTAssertEqual(SafeMath.clampedInt(42.9), 42)
        XCTAssertEqual(SafeMath.clampedInt(-42.9), -42)
    }

    func testClampedIndexRefusesEmptyCollections() {
        XCTAssertNil(SafeMath.clampedIndex(0, count: 0))
        XCTAssertNil(SafeMath.clampedIndex(-5, count: 0))
        XCTAssertEqual(SafeMath.clampedIndex(-5, count: 3), 0)
        XCTAssertEqual(SafeMath.clampedIndex(99, count: 3), 2)
        XCTAssertEqual(SafeMath.clampedIndex(1, count: 3), 1)
    }

    func testPercentageOfZeroIsZeroNotNaN() {
        XCTAssertEqual(SafeMath.percentage(5, of: 0), 0)
        XCTAssertEqual(SafeMath.percentage(5, of: -1), 0)
        XCTAssertEqual(SafeMath.percentage(1, of: 4), 25, accuracy: 0.0001)
    }
}
