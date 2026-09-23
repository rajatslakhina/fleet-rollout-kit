import Foundation

/// A named OS release lineage.
///
/// The premise of this whole package: **the iOS version stopped being a line.**
/// iOS 27.1 shipped only to iPhone Duo; every other iPhone went from 27.0
/// straight to 27.2. A device running 27.2 therefore never executed a single
/// line of 27.1's code — and yet the check that virtually every feature flag in
/// the industry is written with, `osVersion >= "27.1"`, matches it.
///
/// The fix is not a cleverer comparison. It is to stop ordering OS versions at
/// all. A train is an *identity*, and targeting rules match it by set
/// membership. `TargetingPredicate` deliberately exposes no `>=` operator over
/// build trains for exactly this reason.
public struct BuildTrain: Hashable, Sendable, Codable {

    /// How this train relates to the rest of the fleet.
    public enum Lineage: String, Hashable, Sendable, Codable, CaseIterable {
        /// The train the majority of the fleet receives.
        case mainline
        /// A train that shipped only to one device family.
        case deviceExclusive
        /// A train no longer receiving updates.
        case terminal
    }

    /// Stable machine identifier, e.g. `"ios-27.1-duo"`. Rules match on this.
    public let identifier: String
    /// Human-facing version string. Display only — never compared.
    public let marketingVersion: String
    public let lineage: Lineage

    public init(identifier: String, marketingVersion: String, lineage: Lineage) {
        self.identifier = identifier
        self.marketingVersion = marketingVersion
        self.lineage = lineage
    }
}

extension BuildTrain {
    public static let ios26_5 = BuildTrain(
        identifier: "ios-26.5", marketingVersion: "26.5", lineage: .terminal)
    public static let ios27_0 = BuildTrain(
        identifier: "ios-27.0", marketingVersion: "27.0", lineage: .mainline)
    /// iPhone Duo only. No other device ever ran this train.
    public static let ios27_1Duo = BuildTrain(
        identifier: "ios-27.1-duo", marketingVersion: "27.1", lineage: .deviceExclusive)
    public static let ios27_2 = BuildTrain(
        identifier: "ios-27.2", marketingVersion: "27.2", lineage: .mainline)

    public static let known: [BuildTrain] = [.ios26_5, .ios27_0, .ios27_1Duo, .ios27_2]
}

/// Hardware family. Separate from posture capability on purpose: a device class
/// is fixed at manufacture, a posture capability is a runtime affordance and a
/// future device could gain one without changing class.
public enum DeviceClass: String, Hashable, Sendable, Codable, CaseIterable {
    case phoneStandard
    case phonePro
    case phoneDuo
    case pad
    /// Reported by a build newer than this client's table. Treated as a real
    /// value, never coerced to a default: silently mapping an unknown device to
    /// `phoneStandard` is how a rollout reaches hardware it was never tested on.
    case unknown
}

/// Whether the device can change physical posture at runtime.
public enum PostureCapability: String, Hashable, Sendable, Codable, CaseIterable {
    case fixed
    case foldable
}

/// Everything a targeting rule is allowed to see.
///
/// The type is a closed struct rather than a dictionary so that adding a new
/// targeting dimension is a compile-time event that forces every call site to
/// be revisited — the alternative, a free-form bag of strings, is how a rollout
/// ends up keyed on an attribute nobody can enumerate six months later. The
/// escape hatch (`attributes`) exists, is explicitly bounded, and is documented
/// as the place experiments go before they earn a field.
public struct DeviceContext: Hashable, Sendable {

    /// Identifier used for rollout bucketing.
    ///
    /// Must survive app reinstall, or a user churns in and out of a rollout by
    /// deleting and re-downloading. `identifierForVendor` is reset when the last
    /// app from a vendor is removed, so production should persist a generated
    /// UUID in the Keychain (which survives reinstall) and pass it here. The
    /// package takes it as a parameter and never reads device state itself,
    /// which is also what makes the evaluator a pure function.
    public let stableIdentifier: String

    public let buildTrain: BuildTrain
    public let deviceClass: DeviceClass
    public let posture: PostureCapability
    /// The app's own build number. Ordering *is* legitimate here — unlike OS
    /// trains, we control this number and it is monotonic by construction.
    public let appBuild: Int
    /// Bounded free-form dimensions. Capped at `maximumAttributeCount`; excess
    /// keys are dropped at init rather than silently growing the evaluation
    /// surface.
    public let attributes: [String: String]

    public static let maximumAttributeCount = 32

    public init(
        stableIdentifier: String,
        buildTrain: BuildTrain,
        deviceClass: DeviceClass,
        posture: PostureCapability,
        appBuild: Int,
        attributes: [String: String] = [:]
    ) {
        self.stableIdentifier = stableIdentifier
        self.buildTrain = buildTrain
        self.deviceClass = deviceClass
        self.posture = posture
        self.appBuild = appBuild
        if attributes.count <= Self.maximumAttributeCount {
            self.attributes = attributes
        } else {
            // Deterministic truncation: sorting by key keeps two devices with
            // the same attribute set from disagreeing about which keys survived.
            let kept = attributes.sorted { $0.key < $1.key }.prefix(Self.maximumAttributeCount)
            self.attributes = Dictionary(uniqueKeysWithValues: Array(kept))
        }
    }
}
