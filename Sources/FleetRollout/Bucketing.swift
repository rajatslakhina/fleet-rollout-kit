import Foundation

/// Deterministic rollout bucketing.
///
/// Rollout percentages are expressed in **basis points** (0...10_000) rather
/// than whole percent. A 0.05% canary is a real thing teams ask for on a fleet
/// of tens of millions, and rounding it to "0% or 1%" is a two-order-of-
/// magnitude error in blast radius.
public enum StableBucketer {

    /// Number of buckets. 10_000 basis points = 0.01% resolution.
    public static let bucketSpace = 10_000

    /// Assigns a device to a bucket in `0..<bucketSpace`.
    ///
    /// The **`(flagKey, salt)` pair is the bucketing namespace**, and both halves
    /// of it matter:
    ///
    /// - The flag key is in the hash input so that two flags are decorrelated
    ///   *by construction*. Systems that hash only `(salt, id)` are correlated
    ///   by default and rely on an operator remembering to set a distinct salt
    ///   on every flag; the day someone copies a flag definition, two
    ///   independent 10% rollouts land on the same tenth of the fleet, that
    ///   population is over-exposed to everything the company ships, and both
    ///   experiments are confounded. Measured here: two flags sharing a salt
    ///   overlap on ~1.07% of a 40,000-device fleet at 10% each — the ~1% you
    ///   would expect from independence, not 10%.
    /// - The salt is the **rotation handle**. Bumping it reshuffles that one
    ///   flag's population without renaming the flag, which is what you need to
    ///   re-run an experiment on a fresh split. Measured: same flag key, new
    ///   salt overlaps the old treatment on ~1.05%.
    ///
    /// `BucketingTests.testFlagKeyAndSaltEachReshuffleTheFleetIndependently`
    /// pins both numbers.
    ///
    /// The hash is FNV-1a/64 over `"flagKey:salt:stableIdentifier"`, chosen
    /// because it is **specified**, not because it is fast.
    ///
    /// It is deliberately *not* Swift's `Hasher` / `hashValue`. Those are seeded
    /// with a per-process random value, so the same device lands in a different
    /// bucket on every cold start. A rollout built on `hashValue` flickers users
    /// in and out of the treatment on every launch: the feature looks flaky, any
    /// experiment reading it is silently invalid, and — worst of the three — a
    /// user who hit a crash in the treatment can land back in it on the next
    /// launch. This is the single easiest way to get fleet bucketing wrong, and
    /// it does not show up in a unit test that calls the function twice in one
    /// process, because within a process `Hasher` *is* stable.
    /// `BucketStabilityCheck` exists to catch it for real.
    public static func bucket(flagKey: String, salt: String, stableIdentifier: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a 64-bit offset basis
        let prime: UInt64 = 0x0000_0100_0000_01b3

        @inline(__always)
        func absorb(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime      // wrapping by specification, not by accident
            }
        }

        absorb(flagKey)
        absorb(":")
        absorb(salt)
        absorb(":")
        absorb(stableIdentifier)

        // `bucketSpace` is a positive compile-time constant, so the modulus
        // cannot trap, and the result is < 10_000 and therefore always fits an
        // `Int` even on a 32-bit platform.
        return Int(hash % UInt64(bucketSpace))
    }
}

/// A half-open slice of the bucket space, in basis points.
///
/// Bounds are clamped into `0...bucketSpace` on construction **and on decoding**
/// — the custom `init(from:)` exists precisely because synthesised `Codable`
/// would bypass the designated initialiser and let a remote document hand the
/// client an `upperBasisPoints` of 99,999, which `contains(_:)` would then treat
/// as a 100% ramp. Failing *open* on ramp width, in the one system whose whole
/// thesis is failing closed, is not an acceptable decoding bug.
///
/// An inverted range (upper below lower) is **stored as given**, not silently
/// repaired. It is a real defect in the document, `DocumentValidator` reports it
/// as fatal, and `contains(_:)` returns `false` for every bucket — so a document
/// that somehow bypasses validation puts nobody in the rollout rather than
/// everybody.
public struct BucketRange: Hashable, Sendable, Codable {
    public let lowerBasisPoints: Int
    public let upperBasisPoints: Int

