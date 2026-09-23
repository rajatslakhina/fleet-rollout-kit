import XCTest
@testable import FleetRollout

final class FleetSimulatorTests: XCTestCase {

    /// SplitMix64 against committed outputs, not against itself.
    ///
    /// Drawing twice from two generators with the same seed and asserting they
    /// agree proves only that the function is a function. The golden vector is
    /// what makes a changed constant, a changed shift, or a swapped multiplier
    /// fail — and changing any of those silently re-buckets every simulated
    /// fleet this package has ever reported a number for.
    func testGeneratorMatchesItsGoldenVector() {
        var generator = SplitMix64(seed: 2026)
        XCTAssertEqual(generator.next(), 15_824_617_304_438_902_051)
        XCTAssertEqual(generator.next(), 8_699_989_649_721_214_301)
        XCTAssertEqual(generator.next(), 12_310_341_597_754_734_734)
        XCTAssertEqual(generator.next(), 7_097_835_237_234_771_186)
    }

    /// The bounded draw has to be uniform and has to reach every value.
    ///
    /// `(0..<10).contains(value)` holds by construction of the modulus; that a
    /// generator stuck on one value would fail does not.
    func testBoundedDrawCoversItsRangeUniformly() {
        var generator = SplitMix64(seed: 1)
        var histogram: [Int: Int] = [:]
        for _ in 0..<1_000 { histogram[generator.next(upperBound: 10), default: 0] += 1 }

        XCTAssertEqual(Set(histogram.keys), Set(0..<10))
        for (value, count) in histogram {
            XCTAssertGreaterThan(count, 60, "value \(value) drawn only \(count) times in 1,000")
            XCTAssertLessThan(count, 150, "value \(value) drawn \(count) times in 1,000")
        }

        // A non-positive bound must yield 0 rather than trapping on a zero modulus.
        XCTAssertEqual(generator.next(upperBound: 0), 0)
        XCTAssertEqual(generator.next(upperBound: -4), 0)

        var unitGenerator = SplitMix64(seed: 5)
        var lowest = 1.0
        var highest = 0.0
        for _ in 0..<20_000 {
            let unit = unitGenerator.nextUnitInterval()
            lowest = min(lowest, unit)
            highest = max(highest, unit)
        }
        XCTAssertLessThan(lowest, 0.001)
        XCTAssertGreaterThan(highest, 0.999)
        XCTAssertGreaterThanOrEqual(lowest, 0)
        XCTAssertLessThan(highest, 1)
    }

    func testFleetIsDeterministicAcrossRuns() {
        let a = FleetSimulator.makeFleet(size: 500)
        let b = FleetSimulator.makeFleet(size: 500)
        XCTAssertEqual(a, b)
        let c = FleetSimulator.makeFleet(size: 500, seed: 1)
        XCTAssertNotEqual(a, c)
    }

    func testEmptyAndNegativeFleetSizes() {
        XCTAssertTrue(FleetSimulator.makeFleet(size: 0).isEmpty)
        XCTAssertTrue(FleetSimulator.makeFleet(size: -5).isEmpty)
        XCTAssertTrue(FleetSimulator.makeFleet(
            size: 10,
            composition: FleetComposition(cohorts: [], appBuilds: [1])).isEmpty)
        XCTAssertTrue(FleetSimulator.makeFleet(
            size: 10,
            composition: FleetComposition(
                cohorts: [.init(train: .ios27_2, deviceClass: .phoneStandard,
                                posture: .fixed, weight: 0)],
                appBuilds: [1])).isEmpty)
    }

    func testCompositionSubstitutesAnAppBuildWhenNoneGiven() {
        let composition = FleetComposition(
            cohorts: [.init(train: .ios27_2, deviceClass: .phoneStandard,
                            posture: .fixed, weight: 1)],
            appBuilds: [])
        let fleet = FleetSimulator.makeFleet(size: 10, composition: composition)
        XCTAssertEqual(fleet.count, 10)
        XCTAssertTrue(fleet.allSatisfy { $0.appBuild == 1 })
    }

    /// The weighted cohort sampler has to honour its weights.
    ///
    /// Asserting only that Duo is "under 5%" would be vacuous — the composition
    /// declares a weight of 2 out of 100. These are exact counts for a fixed
    /// seed and fixed size, which is what makes the sampler's `pick <
    /// cohort.weight` walk testable at all: an off-by-one in that loop shifts
    /// every cohort.
    func testWeightedCohortSamplerHonoursItsWeights() {
        let fleet = FleetSimulator.makeFleet(size: 10_000)
        let byTrain = Dictionary(grouping: fleet, by: \.buildTrain.identifier)
            .mapValues(\.count)

        XCTAssertEqual(byTrain[BuildTrain.ios27_1Duo.identifier], 210)
        XCTAssertEqual(byTrain[BuildTrain.ios27_2.identifier], 7_032)
        XCTAssertEqual(byTrain[BuildTrain.ios27_0.identifier], 1_983)
        XCTAssertEqual(byTrain[BuildTrain.ios26_5.identifier], 775)
        XCTAssertEqual(Set(byTrain.keys).count, 4)

        // Duo is a 2% slice of the fleet, which is exactly what makes 27.1
        // leaking onto 27.2 a large mistake rather than a small one.
        XCTAssertEqual(SafeMath.percentage(210, of: fleet.count), 2.1, accuracy: 0.001)
    }

