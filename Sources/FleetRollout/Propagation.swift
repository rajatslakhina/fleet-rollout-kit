import Foundation

/// How a device can learn that a new document exists.
public enum PropagationChannel: String, Hashable, Sendable, Codable, CaseIterable {
    /// Blocking fetch at cold start, under a hard budget.
    case launchBlockingFetch
    /// Content-available push. Fast but unreliable and rate-limited by the OS.
    case silentPush
    /// Poll on foreground.
    case foregroundPoll
    /// Background app refresh. Scheduled at the system's discretion.
    case backgroundRefresh

    /// Whether the channel can be relied on to fire.
    ///
    /// Only two of the four can. Silent push is best-effort by Apple's own
    /// documentation and is throttled per app; background refresh is scheduled
    /// by the system against battery and usage heuristics and may simply never
    /// run for a given user. A kill-switch SLO computed as if either were
    /// guaranteed is a fiction, which is why `PropagationSimulator` models them
    /// as probabilistic and the two deterministic channels as the floor.
    public var isGuaranteed: Bool {
        switch self {
        case .launchBlockingFetch, .foregroundPoll: return true
        case .silentPush, .backgroundRefresh: return false
        }
    }
}

/// The promise a kill switch makes.
public struct PropagationSLO: Hashable, Sendable {
    /// Time within which `targetCoverage` of reachable devices must have the new
    /// document.
    public let deadline: TimeInterval
    /// Fraction of the fleet, 0...1.
    public let targetCoverage: Double
    public let channels: Set<PropagationChannel>

    public init(deadline: TimeInterval, targetCoverage: Double, channels: Set<PropagationChannel>) {
        self.deadline = max(0, deadline)
        self.targetCoverage = min(max(targetCoverage, 0), 1)
        self.channels = channels
    }

    /// 95% of the fleet within 15 minutes, using every channel.
    public static let standard = PropagationSLO(
        deadline: 900,
        targetCoverage: 0.95,
        channels: Set(PropagationChannel.allCases))

    /// What the SLO degrades to if push and background refresh never fire.
    public var guaranteedOnly: PropagationSLO {
        PropagationSLO(
            deadline: deadline,
            targetCoverage: targetCoverage,
            channels: channels.filter(\.isGuaranteed))
    }
}

/// Measured propagation of one document version across a fleet.
public struct PropagationReport: Hashable, Sendable {
    public let fleetSize: Int
    /// Seconds from publish to receipt, per device that received it.
    public let p50: TimeInterval
    public let p95: TimeInterval
    public let p99: TimeInterval
    public let worst: TimeInterval
    /// Devices that had not received the document when the window closed.
    public let unreachedCount: Int
    public let observationWindow: TimeInterval
    public let channelAttribution: [PropagationChannel: Int]

    public var coverage: Double {
        guard fleetSize > 0 else { return 0 }
        let reached = SafeMath.addingSaturating(fleetSize, -unreachedCount)
        return Double(max(reached, 0)) / Double(fleetSize)
    }

    public func meets(_ slo: PropagationSLO) -> Bool {
        coverage >= slo.targetCoverage && p95 <= slo.deadline
    }
}

enum Percentile {
    /// Nearest-rank percentile over a sorted array.
    ///
    /// Bounds-safe by construction: returns `0` for an empty input rather than
    /// indexing it, clamps the computed rank into `0..<count`, and routes the
    /// `Double -> Int` conversion through `SafeMath` so a NaN or infinite
    /// fraction cannot trap.
    static func value(_ fraction: Double, ofSorted values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let clampedFraction = min(max(fraction.isNaN ? 0 : fraction, 0), 1)
        let rank = SafeMath.clampedInt((clampedFraction * Double(values.count - 1)).rounded())
        guard let index = SafeMath.clampedIndex(rank, count: values.count) else { return 0 }
        return values[index]
    }
}