    public init(lowerBasisPoints: Int, upperBasisPoints: Int) {
        let space = StableBucketer.bucketSpace
        self.lowerBasisPoints = min(max(lowerBasisPoints, 0), space)
        self.upperBasisPoints = min(max(upperBasisPoints, 0), space)
    }

    private enum CodingKeys: String, CodingKey {
        case lowerBasisPoints
        case upperBasisPoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lowerBasisPoints: try container.decode(Int.self, forKey: .lowerBasisPoints),
            upperBasisPoints: try container.decode(Int.self, forKey: .upperBasisPoints))
    }

    public static let full = BucketRange(lowerBasisPoints: 0, upperBasisPoints: StableBucketer.bucketSpace)
    public static let empty = BucketRange(lowerBasisPoints: 0, upperBasisPoints: 0)

    public static func percent(_ percent: Double) -> BucketRange {
        let scaled = SafeMath.clampedInt((percent * 100).rounded())
        return BucketRange(lowerBasisPoints: 0, upperBasisPoints: scaled)
    }

    /// Zero for an inverted range rather than a negative width.
    public var widthBasisPoints: Int {
        max(0, SafeMath.addingSaturating(upperBasisPoints, -lowerBasisPoints))
    }

    public var isEmpty: Bool { upperBasisPoints <= lowerBasisPoints }

    public var isInverted: Bool { upperBasisPoints < lowerBasisPoints }

    public func contains(_ bucket: Int) -> Bool {
        bucket >= lowerBasisPoints && bucket < upperBasisPoints
    }
}

/// Verifies that a bucketing function is actually stable, using golden vectors.
///
/// This exists because the failure mode it guards is invisible to the obvious
/// test. Calling a bucketer twice in one process and asserting the two results
/// match passes for `Hasher`-based implementations too — `Hasher` is seeded once
/// per process, so within a single test run it looks perfectly deterministic.
/// The only honest check is against values fixed outside the process.
///
/// `FleetRolloutTests` uses this both ways: the real bucketer passes, and a
/// deliberately broken one is asserted to *fail*.
public enum BucketStabilityCheck {

    public struct Vector: Sendable, Hashable {
        public let flagKey: String
        public let salt: String
        public let stableIdentifier: String
        public let expectedBucket: Int

        public init(flagKey: String, salt: String, stableIdentifier: String, expectedBucket: Int) {
            self.flagKey = flagKey
            self.salt = salt
            self.stableIdentifier = stableIdentifier
            self.expectedBucket = expectedBucket
        }
    }

    public struct Failure: Sendable, Hashable, CustomStringConvertible {
        public let vector: Vector
        public let actualBucket: Int
        public var description: String {
            "bucket(\(vector.flagKey), \(vector.salt), \(vector.stableIdentifier)) "
            + "== \(actualBucket), expected \(vector.expectedBucket)"
        }
    }

    /// Golden vectors, committed as constants. Regenerating these to make a
    /// failing build pass is a breaking change to every in-flight rollout: every
    /// device would re-bucket at once.
    public static let goldenVectors: [Vector] = [
        Vector(flagKey: "checkout.duo_layout", salt: "s1", stableIdentifier: "device-0000", expectedBucket: 1411),
        Vector(flagKey: "checkout.duo_layout", salt: "s1", stableIdentifier: "device-0001", expectedBucket: 3200),
        Vector(flagKey: "checkout.duo_layout", salt: "s2", stableIdentifier: "device-0000", expectedBucket: 8426),
        Vector(flagKey: "search.rerank", salt: "s1", stableIdentifier: "device-0000", expectedBucket: 2947),
        Vector(flagKey: "", salt: "", stableIdentifier: "", expectedBucket: 6677)
    ]

    /// Runs `bucketer` against the vectors and returns every mismatch.
    public static func failures(
        of bucketer: (_ flagKey: String, _ salt: String, _ stableIdentifier: String) -> Int,
        vectors: [Vector] = goldenVectors
    ) -> [Failure] {
        vectors.compactMap { vector in
            let actual = bucketer(vector.flagKey, vector.salt, vector.stableIdentifier)
            guard actual != vector.expectedBucket else { return nil }
            return Failure(vector: vector, actualBucket: actual)
        }
    }
}
