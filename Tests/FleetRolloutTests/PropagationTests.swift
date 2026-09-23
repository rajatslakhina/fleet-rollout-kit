import XCTest
@testable import FleetRollout

final class PropagationTests: XCTestCase {

    func testPercentileIsBoundsSafeOnEmptyAndDegenerateInput() {
        XCTAssertEqual(Percentile.value(0.5, ofSorted: []), 0)
        XCTAssertEqual(Percentile.value(.nan, ofSorted: [1, 2, 3]), 1)
        XCTAssertEqual(Percentile.value(-5, ofSorted: [1, 2, 3]), 1)
        XCTAssertEqual(Percentile.value(99, ofSorted: [1, 2, 3]), 3)
        XCTAssertEqual(Percentile.value(.infinity, ofSorted: [1, 2, 3]), 3)
        XCTAssertEqual(Percentile.value(0.5, ofSorted: [7]), 7)
    }

    /// Nearest-rank percentiles against exact expected values.
    ///
    /// Asserting only that p50 <= p95 <= p99 would be satisfied by an
    /// implementation gutted to always return `values[0]`.
    func testPercentilesLandOnTheNearestRank() {
        let values = (1...1_000).map(TimeInterval.init)
        XCTAssertEqual(Percentile.value(0.50, ofSorted: values), 501)
        XCTAssertEqual(Percentile.value(0.95, ofSorted: values), 950)
        XCTAssertEqual(Percentile.value(0.99, ofSorted: values), 990)
        XCTAssertEqual(Percentile.value(0.0, ofSorted: values), 1)
        XCTAssertEqual(Percentile.value(1.0, ofSorted: values), 1_000)
    }

    func testEmptyFleetProducesAnEmptyReportRatherThanCrashing() {
        let report = PropagationSimulator.timeToKill(fleetSize: 0)
        XCTAssertEqual(report.fleetSize, 0)
        XCTAssertEqual(report.coverage, 0)
        XCTAssertEqual(report.p95, 0)
        XCTAssertEqual(report.unreachedCount, 0)

        let negative = PropagationSimulator.timeToKill(fleetSize: -10)
        XCTAssertEqual(negative.fleetSize, 0)
    }

    func testSimulationIsReproducibleForAGivenSeed() {
        let a = PropagationSimulator.timeToKill(fleetSize: 3_000, seed: 42)
        let b = PropagationSimulator.timeToKill(fleetSize: 3_000, seed: 42)
        XCTAssertEqual(a, b)
        let c = PropagationSimulator.timeToKill(fleetSize: 3_000, seed: 43)
        XCTAssertNotEqual(a.p95, c.p95)
    }

    /// The number teams do not have when they are asked "how fast can we turn
    /// it off?".
    ///
    /// Two findings, and the second is the uncomfortable one:
    ///
    /// 1. Dropping the two best-effort channels is not a rounding error on the
    ///    tail. Coverage over an hour falls from 92.2% to 55.3%.
    /// 2. **Neither configuration meets a 95%-in-15-minutes SLO.** Even with
    ///    silent push carrying 72% of the fleet in under 30 seconds, p95 is
    ///    ~35 minutes, because the tail is devices that are simply not running
    ///    the app. A kill switch's SLO is bounded by engagement, not by
    ///    infrastructure — which is why the launch-time blocking fetch exists
    ///    at all, and why `PropagationSLO.standard` is a target to be measured
    ///    against rather than a promise the transport can keep.
    func testNeitherChannelSetMeetsANaiveKillSwitchSLO() {
        let everything = PropagationSimulator.timeToKill(
            fleetSize: 5_000, channels: Set(PropagationChannel.allCases), seed: 7)
        let guaranteed = PropagationSimulator.timeToKill(
            fleetSize: 5_000,
            channels: Set(PropagationChannel.allCases.filter(\.isGuaranteed)),
            seed: 7)

        XCTAssertGreaterThan(guaranteed.p95, everything.p95)
        XCTAssertGreaterThan(everything.coverage, guaranteed.coverage)

        // Every figure the README tabulates is pinned here, exactly. Loose
        // tolerances would let a 92.2% coverage regress to 90.1% unnoticed,
        // which is the difference between an honest table and a decorative one.
        XCTAssertEqual(everything.coverage, 0.9220, accuracy: 0.0001)
        XCTAssertEqual(everything.p50, 19, accuracy: 1)
        XCTAssertEqual(everything.p95, 2_130, accuracy: 1)
        XCTAssertEqual(guaranteed.coverage, 0.5534, accuracy: 0.0001)
        XCTAssertEqual(guaranteed.p50, 1_427, accuracy: 1)
        XCTAssertEqual(guaranteed.p95, 3_315, accuracy: 1)

        XCTAssertFalse(everything.meets(.standard))
        XCTAssertFalse(guaranteed.meets(.standard))

        // Push moves the median almost instantly and does nothing for the tail.
        XCTAssertEqual(everything.channelAttribution[.silentPush] ?? 0, 3_617)
    }