    /// End to end: the rule the industry writes versus the rule this package
    /// makes you write, run over the same 10,000-device fleet.
    ///
    /// The device counts are asserted exactly rather than as loose bounds, so a
    /// regression from 210 treated devices to 490 fails here instead of sliding
    /// under a `< 5%` assertion. These are the numbers the READMEs quote.
    func testVersionComparisonWouldHaveOverExposedTheFleet() {
        let fleet = FleetSimulator.makeFleet(size: 10_000)

        let correct = Fixture.flag(rules: [
            RolloutRule(id: "duo", predicate: .onTrain([BuildTrain.ios27_1Duo.identifier]),
                        variantKey: "on")
        ])
        let correctExposure = FleetSimulator.exposure(
            of: correct.key,
            evaluator: Evaluator(document: Fixture.document(flags: [correct]), fallback: Fixture.fallback),
            fleet: fleet,
            treatedVariantKeys: ["on"])

        // What `osVersion >= 27.1` actually selects: 27.1 *and* everything that
        // shipped after it, including the mainline 27.2 that never ran 27.1.
        let naive = Fixture.flag(key: "naive", salt: "s2", rules: [
            RolloutRule(
                id: "gte",
                predicate: .onTrain([
                    BuildTrain.ios27_1Duo.identifier, BuildTrain.ios27_2.identifier
                ]),
                variantKey: "on")
        ])
        let naiveExposure = FleetSimulator.exposure(
            of: naive.key,
            evaluator: Evaluator(document: Fixture.document(flags: [naive]), fallback: Fixture.fallback),
            fleet: fleet,
            treatedVariantKeys: ["on"])

        XCTAssertEqual(correctExposure.byVariant["on"], 210)
        XCTAssertEqual(naiveExposure.byVariant["on"], 7_242)
        XCTAssertEqual(correctExposure.share(ofVariant: "on"), 0.021, accuracy: 0.0001)
        XCTAssertEqual(naiveExposure.share(ofVariant: "on"), 0.7242, accuracy: 0.0001)
        XCTAssertEqual(Set(correctExposure.treatedByTrain.keys), [BuildTrain.ios27_1Duo.identifier])
        XCTAssertEqual(correctExposure.treatedByTrain[BuildTrain.ios27_1Duo.identifier], 210)
    }

    func testExposureTalliesSumToTheFleetSize() {
        let fleet = FleetSimulator.makeFleet(size: 3_000)
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "ramp", predicate: .always, variantKey: "on", bucketRange: .percent(25))
        ])
        let histogram = FleetSimulator.exposure(
            of: flag.key,
            evaluator: Evaluator(document: Fixture.document(flags: [flag]), fallback: Fixture.fallback),
            fleet: fleet,
            treatedVariantKeys: ["on"])

        // The two totals hold by construction of the accumulation loop; they
        // are here as a guard, not as the point of the test.
        XCTAssertEqual(histogram.byVariant.values.reduce(0, +), fleet.count)
        XCTAssertEqual(histogram.byReason.values.reduce(0, +), fleet.count)

        // These are the assertions with content: an exact treated count for a
        // fixed fleet at a fixed 25% ramp, and the reason split — a device
        // outside the bucket falls to the declared default rather than being
        // recorded as a rule match.
        XCTAssertEqual(histogram.byVariant["on"], 755)
        XCTAssertEqual(histogram.share(ofVariant: "on"), 0.2517, accuracy: 0.0005)
        XCTAssertEqual(histogram.byReason[.ruleMatch], 755)
        XCTAssertEqual(histogram.byReason[.defaultVariant], 2_245)
        XCTAssertEqual(histogram.share(ofVariant: "missing"), 0)
    }

    func testExposureOverAnEmptyFleet() {
        let histogram = FleetSimulator.exposure(
            of: "any",
            evaluator: Evaluator(document: Fixture.document(), fallback: .empty),
            fleet: [])
        XCTAssertEqual(histogram.fleetSize, 0)
        XCTAssertEqual(histogram.share(ofVariant: "on"), 0)
        XCTAssertTrue(histogram.byVariant.isEmpty)
    }

    func testRampingPreservesRuleShapeAndOnlyMovesTheWidth() {
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "duo", predicate: .onTrain(["ios-27.1-duo"]),
                        variantKey: "on", bucketRange: .percent(1))
        ])
        let ramped = flag.ramped(toBasisPoints: 5_000)
        XCTAssertEqual(ramped.rules.map(\.id), flag.rules.map(\.id))
        XCTAssertEqual(ramped.rules.map(\.predicate), flag.rules.map(\.predicate))
        XCTAssertEqual(ramped.salt, flag.salt, "ramping must never re-salt")
        XCTAssertEqual(ramped.rules.first?.bucketRange.upperBasisPoints, 5_000)
    }

    func testKillingAllFlagsBumpsTheVersionAndKillsEveryFlag() {
        let document = Fixture.document(version: 3, flags: [
            Fixture.flag(key: "a", salt: "sa"), Fixture.flag(key: "b", salt: "sb")
        ])
        let killed = document.killingAll(bumpingVersionTo: 4)
        XCTAssertEqual(killed.documentVersion, 4)
        XCTAssertTrue(killed.flags.allSatisfy(\.killed))
        XCTAssertFalse(document.flags.contains(where: \.killed), "the original must be untouched")
    }

    func testUpdatingFlagTouchesOnlyTheNamedFlag() {
        let document = Fixture.document(version: 3, flags: [
            Fixture.flag(key: "a", salt: "sa"), Fixture.flag(key: "b", salt: "sb")
        ])
        let updated = document.updatingFlag("a", bumpingVersionTo: 4) { $0.settingKilled(true) }
        XCTAssertEqual(updated.flags.first { $0.key == "a" }?.killed, true)
        XCTAssertEqual(updated.flags.first { $0.key == "b" }?.killed, false)
    }
}
