import XCTest
@testable import FleetRollout

final class FleetSimulatorTests: XCTestCase {

    func testGeneratorIsDeterministicAndBoundsSafe() {
        var a = SplitMix64(seed: 2026)
        var b = SplitMix64(seed: 2026)
        for _ in 0..<1_000 { XCTAssertEqual(a.next(), b.next()) }

        var c = SplitMix64(seed: 1)
        XCTAssertEqual(c.next(upperBound: 0), 0)
        XCTAssertEqual(c.next(upperBound: -4), 0)
        for _ in 0..<1_000 {
            let value = c.next(upperBound: 10)
            XCTAssertTrue((0..<10).contains(value))
            let unit = c.nextUnitInterval()
            XCTAssertTrue(unit >= 0 && unit < 1)
        }
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

    func testForkedFleetContainsBothSidesOfTheFork() {
        let fleet = FleetSimulator.makeFleet(size: 10_000)
        let trains = Set(fleet.map(\.buildTrain.identifier))
        XCTAssertTrue(trains.contains(BuildTrain.ios27_1Duo.identifier))
        XCTAssertTrue(trains.contains(BuildTrain.ios27_2.identifier))
        // Duo is a small slice of the fleet, which is what makes 27.1 leaking
        // onto 27.2 a large mistake rather than a small one.
        let duo = fleet.filter { $0.buildTrain == .ios27_1Duo }.count
        XCTAssertLessThan(SafeMath.percentage(duo, of: fleet.count), 5)
        XCTAssertGreaterThan(duo, 0)
    }

    /// End to end: the rule the industry writes versus the rule this package
    /// makes you write, run over the same 10,000-device fleet.
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

        XCTAssertLessThan(correctExposure.share(ofVariant: "on"), 0.05)
        XCTAssertGreaterThan(naiveExposure.share(ofVariant: "on"), 0.60)
        XCTAssertEqual(Set(correctExposure.treatedByTrain.keys), [BuildTrain.ios27_1Duo.identifier])
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

        XCTAssertEqual(histogram.byVariant.values.reduce(0, +), fleet.count)
        XCTAssertEqual(histogram.byReason.values.reduce(0, +), fleet.count)
        XCTAssertEqual(histogram.share(ofVariant: "on"), 0.25, accuracy: 0.03)
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
