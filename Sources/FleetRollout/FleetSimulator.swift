import Foundation

/// SplitMix64. Deterministic, seedable, and independent of the standard
/// library's `SystemRandomNumberGenerator`, so a simulated fleet is byte-for-byte
/// reproducible across platforms and Swift versions. A chaos result you cannot
/// reproduce is an anecdote.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<upperBound`. Returns `0` for a non-positive bound rather
    /// than trapping on a zero modulus.
    public mutating func next(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    /// Uniform in `0..<1`.
    public mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2^53
    }
}

/// Composition of a synthetic fleet.
public struct FleetComposition: Sendable {
    /// Relative weights per (train, device class, posture) cohort.
    public struct Cohort: Sendable {
        public let train: BuildTrain
        public let deviceClass: DeviceClass
        public let posture: PostureCapability
        public let weight: Int

        public init(train: BuildTrain, deviceClass: DeviceClass, posture: PostureCapability, weight: Int) {
            self.train = train
            self.deviceClass = deviceClass
            self.posture = posture
            self.weight = max(0, weight)
        }
    }

    public let cohorts: [Cohort]
    public let appBuilds: [Int]

    public init(cohorts: [Cohort], appBuilds: [Int]) {
        self.cohorts = cohorts
        self.appBuilds = appBuilds.isEmpty ? [1] : appBuilds
    }

    /// The fleet this package was written for: a forked release graph where
    /// 27.1 exists only on iPhone Duo and everything else is on 27.2 or behind.
    public static let forkedSeptember2026 = FleetComposition(
        cohorts: [
            Cohort(train: .ios27_1Duo, deviceClass: .phoneDuo, posture: .foldable, weight: 2),
            Cohort(train: .ios27_2, deviceClass: .phoneStandard, posture: .fixed, weight: 48),
            Cohort(train: .ios27_2, deviceClass: .phonePro, posture: .fixed, weight: 22),
            Cohort(train: .ios27_0, deviceClass: .phoneStandard, posture: .fixed, weight: 14),
            Cohort(train: .ios27_0, deviceClass: .pad, posture: .fixed, weight: 6),
            // Stranded: iOS 27 closed the downgrade path on 21 Sep 2026, so a
            // device that took 27.0 and stalled cannot go back to 26.5, and a
            // 26.5 device that has not updated may never.
            Cohort(train: .ios26_5, deviceClass: .phoneStandard, posture: .fixed, weight: 8)
        ],
        appBuilds: [1180, 1181, 1190, 1201])
}

/// How often a given device gives the client a chance to refresh.
public struct WakeProfile: Sendable {
    /// Mean seconds between foreground sessions.
    public let meanForegroundInterval: TimeInterval
    /// Probability a silent push is actually delivered and acted on.
    public let silentPushDeliveryRate: Double
    /// Mean seconds until a background refresh opportunity, if any.
    public let meanBackgroundInterval: TimeInterval
    /// Probability the OS ever grants this device a background refresh.
    public let backgroundRefreshEnabledRate: Double

    public init(
        meanForegroundInterval: TimeInterval,
        silentPushDeliveryRate: Double,
        meanBackgroundInterval: TimeInterval,
        backgroundRefreshEnabledRate: Double
    ) {
        self.meanForegroundInterval = max(1, meanForegroundInterval)
        self.silentPushDeliveryRate = min(max(silentPushDeliveryRate, 0), 1)
        self.meanBackgroundInterval = max(1, meanBackgroundInterval)
        self.backgroundRefreshEnabledRate = min(max(backgroundRefreshEnabledRate, 0), 1)
    }

    /// Engagement roughly matching a daily-use consumer app, with the push and
    /// background-refresh rates set to numbers a team would actually measure
    /// rather than to the 100% those channels are usually budgeted at.
    public static let dailyConsumerApp = WakeProfile(
        meanForegroundInterval: 5_400,
        silentPushDeliveryRate: 0.72,
        meanBackgroundInterval: 3_600,
        backgroundRefreshEnabledRate: 0.55)
}

/// Exposure of one flag across a simulated fleet.
public struct ExposureHistogram: Sendable {
    public let flagKey: String
    public let fleetSize: Int
    /// Device count per resolved variant key.
    public let byVariant: [String: Int]
    /// Device count per evaluation reason.
    public let byReason: [EvaluationReason: Int]
    /// Device count per build train identifier, for the treated variants only.
    public let treatedByTrain: [String: Int]

    public func share(ofVariant key: String) -> Double {
        SafeMath.percentage(byVariant[key] ?? 0, of: fleetSize) / 100
    }
}

public enum FleetSimulator {

    /// Builds a deterministic synthetic fleet.
    ///
    /// Stable identifiers are `"sim-<index>"` rather than random, so the same
    /// seed and size always produce the same *bucketing*, not merely the same
    /// device mix. That is what makes a ramp comparison across two documents
    /// meaningful: the population is held fixed and only the config moves.
    public static func makeFleet(
        size: Int,
        composition: FleetComposition = .forkedSeptember2026,
        seed: UInt64 = 0xF1EE_7C0D_E5EE_D000
    ) -> [DeviceContext] {
        guard size > 0 else { return [] }
        let totalWeight = composition.cohorts.reduce(0) { SafeMath.addingSaturating($0, $1.weight) }
        guard totalWeight > 0, !composition.cohorts.isEmpty else { return [] }

        var generator = SplitMix64(seed: seed)
        var fleet: [DeviceContext] = []
        fleet.reserveCapacity(size)

        for index in 0..<size {
            var pick = generator.next(upperBound: totalWeight)
            var chosen = composition.cohorts[0]
            for cohort in composition.cohorts {
                if pick < cohort.weight { chosen = cohort; break }
                pick = SafeMath.addingSaturating(pick, -cohort.weight)
            }
            let buildIndex = generator.next(upperBound: composition.appBuilds.count)
            // `appBuilds` is non-empty by `FleetComposition.init`, and
            // `next(upperBound:)` returns a value strictly below the bound.
            let appBuild = composition.appBuilds[buildIndex]

            fleet.append(DeviceContext(
                stableIdentifier: "sim-\(index)",
                buildTrain: chosen.train,
                deviceClass: chosen.deviceClass,
                posture: chosen.posture,
                appBuild: appBuild))
        }
        return fleet
    }

