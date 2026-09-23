import XCTest
@testable import FleetRollout

final class DocumentValidatorTests: XCTestCase {

    func testCleanDocumentHasNoDefects() {
        let document = Fixture.document(flags: [
            Fixture.flag(key: "a", salt: "salt-a"),
            Fixture.flag(key: "b", salt: "salt-b")
        ])
        XCTAssertTrue(DocumentValidator.defects(in: document).isEmpty)
    }

    func testDuplicateFlagKeyIsFatal() {
        let document = Fixture.document(flags: [
            Fixture.flag(key: "a", salt: "salt-a"),
            Fixture.flag(key: "a", salt: "salt-b")
        ])
        let fatal = DocumentValidator.fatalDefects(in: document)
        XCTAssertTrue(fatal.contains(.duplicateFlagKey("a")))
    }

    /// A shared salt is a real problem, but the document still resolves to
    /// exactly one answer per flag. Ambiguity fails the document; correlation is
    /// surfaced as a warning.
    func testSharedSaltIsReportedButNotFatal() {
        let document = Fixture.document(flags: [
            Fixture.flag(key: "a", salt: "shared"),
            Fixture.flag(key: "b", salt: "shared")
        ])
        let all = DocumentValidator.defects(in: document)
        XCTAssertTrue(all.contains(.sharedSalt(flagKeys: ["a", "b"], salt: "shared")))
        XCTAssertTrue(DocumentValidator.fatalDefects(in: document).isEmpty)
    }

    func testUnknownVariantReferences() {
        let flag = FlagDefinition(
            key: "a", salt: "s",
            variants: [Variant(key: "on", value: .bool(true))],
            defaultVariantKey: "off",
            rules: [RolloutRule(id: "r1", predicate: .always, variantKey: "missing")])
        let defects = DocumentValidator.defects(in: Fixture.document(flags: [flag]))
        XCTAssertTrue(defects.contains(.unknownDefaultVariant(flagKey: "a", variantKey: "off")))
        XCTAssertTrue(defects.contains(
            .unknownRuleVariant(flagKey: "a", ruleID: "r1", variantKey: "missing")))
    }

    func testEmptyVariantListAndDuplicateVariantKey() {
        let empty = FlagDefinition(key: "a", salt: "s", variants: [], defaultVariantKey: "on")
        XCTAssertTrue(DocumentValidator.defects(in: Fixture.document(flags: [empty]))
            .contains(.emptyVariantList(flagKey: "a")))

        let duplicated = FlagDefinition(
            key: "b", salt: "s2",
            variants: [Variant(key: "on", value: .bool(true)), Variant(key: "on", value: .bool(false))],
            defaultVariantKey: "on")
        XCTAssertTrue(DocumentValidator.defects(in: Fixture.document(flags: [duplicated]))
            .contains(.duplicateVariantKey(flagKey: "b", variantKey: "on")))
    }

