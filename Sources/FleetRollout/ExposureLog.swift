import Foundation

/// One record of a flag being *read* — not of it being configured.
///
/// Exposure is the join key between a rollout and every other signal you have.
/// Without it, "crash rate went up 3%" and "we ramped checkout.duo_layout to
/// 10% yesterday" are two unrelated facts on two dashboards.
public struct ExposureEvent: Hashable, Sendable, Codable {
    public let flagKey: String
    public let variantKey: String
    public let reason: EvaluationReason
    public let documentVersion: Int?
    public let bucket: Int?
    public let timestamp: Date

    public init(assignment: Assignment, timestamp: Date) {
        self.flagKey = assignment.flagKey
        self.variantKey = assignment.variantKey
        self.reason = assignment.reason
        self.documentVersion = assignment.documentVersion
        self.bucket = assignment.bucket
        self.timestamp = timestamp
    }

    /// Identity used for de-duplication: the same device reading the same flag
    /// a thousand times in one scroll is one exposure, not a thousand.
    var dedupeKey: String {
        "\(flagKey)|\(variantKey)|\(reason.rawValue)|\(documentVersion.map(String.init) ?? "-")"
    }
}

/// Bounded, de-duplicating exposure buffer.
///
/// Two properties it must have and most hand-rolled versions do not:
///
/// - **It cannot grow without bound.** A device that is offline for a week still
///   reads flags on every screen. The buffer is a fixed-capacity ring.
/// - **When it drops, it says so.** Dropping the oldest events silently turns a
///   partial dataset into a wrong one, because the analysis downstream has no
///   way to know its denominator is short. `droppedCount` travels with every
///   drain.
public actor ExposureLog {

    public struct Drain: Sendable {
        public let events: [ExposureEvent]
        /// Events discarded since the previous drain because the buffer was full.
        public let droppedCount: Int
        /// Reads suppressed as duplicates since the previous drain. Not a loss —
        /// reported separately so the two are never confused.
        public let deduplicatedCount: Int
    }

    private let capacity: Int
    private let dedupeWindow: TimeInterval
    private var buffer: [ExposureEvent] = []
    private var head = 0
    private var droppedCount = 0
    private var deduplicatedCount = 0
    private var lastSeen: [String: Date] = [:]

    /// - Parameters:
    ///   - capacity: Clamped to at least 1. A zero-capacity ring would make
    ///     every record a drop and every modulus a division by zero.
    ///   - dedupeWindow: A repeat read of the same `(flag, variant, reason,
    ///     version)` inside this window is suppressed.
    public init(capacity: Int = 512, dedupeWindow: TimeInterval = 60) {
        self.capacity = max(1, capacity)
        self.dedupeWindow = max(0, dedupeWindow)
        buffer.reserveCapacity(self.capacity)
    }

    public func record(_ assignment: Assignment, at timestamp: Date) {
        let event = ExposureEvent(assignment: assignment, timestamp: timestamp)

        if let previous = lastSeen[event.dedupeKey],
           timestamp.timeIntervalSince(previous) < dedupeWindow,
           timestamp >= previous {
            deduplicatedCount = SafeMath.addingSaturating(deduplicatedCount, 1)
            return
        }
        lastSeen[event.dedupeKey] = timestamp

        // The dedupe table is itself unbounded input: one distinct key per
        // document version per flag. Bound it to the ring's capacity and reset
        // rather than evicting cleverly — losing dedupe state costs a duplicate
        // event, which is strictly better than an unbounded dictionary.
        if lastSeen.count > capacity {
            lastSeen = [event.dedupeKey: timestamp]
        }

        if buffer.count < capacity {
            buffer.append(event)
        } else {
            // `head` is always < capacity and capacity >= 1, so this index is
            // always in bounds.
            buffer[head] = event
            head = (head + 1) % capacity
            droppedCount = SafeMath.addingSaturating(droppedCount, 1)
        }
    }

    /// Returns buffered events in chronological order and clears the buffer.
    public func drain() -> Drain {
        let ordered: [ExposureEvent]
        if buffer.count < capacity {
            ordered = buffer
        } else {
            // Rotate the ring back into arrival order. `head` is in
            // `0..<capacity` and `buffer.count == capacity` here, so both
            // slices are valid even when `head == 0`.
            ordered = Array(buffer[head...]) + Array(buffer[..<head])
        }
        let drain = Drain(
            events: ordered,
            droppedCount: droppedCount,
            deduplicatedCount: deduplicatedCount)
        buffer.removeAll(keepingCapacity: true)
        head = 0
        droppedCount = 0
        deduplicatedCount = 0
        return drain
    }

    public func bufferedCount() -> Int { buffer.count }
}