    /// Runs the real evaluator over every device and tallies the result.
    public static func exposure(
        of flagKey: String,
        evaluator: Evaluator,
        fleet: [DeviceContext],
        treatedVariantKeys: Set<String> = []
    ) -> ExposureHistogram {
        var byVariant: [String: Int] = [:]
        var byReason: [EvaluationReason: Int] = [:]
        var treatedByTrain: [String: Int] = [:]

        for device in fleet {
            let assignment = evaluator.evaluate(flagKey, for: device)
            byVariant[assignment.variantKey, default: 0] += 1
            byReason[assignment.reason, default: 0] += 1
            if treatedVariantKeys.contains(assignment.variantKey) {
                treatedByTrain[device.buildTrain.identifier, default: 0] += 1
            }
        }

        return ExposureHistogram(
            flagKey: flagKey,
            fleetSize: fleet.count,
            byVariant: byVariant,
            byReason: byReason,
            treatedByTrain: treatedByTrain)
    }
}

/// Measures how long a kill actually takes to reach a fleet.
///
/// The number this produces is the one nobody has when they are asked "how fast
/// can we turn it off?" mid-incident. It is almost never the push latency; it is
/// the tail of devices that are not foregrounded, do not get the push, and have
/// background refresh switched off.
public enum PropagationSimulator {

    public static func timeToKill(
        fleetSize: Int,
        profile: WakeProfile = .dailyConsumerApp,
        channels: Set<PropagationChannel> = Set(PropagationChannel.allCases),
        observationWindow: TimeInterval = 3_600,
        seed: UInt64 = 0xC0FF_EE00_1234_5678
    ) -> PropagationReport {
        guard fleetSize > 0 else {
            return PropagationReport(
                fleetSize: 0, p50: 0, p95: 0, p99: 0, worst: 0,
                unreachedCount: 0, observationWindow: observationWindow,
                channelAttribution: [:])
        }

        var generator = SplitMix64(seed: seed)
        var latencies: [TimeInterval] = []
        latencies.reserveCapacity(fleetSize)
        var attribution: [PropagationChannel: Int] = [:]
        var unreached = 0
        let window = max(0, observationWindow)

        for _ in 0..<fleetSize {
            var best: (channel: PropagationChannel, at: TimeInterval)?

            @inline(__always)
            func consider(_ channel: PropagationChannel, _ at: TimeInterval) {
                guard at <= window else { return }
                guard let current = best else { best = (channel, at); return }
                if at < current.at { best = (channel, at) }
            }

            if channels.contains(.silentPush), generator.nextUnitInterval() < profile.silentPushDeliveryRate {
                // Push latency is short but not zero, and it is deliberately
                // jittered: a kill that reaches the whole fleet in the same
                // second also sends the whole fleet's refresh traffic in the
                // same second, at exactly the moment the backend is already
                // unhealthy enough to warrant a kill.
                consider(.silentPush, 2 + generator.nextUnitInterval() * 28)
            }
            if channels.contains(.foregroundPoll) {
                consider(.foregroundPoll, exponential(mean: profile.meanForegroundInterval, using: &generator))
            }
            if channels.contains(.launchBlockingFetch) {
                // A cold start is rarer than a foreground resume.
                consider(.launchBlockingFetch,
                         exponential(mean: profile.meanForegroundInterval * 4, using: &generator))
            }
            if channels.contains(.backgroundRefresh),
               generator.nextUnitInterval() < profile.backgroundRefreshEnabledRate {
                consider(.backgroundRefresh,
                         exponential(mean: profile.meanBackgroundInterval, using: &generator))
            }

            if let best {
                latencies.append(best.at)
                attribution[best.channel, default: 0] += 1
            } else {
                unreached = SafeMath.addingSaturating(unreached, 1)
            }
        }

        let sorted = latencies.sorted()
        return PropagationReport(
            fleetSize: fleetSize,
            p50: Percentile.value(0.50, ofSorted: sorted),
            p95: Percentile.value(0.95, ofSorted: sorted),
            p99: Percentile.value(0.99, ofSorted: sorted),
            worst: sorted.last ?? 0,
            unreachedCount: unreached,
            observationWindow: window,
            channelAttribution: attribution)
    }

    /// Exponential inter-arrival time. `log` of a value in `(0, 1]` is finite and
    /// non-positive, and the unit-interval draw is nudged off zero so the result
    /// can never be infinite.
    static func exponential(mean: TimeInterval, using generator: inout SplitMix64) -> TimeInterval {
        let uniform = max(generator.nextUnitInterval(), 1e-12)
        let sample = -max(mean, 0) * Foundation.log(uniform)
        return sample.isFinite ? sample : 0
    }
}
