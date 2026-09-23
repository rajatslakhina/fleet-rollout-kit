import Foundation

/// Decides whether an incoming document may replace the one being served.
///
/// Extracted from `ConfigStore` so that the rule can be *tested against a
/// deliberately broken implementation* — see `VersionFloorCheck`. A property the
/// README claims should have a test that fails when the property is removed, and
/// that is only possible if the property has a seam.
public protocol DocumentAcceptancePolicy: Sendable {
    func shouldAccept(offeredVersion: Int, acceptedFloor: Int) -> Bool
}

/// The rule that makes a kill switch irreversible from the network's side.
///
/// Once this device has accepted version N, nothing below N is ever served
/// again. Without it, a CDN edge holding a stale object, a cache poisoned by a
/// replayed response, or a botched publisher rollback can hand the device back
/// the document in which the feature was still alive — and the device would
/// happily install it, because it is a perfectly valid, perfectly signed
/// document. It is just the wrong one.
public struct MonotonicVersionFloorPolicy: DocumentAcceptancePolicy {
    public init() {}
    public func shouldAccept(offeredVersion: Int, acceptedFloor: Int) -> Bool {
        offeredVersion >= acceptedFloor
    }
}

/// Verifies that an acceptance policy is actually monotonic.
///
/// Used in the test suite twice: the real policy passes, and a
/// "newest-wins-by-timestamp" policy — the intuitive implementation, and the one
/// that has the rollback bug — is asserted to **fail**. A check that only ever
/// runs against the correct implementation proves nothing about the check.
public enum VersionFloorCheck {

    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public let offeredVersion: Int
        public let acceptedFloor: Int
        public let accepted: Bool
        public var description: String {
            "offered v\(offeredVersion) against floor v\(acceptedFloor): "
            + "accepted=\(accepted), expected=\(offeredVersion >= acceptedFloor)"
        }
    }

    /// Cases chosen to cover the rollback bug, the equal-version replay, the
    /// normal forward step, and the extremes where a naive `floor - 1` would
    /// itself overflow.
    public static let cases: [(offered: Int, floor: Int)] = [
        (offered: 7, floor: 7),
        (offered: 8, floor: 7),
        (offered: 6, floor: 7),
        (offered: 0, floor: 1),
        (offered: 1, floor: 0),
        (offered: Int.max, floor: 0),
        (offered: Int.min, floor: 0),
        (offered: Int.min, floor: Int.min),
        (offered: Int.max, floor: Int.max)
    ]

    public static func violations(of policy: some DocumentAcceptancePolicy) -> [Violation] {
        cases.compactMap { offered, floor in
            let accepted = policy.shouldAccept(offeredVersion: offered, acceptedFloor: floor)
            guard accepted != (offered >= floor) else { return nil }
            return Violation(offeredVersion: offered, acceptedFloor: floor, accepted: accepted)
        }
    }
}
