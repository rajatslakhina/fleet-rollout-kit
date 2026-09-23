import Foundation

/// A flag's payload. A closed set of three types, not `Any`: a config value that
/// can be anything is a config value nobody can validate at the edge.
public enum FlagValue: Hashable, Sendable, Codable {
    case bool(Bool)
    case int(Int)
    case string(String)

    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var intValue: Int? { if case .int(let value) = self { return value }; return nil }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}

public struct Variant: Hashable, Sendable, Codable {
    public let key: String
    public let value: FlagValue

    public init(key: String, value: FlagValue) {
        self.key = key
        self.value = value
    }
}

/// One targeting rule. Rules are evaluated in document order; first match wins.
public struct RolloutRule: Hashable, Sendable, Codable {
    public let id: String
    public let predicate: TargetingPredicate
    public let variantKey: String
    /// Slice of the bucket space that this rule actually serves. A rule whose
    /// predicate matches but whose bucket range does not contain the device
    /// falls through to the next rule — *not* to the default. That distinction
    /// is what makes staged ramps composable with audience targeting.
    public let bucketRange: BucketRange

    public init(id: String, predicate: TargetingPredicate, variantKey: String, bucketRange: BucketRange = .full) {
        self.id = id
        self.predicate = predicate
        self.variantKey = variantKey
        self.bucketRange = bucketRange
    }
}

public struct FlagDefinition: Hashable, Sendable, Codable {
    public let key: String
    /// Per-flag bucketing salt.
    ///
    /// Two independent 5% rollouts sharing a salt hit *the same* 5% of devices.
    /// That population is then permanently over-exposed to every experiment the
    /// company runs, their crash rate is not the fleet's crash rate, and the
    /// two rollouts' results are confounded with each other. Distinct salts are
    /// the whole fix, and `DocumentValidator` flags collisions.
    public let salt: String
    public let variants: [Variant]
    public let defaultVariantKey: String
    public let rules: [RolloutRule]
    /// Hard stop. Overrides every rule, ignores bucketing, and resolves to the
    /// flag's *fallback* rather than to its default variant.
    public let killed: Bool

    public init(
        key: String,
        salt: String,
        variants: [Variant],
        defaultVariantKey: String,
        rules: [RolloutRule] = [],
        killed: Bool = false
    ) {
        self.key = key
        self.salt = salt
        self.variants = variants
        self.defaultVariantKey = defaultVariantKey
        self.rules = rules
        self.killed = killed
    }

    public func variant(named key: String) -> Variant? {
        variants.first { $0.key == key }
    }
}

/// Integrity metadata travelling with the document.
///
/// **This package does not implement signature verification and deliberately
/// ships no cryptography of its own.** Rolling a signature scheme by hand is how
/// you get a config channel that looks signed and is not. What the package does
/// own is the *policy* around verification — see `DocumentIntegrityVerifying`
/// and `RefreshOutcome.rejectedIntegrity` — which is the part that is actually
/// specific to fleet rollout and the part teams usually get wrong. Production
/// supplies a verifier backed by CryptoKit (`P256.Signing`) or swift-crypto.
public struct IntegrityEnvelope: Hashable, Sendable, Codable {
    /// Which signing key this document claims to be signed by, so keys can be
    /// rotated without a flag day.
    public let keyIdentifier: String
    public let signature: Data

    public init(keyIdentifier: String, signature: Data) {
        self.keyIdentifier = keyIdentifier
        self.signature = signature
    }

    public static let unsigned = IntegrityEnvelope(keyIdentifier: "unsigned", signature: Data())
}

/// A signed, versioned configuration document.
public struct ConfigDocument: Hashable, Sendable, Codable {
    public let schemaVersion: Int
    /// Monotonically increasing publisher-assigned version.
    ///
    /// Load-bearing: `ConfigStore` refuses to accept a document whose version is
    /// below the highest it has ever seen. A CDN that serves a stale object from
    /// one edge, or an attacker who replays yesterday's response, would otherwise
    /// be able to *resurrect a feature that was killed* — which is the one
    /// failure this system exists to prevent.
    public let documentVersion: Int
    public let issuedAt: Date
    /// How long the document is fresh.
    public let maxAge: TimeInterval
    /// How long past `maxAge` it may still be served while a refresh runs.
    public let staleWhileRevalidate: TimeInterval
    public let flags: [FlagDefinition]
    public let integrity: IntegrityEnvelope

