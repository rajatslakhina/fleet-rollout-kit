import Foundation

/// Why a device got the value it got.
///
/// Every assignment carries one. A flag system whose answers are not
/// attributable is a flag system you cannot debug from a crash report, and the
/// question a lead is actually asked at 2am is never "what is the value" — it is
/// "why did *this* device get it".
public enum EvaluationReason: String, Hashable, Sendable, Codable {
    /// A targeting rule matched and the device fell inside its bucket range.
    case ruleMatch
    /// No rule matched; the flag's declared default was served.
    case defaultVariant
    /// The flag is killed. Overrides everything.
    case killed
    /// The flag is not in the served document. Compiled-in fallback used.
    case unknownFlag
    /// No document could be served at all. Compiled-in fallback used.
    case noDocument
    /// A rule's predicate exceeded the depth limit, so the flag was resolved
    /// conservatively from the fallback instead of being guessed at.
    case refusedMalformedRule
}

/// A resolved flag value plus the full provenance of the decision.
public struct Assignment: Hashable, Sendable {
    public let flagKey: String
    public let variantKey: String
    public let value: FlagValue
    public let reason: EvaluationReason
    public let documentVersion: Int?
    public let bucket: Int?
    public let matchedRuleID: String?

    public init(
        flagKey: String,
        variantKey: String,
        value: FlagValue,
        reason: EvaluationReason,
        documentVersion: Int?,
        bucket: Int?,
        matchedRuleID: String?
    ) {
        self.flagKey = flagKey
        self.variantKey = variantKey
        self.value = value
        self.reason = reason
        self.documentVersion = documentVersion
        self.bucket = bucket
        self.matchedRuleID = matchedRuleID
    }
}

/// Compiled-in values used when the remote document cannot answer.
///
/// This is owned by the **app**, not by the config service, and that is the
/// point: it is the answer that ships in the binary, works with the network
/// unplugged, and is what a killed flag resolves to. A config system whose
/// "off" state is defined by the server has no off state at all.
public struct FallbackCatalog: Hashable, Sendable {
    public let values: [String: FlagValue]
    /// Value returned for a key not present in the catalog. `.bool(false)` by
    /// default, because an unknown flag is an un-launched feature.
    public let unknownKeyValue: FlagValue

    public init(values: [String: FlagValue], unknownKeyValue: FlagValue = .bool(false)) {
        self.values = values
        self.unknownKeyValue = unknownKeyValue
    }

    public func value(for key: String) -> FlagValue {
        values[key] ?? unknownKeyValue
    }

    public static let empty = FallbackCatalog(values: [:])
}

/// Pure flag evaluation.
///
/// No clock, no network, no device access, no caching — those live in
/// `ConfigStore`. Keeping evaluation pure is what makes `FleetSimulator` able to
/// run a 10,000-device fleet through the exact code path a real device takes,
/// and what makes every assertion in the test suite a statement about
/// production behaviour rather than about a test harness.
public struct Evaluator: Sendable {

    private let index: [String: FlagDefinition]
    private let documentVersion: Int?
    public let fallback: FallbackCatalog

    /// Builds an evaluator over a document.
    ///
    /// On a duplicate flag key the **first** definition wins and the duplicate is
    /// ignored. Documents with duplicates are rejected upstream by
    /// `DocumentValidator`; first-wins is the fail-closed choice if one somehow
    /// reaches here, because the first definition is the one an operator reading
    /// the document top-to-bottom would expect.
    public init(document: ConfigDocument?, fallback: FallbackCatalog) {
        var index: [String: FlagDefinition] = [:]
        if let document {
            index.reserveCapacity(document.flags.count)
            for flag in document.flags where index[flag.key] == nil {
                index[flag.key] = flag
            }
        }
        self.index = index
        self.documentVersion = document?.documentVersion
        self.fallback = fallback
    }

    public var knownFlagKeys: [String] { index.keys.sorted() }

    public func evaluate(_ flagKey: String, for context: DeviceContext) -> Assignment {
        guard documentVersion != nil else {
            return fallbackAssignment(flagKey, reason: .noDocument)
        }
        guard let flag = index[flagKey] else {
            return fallbackAssignment(flagKey, reason: .unknownFlag)
        }

        // Kill is checked before anything else and resolves to the compiled-in
        // fallback, not to the document's default variant. Those are different:
        // a default variant is still a server-chosen value, and the situation
        // that makes you reach for a kill switch is often exactly the situation
        // where you have stopped trusting the server's choices.
        if flag.killed {
            return fallbackAssignment(flagKey, reason: .killed)
        }

        let bucket = StableBucketer.bucket(
            flagKey: flag.key, salt: flag.salt, stableIdentifier: context.stableIdentifier)

        for rule in flag.rules {
            switch rule.predicate.matches(context) {
            case .refusedDepthExceeded:
                return fallbackAssignment(flagKey, reason: .refusedMalformedRule, bucket: bucket)
            case .notMatched:
                continue
            case .matched:
                // Predicate matched but bucket did not: fall through to the next
                // rule rather than to the default, so a staged ramp nested
                // inside an audience rule still lets a later broader rule serve.
                guard rule.bucketRange.contains(bucket) else { continue }
                guard let variant = flag.variant(named: rule.variantKey) else {
                    // Validated against upstream, but a rule pointing at a
                    // variant that does not exist must not silently serve some
                    // other variant.
                    return fallbackAssignment(flagKey, reason: .refusedMalformedRule, bucket: bucket)
                }
                return Assignment(
                    flagKey: flagKey,
                    variantKey: variant.key,
                    value: variant.value,
                    reason: .ruleMatch,
                    documentVersion: documentVersion,
                    bucket: bucket,
                    matchedRuleID: rule.id)
            }
        }

        guard let defaultVariant = flag.variant(named: flag.defaultVariantKey) else {
            return fallbackAssignment(flagKey, reason: .refusedMalformedRule, bucket: bucket)
        }
        return Assignment(
            flagKey: flagKey,
            variantKey: defaultVariant.key,
            value: defaultVariant.value,
            reason: .defaultVariant,
            documentVersion: documentVersion,
            bucket: bucket,
            matchedRuleID: nil)
    }

    public func evaluateAll(for context: DeviceContext) -> [Assignment] {
        knownFlagKeys.map { evaluate($0, for: context) }
    }

    private func fallbackAssignment(
        _ flagKey: String,
        reason: EvaluationReason,
        bucket: Int? = nil
    ) -> Assignment {
        Assignment(
            flagKey: flagKey,
            variantKey: "fallback",
            value: fallback.value(for: flagKey),
            reason: reason,
            documentVersion: documentVersion,
            bucket: bucket,
            matchedRuleID: nil)
    }
}
