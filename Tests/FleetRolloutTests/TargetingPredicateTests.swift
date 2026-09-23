import XCTest
@testable import FleetRollout

final class TargetingPredicateTests: XCTestCase {

    /// The headline bug this package exists to make unexpressible.
    ///
    /// iOS 27.1 shipped only to iPhone Duo. A device on 27.2 never ran it. Under
    /// `osVersion >= "27.1"` — the check almost every flag in the industry uses —
    /// that 27.2 device is in the audience. Under set membership it is not, and
    /// there is no `>=` operator over trains to get it wrong with.
    func testTrainTargetingDoesNotLeakOntoALaterFork() {
        let duoOnly = TargetingPredicate.onTrain([BuildTrain.ios27_1Duo.identifier])

        XCTAssertEqual(duoOnly.matches(Fixture.duoDevice), .matched)
        XCTAssertEqual(duoOnly.matches(Fixture.device(train: .ios27_2)), .notMatched)
        XCTAssertEqual(duoOnly.matches(Fixture.device(train: .ios27_0)), .notMatched)

        // And the comparison that would have gone wrong, spelled out: 27.2 sorts
        // above 27.1 on every numeric comparison anyone would write.
        XCTAssertTrue(
            BuildTrain.ios27_2.marketingVersion.compare(
                BuildTrain.ios27_1Duo.marketingVersion, options: .numeric) == .orderedDescending)
    }

    func testLineageTargetingCoversTrainsThatDoNotExistYet() {
        let exclusive = TargetingPredicate.onLineage([.deviceExclusive])
        XCTAssertEqual(exclusive.matches(Fixture.duoDevice), .matched)
        XCTAssertEqual(exclusive.matches(Fixture.device(train: .ios27_2)), .notMatched)
    }

    func testScalarPredicates() {
        XCTAssertEqual(TargetingPredicate.always.matches(Fixture.device()), .matched)
        XCTAssertEqual(TargetingPredicate.never.matches(Fixture.device()), .notMatched)
        XCTAssertEqual(
            TargetingPredicate.deviceClass([.phoneDuo]).matches(Fixture.duoDevice), .matched)
        XCTAssertEqual(
            TargetingPredicate.posture(.foldable).matches(Fixture.duoDevice), .matched)
        XCTAssertEqual(
            TargetingPredicate.posture(.foldable).matches(Fixture.device()), .notMatched)
        XCTAssertEqual(
            TargetingPredicate.appBuildAtLeast(1_201).matches(Fixture.device(appBuild: 1_201)),
            .matched)
        XCTAssertEqual(
            TargetingPredicate.appBuildAtLeast(1_202).matches(Fixture.device(appBuild: 1_201)),
            .notMatched)
        XCTAssertEqual(
            TargetingPredicate.appBuildAtMost(1_200).matches(Fixture.device(appBuild: 1_201)),
            .notMatched)
    }

    func testAttributePredicateMissingKeyIsNotAMatch() {
        let predicate = TargetingPredicate.attribute(key: "cohort", anyOf: ["beta"])
        XCTAssertEqual(predicate.matches(Fixture.device()), .notMatched)
        XCTAssertEqual(
            predicate.matches(Fixture.device(attributes: ["cohort": "beta"])), .matched)
        XCTAssertEqual(
            predicate.matches(Fixture.device(attributes: ["cohort": "ga"])), .notMatched)
    }

    func testAttributeBagIsBoundedAndTruncationIsDeterministic() {
        let attributes = Dictionary(
            uniqueKeysWithValues: (0..<200).map { (String(format: "k%03d", $0), "v") })
        let first = Fixture.device(attributes: attributes)
        let second = Fixture.device(attributes: attributes)
        XCTAssertEqual(first.attributes.count, DeviceContext.maximumAttributeCount)
        XCTAssertEqual(first.attributes, second.attributes)
        XCTAssertNotNil(first.attributes["k000"])
        XCTAssertNil(first.attributes["k199"])
    }

    func testDepthLimitRefusesRatherThanReturningFalse() {
        var predicate = TargetingPredicate.always
        for _ in 0..<(TargetingPredicate.maximumDepth + 5) {
            predicate = .all([predicate])
        }
        XCTAssertEqual(predicate.matches(Fixture.device()), .refusedDepthExceeded)
        XCTAssertGreaterThan(predicate.depth(), TargetingPredicate.maximumDepth)
    }

    /// "Unknown" must survive negation and disjunction. If `not(refused)` folded
    /// to `.matched`, a document nested too deep to parse would become a 100%
    /// rollout — the worst possible reading of "we could not understand this".
    func testRefusalPropagatesThroughNotAndAny() {
        var deep = TargetingPredicate.always
        for _ in 0..<(TargetingPredicate.maximumDepth + 2) { deep = .all([deep]) }

        XCTAssertEqual(TargetingPredicate.not(deep).matches(Fixture.device()), .refusedDepthExceeded)
        XCTAssertEqual(
            TargetingPredicate.any([.never, deep]).matches(Fixture.device()), .refusedDepthExceeded)
        // A genuine match short-circuits ahead of the refusal, which is correct:
        // the answer is known regardless of the branch we declined.
        XCTAssertEqual(
            TargetingPredicate.any([.always, deep]).matches(Fixture.device()), .matched)
        XCTAssertEqual(
            TargetingPredicate.all([.never, deep]).matches(Fixture.device()), .notMatched)
    }

    func testDepthComputationSaturatesOnPathologicalNesting() {
        var predicate = TargetingPredicate.always
        for _ in 0..<1_000 { predicate = .not(predicate) }
        XCTAssertEqual(predicate.depth(), TargetingPredicate.maximumDepth + 1)
    }

    func testBooleanCombinators() {
        let duoOn27_1 = TargetingPredicate.all([
            .onTrain([BuildTrain.ios27_1Duo.identifier]),
            .deviceClass([.phoneDuo])
        ])
        XCTAssertEqual(duoOn27_1.matches(Fixture.duoDevice), .matched)
        XCTAssertEqual(duoOn27_1.matches(Fixture.device(deviceClass: .phoneDuo)), .notMatched)

        let either = TargetingPredicate.any([.onTrain(["ios-27.0"]), .deviceClass([.pad])])
        XCTAssertEqual(either.matches(Fixture.device(train: .ios27_0)), .matched)
        XCTAssertEqual(either.matches(Fixture.device(deviceClass: .pad)), .matched)
        XCTAssertEqual(either.matches(Fixture.device()), .notMatched)

        XCTAssertEqual(TargetingPredicate.not(.never).matches(Fixture.device()), .matched)
    }

    func testPredicateRoundTripsThroughCodable() throws {
        let predicate = TargetingPredicate.all([
            .onTrain([BuildTrain.ios27_1Duo.identifier, BuildTrain.ios27_2.identifier]),
            .any([.deviceClass([.phoneDuo, .phonePro]), .posture(.foldable)]),
            .not(.attribute(key: "cohort", anyOf: ["internal"]))
        ])
        let data = try JSONEncoder().encode(predicate)
        let decoded = try JSONDecoder().decode(TargetingPredicate.self, from: data)
        XCTAssertEqual(decoded, predicate)
    }
}