    public init(
        schemaVersion: Int = ConfigDocument.currentSchemaVersion,
        documentVersion: Int,
        issuedAt: Date,
        maxAge: TimeInterval = 300,
        staleWhileRevalidate: TimeInterval = 86_400,
        flags: [FlagDefinition],
        integrity: IntegrityEnvelope = .unsigned
    ) {
        self.schemaVersion = schemaVersion
        self.documentVersion = documentVersion
        self.issuedAt = issuedAt
        self.maxAge = maxAge
        self.staleWhileRevalidate = staleWhileRevalidate
        self.flags = flags
        self.integrity = integrity
    }

    public static let currentSchemaVersion = 1
}

/// Structural problems found in a document.
public enum DocumentDefect: Hashable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case negativeDocumentVersion(Int)
    case duplicateFlagKey(String)
    case emptyVariantList(flagKey: String)
    case duplicateVariantKey(flagKey: String, variantKey: String)
    case unknownDefaultVariant(flagKey: String, variantKey: String)
    case unknownRuleVariant(flagKey: String, ruleID: String, variantKey: String)
    case duplicateRuleID(flagKey: String, ruleID: String)
    case invertedBucketRange(flagKey: String, ruleID: String)
    case predicateTooDeep(flagKey: String, ruleID: String, depth: Int)
    case emptyPredicateGroup(flagKey: String, ruleID: String)
    case sharedSalt(flagKeys: [String], salt: String)
    case nonPositiveMaxAge(TimeInterval)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "unsupported schemaVersion \(version)"
        case .negativeDocumentVersion(let version):
            return "documentVersion \(version) is negative"
        case .duplicateFlagKey(let key):
            return "duplicate flag key '\(key)'"
        case .emptyVariantList(let flagKey):
            return "flag '\(flagKey)' declares no variants"
        case .duplicateVariantKey(let flagKey, let variantKey):
            return "flag '\(flagKey)' declares variant '\(variantKey)' more than once"
        case .unknownDefaultVariant(let flagKey, let variantKey):
            return "flag '\(flagKey)' defaults to unknown variant '\(variantKey)'"
        case .unknownRuleVariant(let flagKey, let ruleID, let variantKey):
            return "flag '\(flagKey)' rule '\(ruleID)' serves unknown variant '\(variantKey)'"
        case .duplicateRuleID(let flagKey, let ruleID):
            return "flag '\(flagKey)' declares rule id '\(ruleID)' more than once"
        case .invertedBucketRange(let flagKey, let ruleID):
            return "flag '\(flagKey)' rule '\(ruleID)' has an inverted bucket range"
        case .predicateTooDeep(let flagKey, let ruleID, let depth):
            return "flag '\(flagKey)' rule '\(ruleID)' nests \(depth) levels deep"
        case .emptyPredicateGroup(let flagKey, let ruleID):
            return "flag '\(flagKey)' rule '\(ruleID)' contains an empty all/any group"
        case .sharedSalt(let flagKeys, let salt):
            return "flags \(flagKeys.joined(separator: ", ")) share bucketing salt '\(salt)'"
        case .nonPositiveMaxAge(let maxAge):
            return "maxAge \(maxAge) is not positive"
        }
    }

    /// Whether this defect must reject the document outright.
    ///
    /// A shared salt is a real problem but it is a *correlation* problem, not an
    /// ambiguity: the document still resolves to exactly one answer per flag. A
    /// duplicate flag key does not, and a kill switch that resolves ambiguously
    /// is worse than no kill switch. So the first fails the document and the
    /// second is a warning surfaced to the dashboard.
    public var isFatal: Bool {
        if case .sharedSalt = self { return false }
        return true
    }
}

public enum DocumentValidator {

