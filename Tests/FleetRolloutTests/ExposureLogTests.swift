import XCTest
@testable import FleetRollout

final class ExposureLogTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_758_585_600)

    private func assignment(_ flagKey: String, variant: String = "on") -> Assignment {
        Assignment(
            flagKey: flagKey, variantKey: variant, value: .bool(true),
            reason: .ruleMatch, documentVersion: 7, bucket: 42, matchedRuleID: "r1")
    }

    /// `dedupeKey` folds a nil `documentVersion` (the fallback/no-document
    /// path) into `"-"` rather than `Optional.none`'s string form, so two
    /// fallback exposures for the same flag still dedupe against each other.
    func testDedupeKeyFoldsAMissingDocumentVersion() async {
        let log = ExposureLog(capacity: 8, dedupeWindow: 60)
        let noDocument = Assignment(
            flagKey: "a", variantKey: "fallback", value: .bool(false),
            reason: .noDocument, documentVersion: nil, bucket: nil, matchedRuleID: nil)
        await log.record(noDocument, at: epoch)
        await log.record(noDocument, at: epoch.addingTimeInterval(1))
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, 1, "two nil-documentVersion reads within the window should dedupe")
        XCTAssertEqual(drain.deduplicatedCount, 1)
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

    func testDedupeTableDoesNotGrowWithoutBound() async {
        let log = ExposureLog(capacity: 32, dedupeWindow: 3_600)
        for index in 0..<5_000 {
            await log.record(assignment("flag.\(index)"), at: epoch)
        }
        // The observable guarantee: memory is bounded by capacity, and the log
        // still functions afterwards.
        let actual3 = await log.bufferedCount()
        XCTAssertEqual(actual3, 32)
        let drain = await log.drain()
        XCTAssertEqual(drain.events.count, 32)
        XCTAssertGreaterThan(drain.droppedCount, 0)
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
