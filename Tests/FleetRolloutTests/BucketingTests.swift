import XCTest
@testable import FleetRollout

final class BucketingTests: XCTestCase {

    func testRealBucketerMatchesGoldenVectors() {
        let failures = BucketStabilityCheck.failures(of: StableBucketer.bucket)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
    }

    /// The point of `BucketStabilityCheck` is to catch a bucketer that is not
    /// stable across processes. If the check passed for everything it would be
    /// worthless, so here it is fed the exact wrong implementation people reach
    /// for — Swift's per-process-seeded `hashValue` — and asserted to reject it.
    ///
    /// Note what a naive test would have done instead: call the broken bucketer
    /// twice in one process and assert the results match. They *would* match.
    /// `Hasher` is seeded once per process, so within a single test run the bug
    /// is completely invisible. Only a value fixed outside the process catches it.
    func testCheckRejectsAProcessSeededBucketer() {
        func brokenBucketer(flagKey: String, salt: String, stableIdentifier: String) -> Int {
            let combined = "\(flagKey):\(salt):\(stableIdentifier)"
            return abs(combined.hashValue % StableBucketer.bucketSpace)
        }
        let failures = BucketStabilityCheck.failures(of: brokenBucketer)
        XCTAssertFalse(
            failures.isEmpty,
            "the stability check accepted a hashValue-based bucketer, so it proves nothing")

        // And the thing the naive test would have asserted, demonstrated to hold
        // for the broken implementation too.
        XCTAssertEqual(
            brokenBucketer(flagKey: "a", salt: "b", stableIdentifier: "c"),
            brokenBucketer(flagKey: "a", salt: "b", stableIdentifier: "c"))
    }

    func testCheckRejectsAStatefulBucketer() {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        func statefulBucketer(flagKey: String, salt: String, stableIdentifier: String) -> Int {
            counter.value += 1
            return counter.value % StableBucketer.bucketSpace
        }
        XCTAssertFalse(BucketStabilityCheck.failures(of: statefulBucketer).isEmpty)
    }

    func testBucketAlwaysInsideBucketSpace() {
        for index in 0..<5_000 {
            let bucket = StableBucketer.bucket(
                flagKey: "flag.\(index % 7)",
                salt: "salt-\(index % 3)",
                stableIdentifier: "device-\(index)")
            XCTAssertGreaterThanOrEqual(bucket, 0)
            XCTAssertLessThan(bucket, StableBucketer.bucketSpace)
        }
    }

    func testBucketHandlesEmptyAndUnicodeInput() {
        XCTAssertGreaterThanOrEqual(
            StableBucketer.bucket(flagKey: "", salt: "", stableIdentifier: ""), 0)
        let unicode = StableBucketer.bucket(
            flagKey: "🚀.flag", salt: "सॉल्ट", stableIdentifier: "device-😀")
        XCTAssertLessThan(unicode, StableBucketer.bucketSpace)
    }

    func testDistributionIsApproximatelyUniform() {
        let range = BucketRange.percent(10)
        var inside = 0
        let population = 40_000
        for index in 0..<population {
            let bucket = StableBucketer.bucket(
                flagKey: "checkout.duo_layout", salt: "s1", stableIdentifier: "device-\(index)")
            if range.contains(bucket) { inside += 1 }
        }
        let share = SafeMath.percentage(inside, of: population)
        XCTAssertEqual(share, 10, accuracy: 0.75, "10% ramp landed \(share)% of the fleet")
    }