    /// Returns every defect found. Empty means the document is structurally sound.
    public static func defects(in document: ConfigDocument) -> [DocumentDefect] {
        var defects: [DocumentDefect] = []

        if document.schemaVersion != ConfigDocument.currentSchemaVersion {
            defects.append(.unsupportedSchemaVersion(document.schemaVersion))
        }
        if document.documentVersion < 0 {
            defects.append(.negativeDocumentVersion(document.documentVersion))
        }
        if !(document.maxAge > 0) {
            defects.append(.nonPositiveMaxAge(document.maxAge))
        }

        var seenFlagKeys = Set<String>()
        var saltOwners: [String: [String]] = [:]

        for flag in document.flags {
            if !seenFlagKeys.insert(flag.key).inserted {
                defects.append(.duplicateFlagKey(flag.key))
                continue
            }
            saltOwners[flag.salt, default: []].append(flag.key)

            if flag.variants.isEmpty {
                defects.append(.emptyVariantList(flagKey: flag.key))
            }
            var seenVariantKeys = Set<String>()
            for variant in flag.variants where !seenVariantKeys.insert(variant.key).inserted {
                defects.append(.duplicateVariantKey(flagKey: flag.key, variantKey: variant.key))
            }
            if !seenVariantKeys.contains(flag.defaultVariantKey) {
                defects.append(.unknownDefaultVariant(
                    flagKey: flag.key, variantKey: flag.defaultVariantKey))
            }

            var seenRuleIDs = Set<String>()
            for rule in flag.rules {
                if !seenRuleIDs.insert(rule.id).inserted {
                    defects.append(.duplicateRuleID(flagKey: flag.key, ruleID: rule.id))
                }
                if !seenVariantKeys.contains(rule.variantKey) {
                    defects.append(.unknownRuleVariant(
                        flagKey: flag.key, ruleID: rule.id, variantKey: rule.variantKey))
                }
                if rule.bucketRange.upperBasisPoints < rule.bucketRange.lowerBasisPoints {
                    defects.append(.invertedBucketRange(flagKey: flag.key, ruleID: rule.id))
                }
                let depth = rule.predicate.depth()
                if depth > TargetingPredicate.maximumDepth {
                    defects.append(.predicateTooDeep(
                        flagKey: flag.key, ruleID: rule.id, depth: depth))
                }
                if containsEmptyGroup(rule.predicate) {
                    defects.append(.emptyPredicateGroup(flagKey: flag.key, ruleID: rule.id))
                }
            }
        }

        for (salt, owners) in saltOwners where owners.count > 1 {
            defects.append(.sharedSalt(flagKeys: owners.sorted(), salt: salt))
        }

        return defects
    }

    public static func fatalDefects(in document: ConfigDocument) -> [DocumentDefect] {
        defects(in: document).filter(\.isFatal)
    }

    private static func containsEmptyGroup(_ predicate: TargetingPredicate, depth: Int = 0) -> Bool {
        guard depth < TargetingPredicate.maximumDepth else { return false }
        switch predicate {
        case .all(let children), .any(let children):
            if children.isEmpty { return true }
            return children.contains { containsEmptyGroup($0, depth: depth + 1) }
        case .not(let child):
            return containsEmptyGroup(child, depth: depth + 1)
        default:
            return false
        }
    }
}

// MARK: - Publisher-side edits
//
// Documents are immutable value types. These produce a new document rather than
// mutating one in place, which is what lets a dashboard show "current" and
// "proposed" side by side, and what lets a test assert that re-ramping a flag
// changed nothing except the bucket range.

extension RolloutRule {
    public func replacingBucketRange(_ range: BucketRange) -> RolloutRule {
        RolloutRule(id: id, predicate: predicate, variantKey: variantKey, bucketRange: range)
    }
}

extension FlagDefinition {
    public func replacingRules(_ rules: [RolloutRule]) -> FlagDefinition {
        FlagDefinition(
            key: key, salt: salt, variants: variants,
            defaultVariantKey: defaultVariantKey, rules: rules, killed: killed)
    }

    public func settingKilled(_ killed: Bool) -> FlagDefinition {
        FlagDefinition(
            key: key, salt: salt, variants: variants,
            defaultVariantKey: defaultVariantKey, rules: rules, killed: killed)
    }

    /// Re-ramps every rule to the given width, preserving rule order and
    /// predicates. Ramping is a *width* change, never a re-salt: changing the
    /// salt would re-shuffle the whole fleet and evict devices that were already
    /// in the treatment.
    public func ramped(toBasisPoints basisPoints: Int) -> FlagDefinition {
        replacingRules(rules.map {
            $0.replacingBucketRange(
                BucketRange(lowerBasisPoints: 0, upperBasisPoints: basisPoints))
        })
    }
}

extension ConfigDocument {
    public func replacingFlags(_ flags: [FlagDefinition], bumpingVersionTo version: Int) -> ConfigDocument {
        ConfigDocument(
            schemaVersion: schemaVersion,
            documentVersion: version,
            issuedAt: issuedAt,
            maxAge: maxAge,
            staleWhileRevalidate: staleWhileRevalidate,
            flags: flags,
            integrity: integrity)
    }

    public func updatingFlag(
        _ key: String,
        bumpingVersionTo version: Int,
        _ transform: (FlagDefinition) -> FlagDefinition
    ) -> ConfigDocument {
        replacingFlags(flags.map { $0.key == key ? transform($0) : $0 },
                       bumpingVersionTo: version)
    }

    public func killingAll(bumpingVersionTo version: Int) -> ConfigDocument {
        replacingFlags(flags.map { $0.settingKilled(true) }, bumpingVersionTo: version)
    }
}
