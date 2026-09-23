import FleetRollout
import Foundation

// FleetRolloutDemo — runs the four scenarios FleetRollout's README argues from,
// against the real package types (no fixtures, no mocking).

func percentString(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

// MARK: - Scenario 1: set-membership targeting vs. version-ordering targeting

func scenarioOne() {
    print("=== Scenario 1: onTrain(set) vs. a version-ordering rule over the forked fleet ===")
    let fleet = FleetSimulator.makeFleet(size: 10_000)

    let correctFlag = FlagDefinition(
        key: "checkout.duo_layout", salt: "demo-salt-correct",
        variants: [Variant(key: "on", value: .bool(true)), Variant(key: "off", value: .bool(false))],
        defaultVariantKey: "off",
        rules: [RolloutRule(id: "duo-only", predicate: .onTrain(["ios-27.1-duo"]), variantKey: "on")])

    // The rule nobody would write on purpose, but that `osVersion >= "27.1"`
    // is equivalent to on this fleet: every train whose marketing version
    // sorts at or above 27.1. FleetRollout's predicate language has no
    // ordering operator, so this is expressed the only way an ordering
    // comparison *can* be expressed here — by enumerating the trains it
    // would actually match.
    let versionOrderedFlag = correctFlag.replacingRules([
        RolloutRule(id: "gte-27.1", predicate: .onTrain(["ios-27.1-duo", "ios-27.2"]), variantKey: "on")
    ])

    let document = ConfigDocument(documentVersion: 1, issuedAt: .now, flags: [correctFlag])
    let evaluator = Evaluator(document: document, fallback: .empty)
    let correctExposure = FleetSimulator.exposure(
        of: "checkout.duo_layout", evaluator: evaluator, fleet: fleet, treatedVariantKeys: ["on"])

    let versionDocument = ConfigDocument(documentVersion: 1, issuedAt: .now, flags: [versionOrderedFlag])
    let versionEvaluator = Evaluator(document: versionDocument, fallback: .empty)
    let versionExposure = FleetSimulator.exposure(
        of: "checkout.duo_layout", evaluator: versionEvaluator, fleet: fleet, treatedVariantKeys: ["on"])

    let correctTreated = correctExposure.byVariant["on"] ?? 0
    let versionTreated = versionExposure.byVariant["on"] ?? 0
    let correctPercent = percentString(correctExposure.share(ofVariant: "on"))
    let versionPercent = percentString(versionExposure.share(ofVariant: "on"))
    print("  onTrain([\"ios-27.1-duo\"])          "
          + "treated \(correctTreated) / \(fleet.count) devices (\(correctPercent))")
    print("  onTrain([\"...-duo\", \"...-27.2\"])    "
          + "treated \(versionTreated) / \(fleet.count) devices (\(versionPercent))")
    if correctTreated > 0 {
        let factor = Double(versionTreated) / Double(correctTreated)
        print(String(format: "  over-exposure factor: %.1fx", factor))
    }
}

// MARK: - Scenario 2: monotonic version floor stops a stale edge resurrecting a kill

struct SequencedTransport: ConfigTransport {
    let documents: [ConfigDocument]
    let index: AtomicIndex

    final class AtomicIndex: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    func fetch(knownVersion: Int) async throws -> TransportResponse {
        let position = min(index.next(), documents.count - 1)
        return .document(documents[position])
    }
}

func scenarioTwo() async {
    print("\n=== Scenario 2: a stale CDN edge cannot resurrect a killed flag ===")
    let flagOn = FlagDefinition(
        key: "promo.banner", salt: "demo-salt-promo",
        variants: [Variant(key: "on", value: .bool(true)), Variant(key: "off", value: .bool(false))],
        defaultVariantKey: "off",
        rules: [RolloutRule(id: "everyone", predicate: .always, variantKey: "on")])

    let v5Live = ConfigDocument(documentVersion: 5, issuedAt: .now.addingTimeInterval(-600), flags: [flagOn])
    let v6Killed = ConfigDocument(documentVersion: 6, issuedAt: .now, flags: [flagOn.settingKilled(true)])
    // The stale edge: a real, validly-signed v5 in which the feature is
    // still alive, served again after the client already accepted v6.
    let staleV5Replay = v5Live

    let bundled = ConfigDocument(
        documentVersion: 0, issuedAt: .now.addingTimeInterval(-3_600), flags: [flagOn.settingKilled(true)])
    let transport = SequencedTransport(documents: [v5Live, v6Killed, staleV5Replay], index: .init())
    let store = ConfigStore(bundledFallback: bundled, transport: transport)

    let firstFetch = await store.refresh()
    let killFetch = await store.refresh()
    let replayFetch = await store.refresh()

    print("  fetch 1 (v5, live):    \(firstFetch)")
    print("  fetch 2 (v6, killed):  \(killFetch)")
    print("  fetch 3 (stale v5 replay): \(replayFetch)")

    let evaluator = await store.evaluator(fallback: .empty)
    let device = DeviceContext(
        stableIdentifier: "demo-device", buildTrain: .ios27_2, deviceClass: .phoneStandard,
        posture: .fixed, appBuild: 1200)
    let assignment = evaluator.evaluate("promo.banner", for: device)
    let versionFloor = await store.acceptedVersionFloor()
    print("  served after replay: variant=\(assignment.variantKey) reason=\(assignment.reason) "
          + "version floor=\(versionFloor)")
    print("  kill held: \(assignment.reason == .killed ? "yes" : "NO -- REGRESSION")")
}

// MARK: - Scenario 3: bucketing stability — the real bucketer vs. a hashValue-seeded one

func scenarioThree() {
    print("\n=== Scenario 3: BucketStabilityCheck against golden vectors ===")
    let realFailures = BucketStabilityCheck.failures(of: StableBucketer.bucket(flagKey:salt:stableIdentifier:))
    let vectorCount = BucketStabilityCheck.goldenVectors.count
    print("  real FNV-1a bucketer:  \(realFailures.count) failures against \(vectorCount) golden vectors")

    struct HashValueBucketer {
        static func bucket(flagKey: String, salt: String, stableIdentifier: String) -> Int {
            var hasher = Hasher()
            hasher.combine(flagKey); hasher.combine(salt); hasher.combine(stableIdentifier)
            return abs(hasher.finalize()) % StableBucketer.bucketSpace
        }
    }
    let brokenFailures = BucketStabilityCheck.failures(of: HashValueBucketer.bucket(flagKey:salt:stableIdentifier:))
    print("  hashValue-seeded bucketer: \(brokenFailures.count) failures against \(vectorCount) golden vectors")
    print("  (expected to diverge — Hasher is seeded per process)")
}

// MARK: - Scenario 4: propagation SLO across four channels vs. guaranteed-only

func scenarioFour() {
    print("\n=== Scenario 4: measured time-to-kill across a 5,000-device fleet ===")
    let allChannels = PropagationSimulator.timeToKill(fleetSize: 5_000, channels: Set(PropagationChannel.allCases))
    let guaranteedOnly = PropagationSimulator.timeToKill(
        fleetSize: 5_000,
        channels: Set(PropagationChannel.allCases.filter(\.isGuaranteed)))

    print(String(format: "  all four channels:      coverage %@  p50 %.0fs  p95 %.1fmin",
                 percentString(allChannels.coverage), allChannels.p50, allChannels.p95 / 60))
    print(String(format: "  guaranteed only:        coverage %@  p50 %.1fmin  p95 %.1fmin",
                 percentString(guaranteedOnly.coverage), guaranteedOnly.p50 / 60, guaranteedOnly.p95 / 60))
    print("  neither meets a 95%-in-15-minutes SLO.")
}

print("FleetRolloutDemo — fleet-rollout-kit")
print(String(repeating: "=", count: 60))
scenarioOne()
await scenarioTwo()
scenarioThree()
scenarioFour()
print("\ndone.")
