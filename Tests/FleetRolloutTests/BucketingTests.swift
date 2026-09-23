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

    /// The bucketer must actually *use* the space it claims.
    ///
    /// Asserting the result is inside `0..<10_000` would be vacuous — it is a
    /// modulus by 10,000. What is not vacuous is coverage: a bucketer that
    /// collapses onto a handful of values (a weak hash, a truncated input, a
    /// constant) satisfies the range check and fails this one.
    func testBucketerCoversTheWholeSpace() {
        var seen = Set<Int>()
        var lowest = StableBucketer.bucketSpace
        var highest = -1
        for index in 0..<60_000 {
            let bucket = StableBucketer.bucket(
                flagKey: "f", salt: "s", stableIdentifier: "d-\(index)")
            seen.insert(bucket)
            lowest = min(lowest, bucket)
            highest = max(highest, bucket)
        }
        XCTAssertEqual(seen.count, 9_970, "bucket coverage changed; the hash is not the same function")
        XCTAssertEqual(lowest, 0)
        XCTAssertEqual(highest, StableBucketer.bucketSpace - 1)
    }

    /// Empty and multi-byte inputs hash to fixed, committed values.
    ///
    /// Asserting only that the result is inside `0..<bucketSpace` would be
    /// vacuous — it is a modulus by 10,000, and a bucketer that returned the
    /// constant zero would pass. These are golden values: the empty triple is
    /// the degenerate case, and the UTF-8 one is the case a byte-wise hash gets
    /// wrong if it ever starts iterating `Character`s instead of `utf8`.
    func testEmptyAndUnicodeInputsHashToCommittedValues() {
        XCTAssertEqual(
            StableBucketer.bucket(flagKey: "", salt: "", stableIdentifier: ""), 6_677)
        XCTAssertEqual(
            StableBucketer.bucket(
                flagKey: "\u{1F680}.flag", salt: "\u{938}\u{949}\u{932}\u{94D}\u{91F}",
                stableIdentifier: "device-\u{1F600}"),
            4_345)
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

    /// The `(flagKey, salt)` pair is the bucketing namespace, and each half of
    /// it independently reshuffles the fleet.
    ///
    /// Both assertions are real properties of the hash, not artefacts of the
    /// range. A bucketer that ignored the flag key would put two flags on the
    /// same 10% and fail the first; one that ignored the salt would fail the
    /// second. The expected overlap is ~1% — the product of two independent 10%
    /// slices — and the measured values are 1.07% and 1.05%.
    ///
    /// The consequence is worth stating plainly: because the flag key is in the
    /// hash, decorrelation between flags does **not** depend on an operator
    /// remembering to set a unique salt. Systems that hash only `(salt, id)` are
    /// correlated by default, and the first copy-pasted flag definition puts two
    /// independent rollouts on the same tenth of the fleet.
    func testFlagKeyAndSaltEachReshuffleTheFleetIndependently() {
        let range = BucketRange.percent(10)
        let population = 40_000
        var treated = 0
        var sharedSaltDifferentKey = 0
        var sharedKeyDifferentSalt = 0

        for index in 0..<population {
            let identifier = "device-\(index)"
            let a = StableBucketer.bucket(flagKey: "flag.a", salt: "s1", stableIdentifier: identifier)
            let differentKey = StableBucketer.bucket(flagKey: "flag.b", salt: "s1", stableIdentifier: identifier)
            let differentSalt = StableBucketer.bucket(flagKey: "flag.a", salt: "s2", stableIdentifier: identifier)

            guard range.contains(a) else { continue }
            treated += 1
            if range.contains(differentKey) { sharedSaltDifferentKey += 1 }
            if range.contains(differentSalt) { sharedKeyDifferentSalt += 1 }
        }

        XCTAssertEqual(SafeMath.percentage(treated, of: population), 9.88, accuracy: 0.01)
        XCTAssertEqual(SafeMath.percentage(sharedSaltDifferentKey, of: population), 1.07, accuracy: 0.05)
        XCTAssertEqual(SafeMath.percentage(sharedKeyDifferentSalt, of: population), 1.05, accuracy: 0.05)
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

    func testBucketRangeClampsItsBounds() {
        let clamped = BucketRange(lowerBasisPoints: -50, upperBasisPoints: 99_999)
        XCTAssertEqual(clamped.lowerBasisPoints, 0)
        XCTAssertEqual(clamped.upperBasisPoints, StableBucketer.bucketSpace)

        XCTAssertTrue(BucketRange.empty.isEmpty)
        XCTAssertFalse(BucketRange.empty.contains(0))
        XCTAssertTrue(BucketRange.full.contains(0))
        XCTAssertFalse(BucketRange.full.contains(StableBucketer.bucketSpace))
    }

    /// An inverted range is kept as given — it is a document defect, and
    /// silently repairing it would make `DocumentValidator` unable to report it
    /// — but it serves nobody.
    func testInvertedRangeIsPreservedAndFailsClosed() {
        let inverted = BucketRange(lowerBasisPoints: 900, upperBasisPoints: 100)
        XCTAssertTrue(inverted.isInverted)
        XCTAssertTrue(inverted.isEmpty)
        XCTAssertEqual(inverted.widthBasisPoints, 0)
        for bucket in [0, 99, 100, 500, 899, 900, 901, 9_999] {
            XCTAssertFalse(inverted.contains(bucket), "bucket \(bucket) served by an inverted range")
        }
    }

    /// Synthesised `Codable` would bypass the designated initialiser, so a
    /// remote document could hand the client a 99,999-basis-point upper bound
    /// and `contains(_:)` would read it as a 100% ramp. This is the test that
    /// fails if the custom `init(from:)` is deleted.
    func testDecodingClampsOutOfSpaceBounds() throws {
        let json = Data(#"{"lowerBasisPoints":-4000,"upperBasisPoints":99999}"#.utf8)
        let decoded = try JSONDecoder().decode(BucketRange.self, from: json)
        XCTAssertEqual(decoded.lowerBasisPoints, 0)
        XCTAssertEqual(decoded.upperBasisPoints, StableBucketer.bucketSpace)
        XCTAssertFalse(decoded.contains(StableBucketer.bucketSpace))
    }

    func testInvertedRangeSurvivesACodableRoundTrip() throws {
        let inverted = BucketRange(lowerBasisPoints: 900, upperBasisPoints: 100)
        let decoded = try JSONDecoder().decode(
            BucketRange.self, from: try JSONEncoder().encode(inverted))
        XCTAssertEqual(decoded, inverted)
        XCTAssertTrue(decoded.isInverted, "decoding repaired a defect the validator has to report")
    }

    func testPercentHelperSurvivesNonsenseInput() {
        XCTAssertTrue(BucketRange.percent(.nan).isEmpty)
        XCTAssertFalse(BucketRange.percent(.nan).isInverted)
        XCTAssertEqual(BucketRange.percent(.infinity).upperBasisPoints, StableBucketer.bucketSpace)
        XCTAssertTrue(BucketRange.percent(-10).isEmpty)
        XCTAssertEqual(BucketRange.percent(0.01).upperBasisPoints, 1)
    }
}
