import XCTest
@testable import FleetRollout

final class EvaluatorTests: XCTestCase {

    func testRuleMatchCarriesFullProvenance() {
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "duo", predicate: .onTrain([BuildTrain.ios27_1Duo.identifier]),
                        variantKey: "on", bucketRange: .full)
        ])
        let evaluator = Evaluator(document: Fixture.document(flags: [flag]), fallback: Fixture.fallback)
        let assignment = evaluator.evaluate(flag.key, for: Fixture.duoDevice)

        XCTAssertEqual(assignment.variantKey, "on")
        XCTAssertEqual(assignment.value, .bool(true))
        XCTAssertEqual(assignment.reason, .ruleMatch)
        XCTAssertEqual(assignment.matchedRuleID, "duo")
        XCTAssertEqual(assignment.documentVersion, 10)
        XCTAssertNotNil(assignment.bucket)
    }

    func testNonMatchingDeviceFallsToDeclaredDefault() {
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "duo", predicate: .onTrain([BuildTrain.ios27_1Duo.identifier]),
                        variantKey: "on")
        ])
        let evaluator = Evaluator(document: Fixture.document(flags: [flag]), fallback: Fixture.fallback)
        let assignment = evaluator.evaluate(flag.key, for: Fixture.device(train: .ios27_2))
        XCTAssertEqual(assignment.reason, .defaultVariant)
        XCTAssertEqual(assignment.variantKey, "off")
        XCTAssertNil(assignment.matchedRuleID)
    }

    /// A matched predicate whose bucket range excludes the device must fall to
    /// the *next rule*, not to the default. Otherwise a staged ramp nested inside
    /// an audience rule would shadow every broader rule beneath it.
    func testBucketMissFallsThroughToTheNextRule() {
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "canary", predicate: .always, variantKey: "on", bucketRange: .empty),
            RolloutRule(id: "everyone", predicate: .always, variantKey: "on", bucketRange: .full)
        ])
        let evaluator = Evaluator(document: Fixture.document(flags: [flag]), fallback: Fixture.fallback)
        let assignment = evaluator.evaluate(flag.key, for: Fixture.device())
        XCTAssertEqual(assignment.matchedRuleID, "everyone")
        XCTAssertEqual(assignment.reason, .ruleMatch)
    }

    /// Kill beats everything: rule order, bucket, and the document's own default.
    func testKillOverridesEveryRuleAndResolvesToCompiledInFallback() {
        let flag = Fixture.flag(
            rules: [RolloutRule(id: "all", predicate: .always, variantKey: "on")],
            killed: true)
        let fallback = FallbackCatalog(values: [flag.key: .bool(false)])
        let evaluator = Evaluator(document: Fixture.document(flags: [flag]), fallback: fallback)
        let assignment = evaluator.evaluate(flag.key, for: Fixture.duoDevice)

        XCTAssertEqual(assignment.reason, .killed)
        XCTAssertEqual(assignment.value, .bool(false))
        XCTAssertEqual(assignment.variantKey, "fallback")
        XCTAssertNil(assignment.matchedRuleID)
    }

    /// The fallback is the *app's* value, not the document's default variant.
    /// This test fails if kill is ever re-implemented as "serve the default".
    func testKillDoesNotServeTheDocumentDefaultVariant() {
        let flag = FlagDefinition(
            key: "search.rerank", salt: "s",
            variants: [
                Variant(key: "off", value: .string("server-default")),
                Variant(key: "on", value: .string("treatment"))
            ],
            defaultVariantKey: "off",
            rules: [RolloutRule(id: "all", predicate: .always, variantKey: "on")],
            killed: true)
        let evaluator = Evaluator(
            document: Fixture.document(flags: [flag]),
            fallback: FallbackCatalog(values: ["search.rerank": .string("baseline")]))
        let assignment = evaluator.evaluate("search.rerank", for: Fixture.device())
        XCTAssertEqual(assignment.value, .string("baseline"))
        XCTAssertNotEqual(assignment.value, .string("server-default"))
    }

    func testUnknownFlagAndMissingDocument() {
        let evaluator = Evaluator(document: Fixture.document(), fallback: Fixture.fallback)
        let unknown = evaluator.evaluate("nope", for: Fixture.device())
        XCTAssertEqual(unknown.reason, .unknownFlag)
        XCTAssertEqual(unknown.value, .bool(false))

        let empty = Evaluator(document: nil, fallback: Fixture.fallback)
        let none = empty.evaluate("checkout.duo_layout", for: Fixture.device())
        XCTAssertEqual(none.reason, .noDocument)
        XCTAssertNil(none.documentVersion)
        XCTAssertTrue(empty.knownFlagKeys.isEmpty)
    }

    func testMalformedRuleResolvesConservativelyRatherThanGuessing() {
        var deep = TargetingPredicate.always
        for _ in 0...TargetingPredicate.maximumDepth { deep = .all([deep]) }
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "deep", predicate: deep, variantKey: "on"),
            RolloutRule(id: "everyone", predicate: .always, variantKey: "on")
        ])
        let evaluator = Evaluator(document: Fixture.document(flags: [flag]), fallback: Fixture.fallback)
        let assignment = evaluator.evaluate(flag.key, for: Fixture.device())
        // Refusal stops evaluation entirely: a later rule must not be allowed to
        // serve past a rule we could not understand, because the unread rule may
        // have been the one that excluded this device.
        XCTAssertEqual(assignment.reason, .refusedMalformedRule)
        XCTAssertEqual(assignment.variantKey, "fallback")
    }

    func testRuleReferencingAMissingVariantDoesNotServeSomeOtherVariant() {
        let flag = FlagDefinition(
            key: "a", salt: "s",
            variants: [Variant(key: "off", value: .bool(false))],
            defaultVariantKey: "off",
            rules: [RolloutRule(id: "ghost", predicate: .always, variantKey: "ghost")])
        let evaluator = Evaluator(document: Fixture.document(flags: [flag]), fallback: .empty)
        XCTAssertEqual(evaluator.evaluate("a", for: Fixture.device()).reason, .refusedMalformedRule)
    }

    func testDuplicateFlagKeyResolvesFirstWins() {
        let document = Fixture.document(flags: [
            FlagDefinition(key: "a", salt: "s1",
                           variants: [Variant(key: "v", value: .string("first"))],
                           defaultVariantKey: "v"),
            FlagDefinition(key: "a", salt: "s2",
                           variants: [Variant(key: "v", value: .string("second"))],
                           defaultVariantKey: "v")
        ])
        let evaluator = Evaluator(document: document, fallback: .empty)
        XCTAssertEqual(evaluator.evaluate("a", for: Fixture.device()).value, .string("first"))
    }

    func testEvaluationIsDeterministicForTheSameDevice() {
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "ramp", predicate: .always, variantKey: "on", bucketRange: .percent(50))
        ])
        let evaluator = Evaluator(document: Fixture.document(flags: [flag]), fallback: Fixture.fallback)
        let device = Fixture.device("device-stable")
        let first = evaluator.evaluate(flag.key, for: device)
        // Rebuilt evaluator, fresh document instance: still the same answer,
        // because nothing in the path depends on process state.
        let second = Evaluator(document: Fixture.document(flags: [flag]), fallback: Fixture.fallback)
            .evaluate(flag.key, for: device)
        XCTAssertEqual(first, second)
    }

    func testEvaluateAllCoversEveryKnownFlag() {
        let document = Fixture.document(flags: [
            Fixture.flag(key: "a", salt: "sa"),
            Fixture.flag(key: "b", salt: "sb")
        ])
        let evaluator = Evaluator(document: document, fallback: .empty)
        XCTAssertEqual(evaluator.evaluateAll(for: Fixture.device()).map(\.flagKey), ["a", "b"])
    }

    func testFlagValueAccessors() {
        XCTAssertEqual(FlagValue.bool(true).boolValue, true)
        XCTAssertNil(FlagValue.bool(true).intValue)
        XCTAssertEqual(FlagValue.int(3).intValue, 3)
        XCTAssertEqual(FlagValue.string("x").stringValue, "x")
        XCTAssertNil(FlagValue.string("x").boolValue)
    }
}