    func testNoChannelsMeansNobodyIsEverReached() {
        let report = PropagationSimulator.timeToKill(fleetSize: 500, channels: [])
        XCTAssertEqual(report.unreachedCount, 500)
        XCTAssertEqual(report.coverage, 0)
        XCTAssertTrue(report.channelAttribution.isEmpty)
    }

    /// Attribution has to reflect the channels that were actually available.
    ///
    /// The bookkeeping identity (attributed + unreached == fleetSize) holds by
    /// construction of the accumulation loop and proves nothing, so it is
    /// asserted only as a guard. The real assertion is that switching a channel
    /// off removes it from the attribution *and* moves the median — which is a
    /// statement about the model, not about the counters.
    func testAttributionFollowsTheChannelsThatActuallyFire() {
        let withPush = PropagationSimulator.timeToKill(fleetSize: 5_000, seed: 7)
        XCTAssertEqual(
            withPush.channelAttribution.values.reduce(0, +) + withPush.unreachedCount,
            withPush.fleetSize)
        XCTAssertEqual(withPush.channelAttribution[.silentPush], 3_617)

        let noPush = PropagationSimulator.timeToKill(
            fleetSize: 5_000,
            profile: WakeProfile(
                meanForegroundInterval: 5_400,
                silentPushDeliveryRate: 0,
                meanBackgroundInterval: 3_600,
                backgroundRefreshEnabledRate: 0.55),
            seed: 7)
        XCTAssertNil(noPush.channelAttribution[.silentPush])
        XCTAssertEqual(noPush.p50, 1_171, accuracy: 1)
        XCTAssertGreaterThan(noPush.p50, withPush.p50 * 50)
    }

    /// A shorter observation window must strand more devices and truncate the
    /// tail. Asserting only that latencies fall inside the window would be
    /// vacuous — `consider()` refuses anything past it by construction.
    func testShrinkingTheWindowStrandsMoreDevices() {
        let short = PropagationSimulator.timeToKill(
            fleetSize: 4_000, observationWindow: 300, seed: 3)
        let long = PropagationSimulator.timeToKill(
            fleetSize: 4_000, observationWindow: 3_600, seed: 3)

        XCTAssertEqual(short.unreachedCount, 1_012)
        XCTAssertEqual(long.unreachedCount, 327)
        XCTAssertGreaterThan(short.unreachedCount, long.unreachedCount * 3)
        XCTAssertGreaterThan(long.p99, short.p99 * 10)
    }

    func testSLOClampsItsInputs() {
        let slo = PropagationSLO(deadline: -100, targetCoverage: 5, channels: [.silentPush])
        XCTAssertEqual(slo.deadline, 0)
        XCTAssertEqual(slo.targetCoverage, 1)
        XCTAssertEqual(PropagationSLO.standard.guaranteedOnly.channels,
                       [.launchBlockingFetch, .foregroundPoll])
    }

    func testChannelGuaranteesMatchPlatformReality() {
        XCTAssertFalse(PropagationChannel.silentPush.isGuaranteed)
        XCTAssertFalse(PropagationChannel.backgroundRefresh.isGuaranteed)
        XCTAssertTrue(PropagationChannel.launchBlockingFetch.isGuaranteed)
        XCTAssertTrue(PropagationChannel.foregroundPoll.isGuaranteed)
    }

    /// The draw has to be finite, non-negative **and actually exponential**.
    ///
    /// The finiteness assertions alone would pass against an implementation
    /// gutted to `return 0`, so the sample mean is checked against the
    /// requested mean — which is the one property the propagation model
    /// depends on.
    func testExponentialSamplesAreFiniteAndDistributedAroundTheMean() {
        var generator = SplitMix64(seed: 99)
        var total = 0.0
        var largest = 0.0
        let count = 20_000
        for _ in 0..<count {
            let sample = PropagationSimulator.exponential(mean: 1_800, using: &generator)
            XCTAssertTrue(sample.isFinite)
            XCTAssertGreaterThanOrEqual(sample, 0)
            total += sample
            largest = max(largest, sample)
        }
        XCTAssertEqual(total / Double(count), 1_800, accuracy: 60)
        XCTAssertGreaterThan(largest, 1_800 * 5, "an exponential has a long tail; this one has none")
        var zeroMean = SplitMix64(seed: 1)
        XCTAssertEqual(PropagationSimulator.exponential(mean: 0, using: &zeroMean), 0)
        var negativeMean = SplitMix64(seed: 1)
        XCTAssertEqual(PropagationSimulator.exponential(mean: -5, using: &negativeMean), 0)
    }
}