    /// Two 10% rollouts with *different* salts should overlap on about 1% of the
    /// fleet. Sharing a salt would make the overlap 10% — the same tenth of the
    /// fleet in every experiment the company runs.
    func testDistinctSaltsDecorrelateRollouts() {
        let range = BucketRange.percent(10)
        let population = 40_000
        var both = 0
        var sharedSaltBoth = 0
        for index in 0..<population {
            let identifier = "device-\(index)"
            let a = StableBucketer.bucket(flagKey: "flag.a", salt: "salt-a", stableIdentifier: identifier)
            let b = StableBucketer.bucket(flagKey: "flag.b", salt: "salt-b", stableIdentifier: identifier)
            if range.contains(a) && range.contains(b) { both += 1 }

            // Same salt *and* same flag key is the degenerate case: identical
            // hash input, so the two rollouts are the same population exactly.
            let c = StableBucketer.bucket(flagKey: "flag.a", salt: "salt-a", stableIdentifier: identifier)
            if range.contains(a) && range.contains(c) { sharedSaltBoth += 1 }
        }
        XCTAssertEqual(SafeMath.percentage(both, of: population), 1.0, accuracy: 0.3)
        XCTAssertEqual(SafeMath.percentage(sharedSaltBoth, of: population), 10.0, accuracy: 0.75)
    }

    /// Widening a ramp must never evict a device that was already treated.
    func testRampIsMonotonicAndNeverEvicts() {
        let identifiers = (0..<3_000).map { "device-\($0)" }
        var previouslyTreated = Set<String>()
        for percent in stride(from: 1.0, through: 100.0, by: 9.0) {
            let range = BucketRange.percent(percent)
            var treated = Set<String>()
            for identifier in identifiers {
                let bucket = StableBucketer.bucket(
                    flagKey: "checkout.duo_layout", salt: "s1", stableIdentifier: identifier)
                if range.contains(bucket) { treated.insert(identifier) }
            }
            XCTAssertTrue(
                previouslyTreated.isSubset(of: treated),
                "widening the ramp to \(percent)% evicted \(previouslyTreated.subtracting(treated).count) devices")
            previouslyTreated = treated
        }
        XCTAssertEqual(previouslyTreated.count, identifiers.count)
    }

    func testBucketRangeClampsAndNormalises() {
        XCTAssertEqual(BucketRange(lowerBasisPoints: -50, upperBasisPoints: 99_999).lowerBasisPoints, 0)
        XCTAssertEqual(
            BucketRange(lowerBasisPoints: -50, upperBasisPoints: 99_999).upperBasisPoints,
            StableBucketer.bucketSpace)
        // Inverted normalises to empty — fail closed, nobody in the rollout.
        let inverted = BucketRange(lowerBasisPoints: 900, upperBasisPoints: 100)
        XCTAssertTrue(inverted.isEmpty)
        XCTAssertFalse(inverted.contains(500))
        XCTAssertTrue(BucketRange.empty.isEmpty)
        XCTAssertFalse(BucketRange.empty.contains(0))
        XCTAssertTrue(BucketRange.full.contains(0))
        XCTAssertFalse(BucketRange.full.contains(StableBucketer.bucketSpace))
    }

    func testFailureDescriptionNamesTheMismatch() {
        struct AlwaysZero {
            static func bucket(flagKey: String, salt: String, stableIdentifier: String) -> Int { 0 }
        }
        let failures = BucketStabilityCheck.failures(
            of: AlwaysZero.bucket(flagKey:salt:stableIdentifier:),
            vectors: [BucketStabilityCheck.goldenVectors[0]])
        guard let failure = failures.first else {
            return XCTFail("expected a mismatch against an always-zero bucketer")
        }
        XCTAssertEqual(
            failure.description,
            "bucket(checkout.duo_layout, s1, device-0000) == 0, expected 1411")
    }

    func testPercentHelperSurvivesNonsenseInput() {
        XCTAssertTrue(BucketRange.percent(.nan).isEmpty)
        XCTAssertEqual(BucketRange.percent(.infinity).upperBasisPoints, StableBucketer.bucketSpace)
        XCTAssertTrue(BucketRange.percent(-10).isEmpty)
        XCTAssertEqual(BucketRange.percent(0.01).upperBasisPoints, 1)
    }
}
