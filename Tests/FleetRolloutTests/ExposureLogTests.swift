import XCTest
@testable import FleetRollout

final class ExposureLogTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_758_585_600)

    private func assignment(_ flagKey: String, variant: String = "on") -> Assignment {
        Assignment(
            flagKey: flagKey, variantKey: variant, value: .bool(true),
            reason: .ruleMatch, documentVersion: 7, bucket: 42, matchedRuleID: "r1")
    }

    func testDrainReturnsEventsInArrivalOrder() async {
        let log = ExposureLog(capacity: 8, dedupeWindow: 0)
        for index in 0..<5 {
            await log.record(assignment("flag.\(index)"), at: epoch.addingTimeInterval(Double(index)))
        }
        let drain = await log.drain()
        XCTAssertEqual(drain.events.map(\.flagKey), (0..<5).map { "flag.\($0)" })
        XCTAssertEqual(drain.droppedCount, 0)
        let actual1 = await log.bufferedCount()
        XCTAssertEqual(actual1, 0)
    }

    /// A device offline for a week still reads flags on every screen. The buffer
    /// must be bounded, must keep the newest events, and must say how many it
    /// threw away — a partial dataset that does not admit it is short is worse
    /// than no dataset, because the analysis downstream divides by the wrong
    /// denominator.
    func testBufferIsBoundedAndReportsWhatItDropped() async {
        let capacity = 16
        let log = ExposureLog(capacity: capacity, dedupeWindow: 0)
        for index in 0..<200 {
            await log.record(assignment("flag.\(index)"), at: epoch.addingTimeInterval(Double(index)))
        }
        let actual2 = await log.bufferedCount()
        XCTAssertEqual(actual2, capacity)
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, capacity)
        XCTAssertEqual(drain.droppedCount, 200 - capacity)
        XCTAssertEqual(drain.events.map(\.flagKey), (184..<200).map { "flag.\($0)" })
    }

    func testRingOrderIsCorrectAtEveryHeadPosition() async {
        for extra in 0..<8 {
            let log = ExposureLog(capacity: 8, dedupeWindow: 0)
            let total = 8 + extra
            for index in 0..<total {
                await log.record(assignment("flag.\(index)"), at: epoch.addingTimeInterval(Double(index)))
            }
            let drain = await log.drain()
            let expected = ((total - 8)..<total).map { "flag.\($0)" }
            XCTAssertEqual(drain.events.map(\.flagKey), expected, "head offset \(extra)")
        }
    }

    func testZeroCapacityIsClampedRatherThanDividingByZero() async {
        let log = ExposureLog(capacity: 0, dedupeWindow: 0)
        await log.record(assignment("a"), at: epoch)
        await log.record(assignment("b"), at: epoch)
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, 1)
        XCTAssertEqual(drain.events.first?.flagKey, "b")
        XCTAssertEqual(drain.droppedCount, 1)
    }

    func testDuplicateReadsAreSuppressedAndCountedSeparatelyFromDrops() async {
        let log = ExposureLog(capacity: 64, dedupeWindow: 60)
        for _ in 0..<50 {
            await log.record(assignment("checkout.duo_layout"), at: epoch)
        }
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, 1)
        XCTAssertEqual(drain.deduplicatedCount, 49)
        XCTAssertEqual(drain.droppedCount, 0, "suppressed duplicates are not data loss")
    }

    func testDedupeWindowExpires() async {
        let log = ExposureLog(capacity: 64, dedupeWindow: 60)
        await log.record(assignment("a"), at: epoch)
        await log.record(assignment("a"), at: epoch.addingTimeInterval(30))
        await log.record(assignment("a"), at: epoch.addingTimeInterval(120))
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, 2)
        XCTAssertEqual(drain.deduplicatedCount, 1)
    }

    func testChangedVariantOrVersionIsANewExposure() async {
        let log = ExposureLog(capacity: 64, dedupeWindow: 600)
        await log.record(assignment("a", variant: "on"), at: epoch)
        await log.record(assignment("a", variant: "off"), at: epoch)
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, 2)
    }

    /// The ring is not the only thing that grows.
    ///
    /// `lastSeen` takes one entry per `(flag, variant, reason, documentVersion)`
    /// and a long-lived process sees a new document version every few minutes.
    /// Asserting `bufferedCount()` here would be vacuous — it is pinned to
    /// `capacity` by the ring, and would still hold with the dictionary bound
    /// deleted. `dedupeTableCount()` is the number that actually moves.
    func testDedupeTableDoesNotGrowWithoutBound() async {
        let capacity = 32
        let log = ExposureLog(capacity: capacity, dedupeWindow: 3_600)
        for index in 0..<5_000 {
            await log.record(assignment("flag.\(index)"), at: epoch)
            let tableSize = await log.dedupeTableCount()
            XCTAssertLessThanOrEqual(
                tableSize, SafeMath.addingSaturating(capacity, 1),
                "dedupe table reached \(tableSize) after \(index + 1) distinct keys")
        }
        let buffered = await log.bufferedCount()
        XCTAssertEqual(buffered, capacity)
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, capacity)
        XCTAssertEqual(drain.droppedCount, 5_000 - capacity)
    }

    func testCountersResetAfterDrain() async {
        let log = ExposureLog(capacity: 4, dedupeWindow: 0)
        for index in 0..<20 {
            await log.record(assignment("f.\(index)"), at: epoch)
        }
        _ = await log.drain()
        let second = await log.drain()
        XCTAssertEqual(second.events.count, 0)
        XCTAssertEqual(second.droppedCount, 0)
        XCTAssertEqual(second.deduplicatedCount, 0)
    }
}
