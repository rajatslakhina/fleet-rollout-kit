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

    func testPercentilesAreOrdered() {
        let values = (1...1_000).map(TimeInterval.init)
        XCTAssertLessThanOrEqual(Percentile.value(0.5, ofSorted: values),
                                 Percentile.value(0.95, ofSorted: values))
        XCTAssertLessThanOrEqual(Percentile.value(0.95, ofSorted: values),
                                 Percentile.value(0.99, ofSorted: values))
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
        XCTAssertEqual(everything.coverage, 0.92, accuracy: 0.02)
        XCTAssertEqual(guaranteed.coverage, 0.55, accuracy: 0.02)

        XCTAssertFalse(everything.meets(.standard))
        XCTAssertFalse(guaranteed.meets(.standard))

        // `meets` short-circuits on coverage; these two synthetic reports reach
        // the deadline comparison too, on both sides of it.
        let fullCoverageFastEnough = PropagationReport(
            fleetSize: 100, p50: 5, p95: 30, p99: 40, worst: 45,
            unreachedCount: 0, observationWindow: 900, channelAttribution: [:])
        XCTAssertTrue(fullCoverageFastEnough.meets(.standard))

        let fullCoverageTooSlow = PropagationReport(
            fleetSize: 100, p50: 5, p95: 2_000, p99: 2_500, worst: 3_000,
            unreachedCount: 0, observationWindow: 900, channelAttribution: [:])
        XCTAssertFalse(fullCoverageTooSlow.meets(.standard))

        // Push moves the median almost instantly and does nothing for the tail.
        XCTAssertLessThan(everything.p50, 60)
        XCTAssertGreaterThan(everything.p95, 900)
        XCTAssertEqual(everything.channelAttribution[.silentPush] ?? 0, 3_617)
    }

    func testNoChannelsMeansNobodyIsEverReached() {
        let report = PropagationSimulator.timeToKill(fleetSize: 500, channels: [])
        XCTAssertEqual(report.unreachedCount, 500)
        XCTAssertEqual(report.coverage, 0)
        XCTAssertTrue(report.channelAttribution.isEmpty)
    }

    func testAttributionSumsToTheReachedPopulation() {
        let report = PropagationSimulator.timeToKill(fleetSize: 2_500, seed: 11)
        let attributed = report.channelAttribution.values.reduce(0, +)
        XCTAssertEqual(attributed + report.unreachedCount, report.fleetSize)
    }

    func testLatenciesNeverExceedTheObservationWindow() {
        let window: TimeInterval = 300
        let report = PropagationSimulator.timeToKill(
            fleetSize: 4_000, observationWindow: window, seed: 3)
        XCTAssertLessThanOrEqual(report.worst, window)
        XCTAssertLessThanOrEqual(report.p99, window)
        XCTAssertGreaterThan(report.unreachedCount, 0, "a 5-minute window cannot reach everyone")
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

    func testExponentialSamplesAreFiniteAndNonNegative() {
        var generator = SplitMix64(seed: 99)
        for _ in 0..<20_000 {
            let sample = PropagationSimulator.exponential(mean: 1_800, using: &generator)
            XCTAssertTrue(sample.isFinite)
            XCTAssertGreaterThanOrEqual(sample, 0)
        }
        var zeroMean = SplitMix64(seed: 1)
        XCTAssertEqual(PropagationSimulator.exponential(mean: 0, using: &zeroMean), 0)
        var negativeMean = SplitMix64(seed: 1)
        XCTAssertEqual(PropagationSimulator.exponential(mean: -5, using: &negativeMean), 0)
    }
}
