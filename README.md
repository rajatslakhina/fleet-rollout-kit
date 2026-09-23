# FleetRollout

**On 21 September 2026 the iOS version stopped being a line, and every feature flag written as `osVersion >= "27.1"` quietly started targeting the wrong fleet.**

iOS 27.1 shipped **only** to iPhone Duo. Every other iPhone went from 27.0 straight to 27.2 ([9to5Mac, 21 Sep 2026](https://9to5mac.com/2026/09/21/apple-releases-second-ios-27-2-developer-beta-for-iphone/)). A device on 27.2 therefore never executed a single line of 27.1's code — and `>= 27.1` matches it anyway. On the same day, Apple [closed the downgrade path off iOS 27](https://9to5mac.com/2026/09/21/iphone-users-running-ios-27-can-no-longer-downgrade-to-ios-26/), so a user who takes a bad build of your app on a bad OS train cannot roll *themselves* out of it. Your remote config is the only way back.

Run both rules over the same simulated 10,000-device fleet and the gap is not subtle:

| Rule | Devices treated | |
|---|---|---|
| `onTrain(["ios-27.1-duo"])` — set membership | **2.1%** (210 devices) | what you meant |
| `osVersion >= 27.1` — version ordering | **72.4%** (7,242 devices) | what you shipped |

A **34× over-exposure**, on a fleet that can no longer downgrade away from it. Both device counts are asserted exactly — not as loose bounds — in `FleetSimulatorTests.testVersionComparisonWouldHaveOverExposedTheFleet`, which runs the real evaluator over the real fleet generator. A regression from 210 treated devices to 490 fails that test rather than sliding under a `< 5%` assertion.

FleetRollout is the client half of a fleet-targeting remote-config and kill-switch system built for that world: signed versioned documents, stale-while-revalidate serving, deterministic sticky bucketing, a kill path with a measured propagation SLO, and exposure logging that is attributable in a crash dashboard.

---

## Why this matters

A feature flag client looks like a lookup table and behaves like a distributed system. It has a cache with two different correctness requirements, a replay-attack surface, a deterministic-hashing problem, a propagation SLO it usually cannot meet, and a failure mode — serving a feature you already killed — that nobody notices until it is the incident.

Four decisions are the ones you would actually have to defend in review.

### 1. There is no `>=` over OS versions, and you cannot add one

The obvious fix for the 27.1/27.2 fork is a smarter comparison. It is the wrong fix, because it has to be re-litigated on every flag, forever, by whoever writes it next.

`TargetingPredicate` is a closed enum, and it exposes **no ordering operator over build trains at all** — only `onTrain(Set<String>)` and `onLineage(Set<Lineage>)`. A `BuildTrain` is an identity (`ios-27.1-duo`), not a number. The wrong expression is not merely discouraged; it is inexpressible.

Ordering *is* allowed on `appBuildAtLeast` / `appBuildAtMost`, and the contrast is the point: your app's build number is monotonic because you control it. Apple's release graph is not, because you do not.

**Rejected:** a `semver` comparator with a per-flag "strict train" escape hatch. It moves the decision from the type system to the code reviewer, which is where this bug came from.

### 2. A monotonic version floor, because a valid document can still be the wrong one

Once the device has accepted document version N, **no version below N is ever served again — from the network, from last-known-good, or from disk.**

Without that, the kill switch has a hole you cannot see in a unit test. Kill a flag in v6. A CDN edge somewhere is still serving v5 — a perfectly valid, perfectly signed document in which the feature is alive. The device fetches it, verifies it, installs it, and the killed feature is back on. Nothing errored. Nothing logged. The dashboard says the kill shipped.

`ConfigStoreTests.testAStaleEdgeCannotResurrectAKilledFlag` runs exactly that sequence and asserts the flag stays dead. Its paired negative, `testWithoutTheVersionFloorTheKillIsUndone`, wires in `NewestResponseWinsPolicy` — the intuitive "take whatever the server sent last" rule — and asserts the kill **is** undone. The guarantee is shown to depend on the code that implements it.

**Rejected:** trusting `issuedAt` timestamps. Clock skew between publisher regions is real, and a timestamp is a claim inside the document rather than a fact about this device's history.

### 3. Bucketing is FNV-1a, specified, because `hashValue` is seeded per process

`StableBucketer` hashes `"flagKey:salt:stableIdentifier"` with FNV-1a/64 into 10,000 basis points — 0.01% resolution, because a 0.05% canary is a real ask on a large fleet and rounding it to "0% or 1%" is a two-order-of-magnitude error in blast radius.

It is deliberately not Swift's `Hasher`. `Hasher` is seeded with a per-process random value, so the same device lands in a different bucket on every cold start: the feature flickers, every experiment reading it is silently invalid, and a user who just crashed in the treatment can land right back in it. **This bug is invisible to the obvious test** — calling the bucketer twice in one process and asserting the results match passes, because within a single process `Hasher` really is deterministic.

So the guard is `BucketStabilityCheck`, which validates a bucketer against golden vectors fixed outside the process. `BucketingTests` runs it three ways: the real bucketer passes; a `hashValue`-based bucketer is asserted to **fail**; and the naive same-process assertion is demonstrated passing for the broken one, so the reason the check exists is visible in the test file.

The **`(flagKey, salt)` pair** is the bucketing namespace, and both halves earn their place. The flag key is in the hash input so that two flags are decorrelated *by construction*: a system that hashes only `(salt, id)` is correlated by default and relies on an operator remembering a distinct salt everywhere, so the first copy-pasted flag definition puts two independent 10% rollouts on the same tenth of the fleet — permanently over-exposed, with confounded results and a crash rate that is not the fleet's. The salt is then free to be the **rotation handle**: bump it to reshuffle one flag's population without renaming the flag, which is what re-running an experiment on a fresh split needs. `testFlagKeyAndSaltEachReshuffleTheFleetIndependently` pins both: two flags sharing a salt overlap on 1.07% of a 40,000-device fleet, and one flag re-salted overlaps its old treatment on 1.05% — the ~1% of two independent 10% slices, in both directions.

**Rejected:** SipHash via `Hasher(seed:)`. It is a better hash, and Swift gives you no supported way to pin the seed across processes, which makes it exactly the property this needs and cannot have. Also rejected: hashing only `(salt, id)`, which is what most flag SDKs do and which makes decorrelation an operator responsibility rather than a property of the system.

### 4. Two different consistency answers in one system

Serving a five-minute-stale "feature is on" is fine. Blocking app launch on a config fetch is a far more reliable way to hurt users. So the config path is availability-first: stale-while-revalidate, with a bundled fallback → last-known-good → network precedence ladder.

Serving a stale "feature is on" *after it was killed* is the one thing this system exists to prevent. So the kill path is correctness-first, via the version floor above.

The launch fetch has a hard `Duration` budget that is **spent, not extended** — on expiry the in-flight request is genuinely cancelled, because a launch fetch that outlives its budget is competing for the connection pool with the first screen's own traffic. One wasted request costs less than that contention. `testLaunchBudgetIsSpentNotExtended` measures two different budgets against the same permanently-hanging transport and asserts the wait tracked the budget, so an implementation that ignored it and used some other fixed timeout fails.

And the SLO is measured, not assumed. `PropagationSimulator` models the four channels with honest delivery rates, and the answer is uncomfortable (5,000 devices, seed 7, one-hour window):

| Channels | Coverage in 1h | p50 | p95 |
|---|---|---|---|
| All four (push + foreground + launch + background refresh) | **92.2%** | 19s | 35.5 min |
| Guaranteed only (push and background refresh assumed dead) | **55.3%** | 23.8 min | 55.2 min |

**Neither meets a 95%-in-15-minutes SLO.** Silent push carries 3,617 of 5,000 devices in under 30 seconds and then does nothing at all for the tail, because the tail is devices that are not running your app. A kill switch's SLO is bounded by engagement, not by infrastructure. `PropagationChannel.isGuaranteed` encodes which two channels are best-effort by Apple's own documentation, and `testNeitherChannelSetMeetsANaiveKillSwitchSLO` pins all six of those figures — the coverages to ±0.0001 and the latencies to ±1 second — rather than to tolerances wide enough to hide a regression.

**Rejected:** modelling push as a guaranteed channel and reporting the resulting p95 as the kill SLO. That produces a number under a minute, which is the number teams actually quote, and it is a fiction: APNs content-available delivery is best-effort and rate-limited, and background refresh is scheduled at the system's discretion. Budgeting a kill switch against channels that may never fire is how you find out mid-incident.

---

## What's in it

| Type | Responsibility |
|---|---|
| `BuildTrain`, `DeviceContext` | Identity-based OS train model; the closed set of dimensions a rule may read |
| `TargetingPredicate` | Depth-bounded targeting language with no version ordering |
| `ConfigDocument`, `FlagDefinition`, `RolloutRule` | Signed, versioned config schema |
| `DocumentValidator` | 13 structural defects, split into fatal (ambiguity) and warning (operability) |
| `StableBucketer`, `BucketRange`, `BucketStabilityCheck` | Deterministic basis-point bucketing and its cross-process stability guard |
| `Evaluator`, `Assignment`, `EvaluationReason` | Pure evaluation; every answer carries its provenance |
| `ConfigStore` | Actor: SWR serving, single-flight revalidation, quarantine, launch budget |
| `MonotonicVersionFloorPolicy`, `VersionFloorCheck` | The anti-rollback rule and its adversarial test seam |
| `ExposureLog` | Bounded, de-duplicating ring that reports what it dropped |
| `PropagationSimulator`, `PropagationSLO` | Time-to-kill measurement across four channels |
| `FleetSimulator`, `SplitMix64` | Reproducible synthetic fleets across the forked 27.1/27.2 trains |
| `FleetRolloutUI` | SwiftUI dashboard driven entirely by the real evaluator and simulator |

### Deliberate non-goals

**No cryptography.** `IntegrityEnvelope` carries a key identifier and a signature; `DocumentIntegrityVerifying` is a protocol the app implements with CryptoKit `P256.Signing` or swift-crypto. Rolling a signature scheme by hand is how you get a config channel that looks signed and is not. What the package *does* own is the policy around verification — an integrity failure **quarantines** the document (never served, never promoted to last-known-good, and critically, the version floor does not move, so an unverified document cannot lock out the real one), while a network failure falls back to last-known-good. Those are different failures and they must not share a code path.

**No device access.** `DeviceContext` is passed in, never read. That is what makes `Evaluator` a pure function, which is what lets `FleetSimulator` push 10,000 devices through the exact code path a real device takes.

### Safety

No force-unwraps anywhere in `Sources/`. Every collection access is bounds-checked — through `SafeMath.clampedIndex` where the index is caller-supplied (`Percentile.value`, the dashboard's device inspector), and by a stated construction invariant otherwise (`ExposureLog`'s ring head is `< capacity` because `capacity >= 1` and the head only ever moves by `(head + 1) % capacity`; `FleetSimulator.makeFleet` guards `!cohorts.isEmpty` before it touches `cohorts[0]`, and `FleetComposition.init` substitutes a default for an empty `appBuilds`). Every trapping arithmetic operation reachable from the public API — `Int(Double)` on NaN/infinity/out-of-range, `/` and `%` by zero, `Int.min / -1`, `+`/`*` overflow — routed through saturating helpers, with `Int`-range ceilings derived from `Int.max` rather than 64-bit literals (`Int` is 32-bit on watchOS). `TargetingPredicate.depth()` is computed with an explicit stack rather than by recursion, because the recursive version blows the stack on exactly the pathological remote document it was added to detect. `BucketRange` has a hand-written `init(from:)` so that decoding cannot bypass its bounds clamp — synthesised `Codable` would let a remote document hand the client a 99,999-basis-point upper bound, and failing *open* on ramp width is not acceptable here. `ExposureLog` is a fixed-capacity ring whose de-duplication table is bounded too, and the test asserts the *table* size rather than the ring's, which is the number that actually moves.

---

## Usage

```swift
.package(url: "https://github.com/rajatslakhina/fleet-rollout-kit.git", from: "1.1.0")
```

```swift
import FleetRollout

let store = ConfigStore(
    bundledFallback: compiledInDocument,       // ships in the binary; works offline
    transport: CDNTransport(),
    verifier: P256DocumentVerifier(publicKeys: keys),
    lastKnownGood: KeychainBackedStore())

await store.restore()                          // adopt cached config, never downgrading
await store.warmUp(budget: .milliseconds(400)) // launch fetch, budget spent not extended

let evaluator = await store.evaluator(fallback: appFallbacks)
let assignment = evaluator.evaluate("checkout.duo_layout", for: deviceContext)

await exposureLog.record(assignment, at: .now)

if assignment.value.boolValue == true { showDuoLayout() }
// assignment.reason / .bucket / .matchedRuleID answer "why did *this* device get it"
```

## Running it

```bash
swift build -Xswiftc -warnings-as-errors
swift test
```

## Verification

Stated as what was observed, not as what is expected to happen:

- `swift build -Xswiftc -warnings-as-errors` from a clean `.build` on Swift 6.0.3 (Linux, aarch64): **observed to succeed with zero warnings.** The same flag is in the Linux CI job, so future commits are checked by a machine rather than by this paragraph.
- `swift test`: **observed at 110 tests, 0 failures.**
- CI runs on every push and its results are public — see the [Actions tab](https://github.com/rajatslakhina/fleet-rollout-kit/actions). Two jobs: Linux does a clean warnings-as-errors build and the full test suite; macOS resolves the package and compiles every scheme for a generic iOS Simulator destination, which is what checks that `FleetRolloutUI` builds for iOS.
- The demo app was **not** launched on a Simulator during the run that produced this repository. It was never built by Xcode here and never ran. See the companion repo's README for the exact scope of what was and was not verified.

## Companion demo app

[**rajatslakhina/fleet-rollout-kit-demo-app**](https://github.com/rajatslakhina/fleet-rollout-kit-demo-app) — a SwiftUI app that consumes this package as a version-pinned remote Swift Package dependency and puts the ramp, the kill switch and the propagation model behind three controls.

## License

MIT