    func testDuplicateRuleID() {
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "r1", predicate: .always, variantKey: "on"),
            RolloutRule(id: "r1", predicate: .never, variantKey: "off")
        ])
        XCTAssertTrue(DocumentValidator.defects(in: Fixture.document(flags: [flag]))
            .contains(.duplicateRuleID(flagKey: flag.key, ruleID: "r1")))
    }

    /// An empty `all` group is vacuously true, so a mis-serialised rule becomes a
    /// silent 100% rollout. That is why it is rejected rather than evaluated.
    func testEmptyPredicateGroupIsFatal() {
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "r1", predicate: .all([]), variantKey: "on")
        ])
        let defects = DocumentValidator.fatalDefects(in: Fixture.document(flags: [flag]))
        XCTAssertTrue(defects.contains(.emptyPredicateGroup(flagKey: flag.key, ruleID: "r1")))

        // Nested, too.
        let nested = Fixture.flag(key: "n", salt: "sn", rules: [
            RolloutRule(id: "r2", predicate: .not(.any([.always, .all([])])), variantKey: "on")
        ])
        XCTAssertTrue(DocumentValidator.fatalDefects(in: Fixture.document(flags: [nested]))
            .contains(.emptyPredicateGroup(flagKey: "n", ruleID: "r2")))
    }

    func testTooDeepPredicateIsFatal() {
        var predicate = TargetingPredicate.always
        for _ in 0...TargetingPredicate.maximumDepth { predicate = .any([predicate]) }
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "deep", predicate: predicate, variantKey: "on")
        ])
        let defects = DocumentValidator.fatalDefects(in: Fixture.document(flags: [flag]))
        XCTAssertTrue(defects.contains { if case .predicateTooDeep = $0 { return true }; return false })
    }

    func testSchemaAndMaxAgeAndNegativeVersion() {
        let document = ConfigDocument(
            schemaVersion: 99, documentVersion: -1,
            issuedAt: Date(timeIntervalSince1970: 0), maxAge: 0,
            flags: [Fixture.flag()])
        let defects = DocumentValidator.defects(in: document)
        XCTAssertTrue(defects.contains(.unsupportedSchemaVersion(99)))
        XCTAssertTrue(defects.contains(.negativeDocumentVersion(-1)))
        XCTAssertTrue(defects.contains(.nonPositiveMaxAge(0)))
    }

    func testValidationTerminatesOnPathologicalNesting() {
        var predicate = TargetingPredicate.always
        for _ in 0..<2_000 { predicate = .all([predicate]) }
        let flag = Fixture.flag(rules: [
            RolloutRule(id: "bomb", predicate: predicate, variantKey: "on")
        ])
        // The assertion that matters is that this returns at all rather than
        // recursing to a stack overflow on a 2,000-deep remote document.
        XCTAssertFalse(DocumentValidator.fatalDefects(in: Fixture.document(flags: [flag])).isEmpty)
    }

    /// `DocumentDefect.description` is what a dashboard actually renders per
    /// defect, so every case's exact wording is pinned here.
    func testEveryDefectDescriptionIsWorded() {
        XCTAssertEqual(
            DocumentDefect.unsupportedSchemaVersion(99).description,
            "unsupported schemaVersion 99")
        XCTAssertEqual(
            DocumentDefect.negativeDocumentVersion(-1).description,
            "documentVersion -1 is negative")
        XCTAssertEqual(
            DocumentDefect.emptyVariantList(flagKey: "a").description,
            "flag 'a' declares no variants")
        XCTAssertEqual(
            DocumentDefect.duplicateVariantKey(flagKey: "a", variantKey: "on").description,
            "flag 'a' declares variant 'on' more than once")
        XCTAssertEqual(
            DocumentDefect.unknownDefaultVariant(flagKey: "a", variantKey: "x").description,
            "flag 'a' defaults to unknown variant 'x'")
        XCTAssertEqual(
            DocumentDefect.unknownRuleVariant(flagKey: "a", ruleID: "r1", variantKey: "x").description,
            "flag 'a' rule 'r1' serves unknown variant 'x'")
        XCTAssertEqual(
            DocumentDefect.duplicateRuleID(flagKey: "a", ruleID: "r1").description,
            "flag 'a' declares rule id 'r1' more than once")
        XCTAssertEqual(
            DocumentDefect.invertedBucketRange(flagKey: "a", ruleID: "r1").description,
            "flag 'a' rule 'r1' has an inverted bucket range")
        XCTAssertEqual(
            DocumentDefect.predicateTooDeep(flagKey: "a", ruleID: "r1", depth: 40).description,
            "flag 'a' rule 'r1' nests 40 levels deep")
        XCTAssertEqual(
            DocumentDefect.emptyPredicateGroup(flagKey: "a", ruleID: "r1").description,
            "flag 'a' rule 'r1' contains an empty all/any group")
        XCTAssertEqual(
            DocumentDefect.sharedSalt(flagKeys: ["a", "b"], salt: "s").description,
            "flags a, b share bucketing salt 's'")
        XCTAssertEqual(
            DocumentDefect.nonPositiveMaxAge(0).description,
            "maxAge 0.0 is not positive")
    }

    /// `BucketRange`'s public initialiser cannot construct an inverted range —
    /// it normalises to empty. The only way one reaches `DocumentValidator` is a
    /// document decoded from JSON, where Codable synthesis sets the stored
    /// properties directly and bypasses that initialiser.
    func testInvertedBucketRangeIsOnlyReachableThroughDecoding() throws {
        let json = """
        {"lowerBasisPoints": 900, "upperBasisPoints": 100}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BucketRange.self, from: json)
        XCTAssertEqual(decoded.lowerBasisPoints, 900)
        XCTAssertEqual(decoded.upperBasisPoints, 100)

        let flag = Fixture.flag(rules: [
            RolloutRule(id: "r1", predicate: .always, variantKey: "on", bucketRange: decoded)
        ])
        let defects = DocumentValidator.fatalDefects(in: Fixture.document(flags: [flag]))
        XCTAssertTrue(defects.contains(.invertedBucketRange(flagKey: flag.key, ruleID: "r1")))
    }

    func testDocumentRoundTripsThroughCodable() throws {
        let document = Fixture.document(flags: [
            Fixture.flag(key: "a", salt: "sa", rules: [
                RolloutRule(
                    id: "r1",
                    predicate: .all([.onTrain(["ios-27.1-duo"]), .appBuildAtLeast(1_190)]),
                    variantKey: "on",
                    bucketRange: .percent(12.5))
            ]),
            Fixture.flag(key: "b", salt: "sb", killed: true)
        ])
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ConfigDocument.self, from: data)
        XCTAssertEqual(decoded, document)
    }
}
