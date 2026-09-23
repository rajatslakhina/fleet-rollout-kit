import XCTest
@testable import FleetRollout

// MARK: - Doubles

actor ScriptedTransport: ConfigTransport {
    enum Step: Sendable {
        case document(ConfigDocument)
        case notModified
        case failure(String)
        case hang
    }

    private var steps: [Step]
    private(set) var callCount = 0
    private let delay: Duration

    init(steps: [Step], delay: Duration = .zero) {
        self.steps = steps
        self.delay = delay
    }

    func fetch(knownVersion: Int) async throws -> TransportResponse {
        callCount += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        guard !steps.isEmpty else { throw TransportError.exhausted }
        let step = steps.removeFirst()
        switch step {
        case .document(let document): return .document(document)
        case .notModified: return .notModified
        case .failure(let message): throw TransportError.scripted(message)
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw TransportError.exhausted
        }
    }

    func observedCallCount() -> Int { callCount }

    enum TransportError: Error { case scripted(String), exhausted }
}

struct AlwaysFailingVerifier: DocumentIntegrityVerifying {
    struct Rejected: Error {}
    func verify(_ document: ConfigDocument) throws { throw Rejected() }
}

struct VersionGatedVerifier: DocumentIntegrityVerifying {
    struct Rejected: Error {}
    let rejecting: Set<Int>
    func verify(_ document: ConfigDocument) throws {
        if rejecting.contains(document.documentVersion) { throw Rejected() }
    }
}

final class MutableClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { self.current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(by interval: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(interval); lock.unlock()
    }
}

/// The intuitive acceptance rule, and the one with the bug: "take whatever the
/// server most recently sent."
struct NewestResponseWinsPolicy: DocumentAcceptancePolicy {
    func shouldAccept(offeredVersion: Int, acceptedFloor: Int) -> Bool { true }
}

// MARK: - Tests

final class ConfigStoreTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_758_585_600)

    private func makeStore(
        bundled: ConfigDocument? = nil,
        transport: ScriptedTransport,
        verifier: DocumentIntegrityVerifying = UnverifiedIntegrity(),
        lastKnownGood: LastKnownGoodStore = InMemoryLastKnownGoodStore(),
        clock: WallClock? = nil,
        acceptance: DocumentAcceptancePolicy = MonotonicVersionFloorPolicy()
    ) -> ConfigStore {
        ConfigStore(
            bundledFallback: bundled ?? Fixture.document(version: 1, issuedAt: epoch),
            transport: transport,
            verifier: verifier,
            lastKnownGood: lastKnownGood,
            clock: clock ?? MutableClock(epoch),
            acceptance: acceptance)
    }

    func testStartsOnBundledFallback() async {
        let store = makeStore(transport: ScriptedTransport(steps: []))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.source, .bundledFallback)
        XCTAssertEqual(snapshot.document.documentVersion, 1)
    }

    func testAcceptsNewerDocument() async {
        let transport = ScriptedTransport(steps: [
            .document(Fixture.document(version: 5, issuedAt: epoch))
        ])
        let store = makeStore(transport: transport)
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .updated(toVersion: 5))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.source, .network)
        let actual1 = await store.acceptedVersionFloor()
        XCTAssertEqual(actual1, 5)
    }

    /// The scenario the version floor exists for, end to end.
    ///
    /// A flag is killed in v6. A CDN edge then serves the still-alive v5 — a
    /// perfectly valid, perfectly signed document. Without the floor the device
    /// installs it and the killed feature is back on. This test fails the moment
    /// the floor is removed.
    func testAStaleEdgeCannotResurrectAKilledFlag() async {
        let alive = Fixture.document(version: 5, issuedAt: epoch, flags: [
            Fixture.flag(rules: [RolloutRule(id: "all", predicate: .always, variantKey: "on")])
        ])
        let killed = Fixture.document(version: 6, issuedAt: epoch, flags: [
            Fixture.flag(
                rules: [RolloutRule(id: "all", predicate: .always, variantKey: "on")],
                killed: true)
        ])
        let transport = ScriptedTransport(steps: [
            .document(alive), .document(killed), .document(alive)
        ])
        let store = makeStore(transport: transport)

        await store.refresh()
        await store.refresh()
        var evaluator = await store.evaluator(fallback: Fixture.fallback)
        XCTAssertEqual(evaluator.evaluate("checkout.duo_layout", for: Fixture.device()).reason, .killed)

        let replay = await store.refresh()
        XCTAssertEqual(replay, .rejectedStaleVersion(offered: 5, floor: 6))
        evaluator = await store.evaluator(fallback: Fixture.fallback)
        XCTAssertEqual(
            evaluator.evaluate("checkout.duo_layout", for: Fixture.device()).reason, .killed,
            "a replayed older document resurrected a killed flag")
        let diagnostics = await store.currentDiagnostics()
        XCTAssertEqual(diagnostics.staleVersionRejections, 1)
    }

    /// Same scenario, same store, but with the naive acceptance policy wired in.
    /// The kill is undone. This is the paired negative case: the guarantee the
    /// README claims is shown to actually depend on the code that implements it.
    func testWithoutTheVersionFloorTheKillIsUndone() async {
        let alive = Fixture.document(version: 5, issuedAt: epoch, flags: [
            Fixture.flag(rules: [RolloutRule(id: "all", predicate: .always, variantKey: "on")])
        ])
        let killed = Fixture.document(version: 6, issuedAt: epoch, flags: [
            Fixture.flag(
                rules: [RolloutRule(id: "all", predicate: .always, variantKey: "on")],
                killed: true)
        ])
        let transport = ScriptedTransport(steps: [
            .document(alive), .document(killed), .document(alive)
        ])
        let store = makeStore(transport: transport, acceptance: NewestResponseWinsPolicy())

        await store.refresh()
        await store.refresh()
        await store.refresh()
        let evaluator = await store.evaluator(fallback: Fixture.fallback)
        XCTAssertEqual(
            evaluator.evaluate("checkout.duo_layout", for: Fixture.device()).reason, .ruleMatch)
    }

    func testEqualVersionReplayIsAcceptedButChangesNothingHarmful() async {
        let document = Fixture.document(version: 5, issuedAt: epoch)
        let transport = ScriptedTransport(steps: [.document(document), .document(document)])
        let store = makeStore(transport: transport)
        let actual2 = await store.refresh()
        XCTAssertEqual(actual2, .updated(toVersion: 5))
        let actual3 = await store.refresh()
        XCTAssertEqual(actual3, .updated(toVersion: 5))
        let actual4 = await store.acceptedVersionFloor()
        XCTAssertEqual(actual4, 5)
    }

    func testIntegrityFailureQuarantinesTheDocument() async {
        let lastKnownGood = InMemoryLastKnownGoodStore()
        let transport = ScriptedTransport(steps: [
            .document(Fixture.document(version: 9, issuedAt: epoch))
        ])
        let store = makeStore(
            transport: transport, verifier: AlwaysFailingVerifier(), lastKnownGood: lastKnownGood)

        let actual5 = await store.refresh()
        XCTAssertEqual(actual5, .rejectedIntegrity)
        // Not served, not promoted, and — critically — the floor did not move,
        // so an unverified document cannot lock out the real one.
        let actual6 = await store.snapshot().source
        XCTAssertEqual(actual6, .bundledFallback)
        let actual7 = await store.acceptedVersionFloor()
        XCTAssertEqual(actual7, 1)
        let saved = await lastKnownGood.load()
        XCTAssertNil(saved)
        let actual8 = await store.currentDiagnostics().integrityRejections
        XCTAssertEqual(actual8, 1)
    }

    func testIntegrityIsCheckedBeforeValidation() async {
        // Structurally broken *and* unsigned. Integrity must win, because a
        // document that failed verification is not evidence of its own defects.
        let broken = Fixture.document(version: 9, issuedAt: epoch, flags: [
            Fixture.flag(key: "dup", salt: "a"), Fixture.flag(key: "dup", salt: "b")
        ])
        let transport = ScriptedTransport(steps: [.document(broken)])
        let store = makeStore(transport: transport, verifier: AlwaysFailingVerifier())
        let actual9 = await store.refresh()
        XCTAssertEqual(actual9, .rejectedIntegrity)
        let actual10 = await store.currentDiagnostics().validationRejections
        XCTAssertEqual(actual10, 0)
    }

    func testInvalidDocumentIsRejectedAndDoesNotMoveTheFloor() async {
        let broken = Fixture.document(version: 9, issuedAt: epoch, flags: [
            Fixture.flag(key: "dup", salt: "a"), Fixture.flag(key: "dup", salt: "b")
        ])
        let transport = ScriptedTransport(steps: [.document(broken)])
        let store = makeStore(transport: transport)
        guard case .rejectedInvalid(let defects) = await store.refresh() else {
            return XCTFail("expected rejectedInvalid")
        }
        XCTAssertTrue(defects.contains(.duplicateFlagKey("dup")))
        let actual11 = await store.acceptedVersionFloor()
        XCTAssertEqual(actual11, 1)
    }

    func testTransportFailureKeepsServingThePreviousDocument() async {
        let transport = ScriptedTransport(steps: [
            .document(Fixture.document(version: 4, issuedAt: epoch)),
            .failure("offline")
        ])
        let store = makeStore(transport: transport)
        await store.refresh()
        guard case .transportFailed = await store.refresh() else {
            return XCTFail("expected transportFailed")
        }
        let actual12 = await store.snapshot().document.documentVersion
        XCTAssertEqual(actual12, 4)
        let actual13 = await store.currentDiagnostics().transportFailures
        XCTAssertEqual(actual13, 1)
    }

    func testNotModifiedIsCountedSeparatelyFromAcceptance() async {
        let transport = ScriptedTransport(steps: [.notModified])
        let store = makeStore(transport: transport)
        let actual14 = await store.refresh()
        XCTAssertEqual(actual14, .notModified)
        let diagnostics = await store.currentDiagnostics()
        XCTAssertEqual(diagnostics.notModifiedCount, 1)
        XCTAssertEqual(diagnostics.acceptedCount, 0)
    }

    func testStaleWhileRevalidateWindows() {
        let document = Fixture.document(
            version: 1, issuedAt: epoch, maxAge: 300, staleWhileRevalidate: 600)
        XCTAssertEqual(ConfigStore.freshness(of: document, age: 0), .fresh)
        XCTAssertEqual(ConfigStore.freshness(of: document, age: 300), .fresh)
        XCTAssertEqual(ConfigStore.freshness(of: document, age: 301), .staleServeable)
        XCTAssertEqual(ConfigStore.freshness(of: document, age: 900), .staleServeable)
        XCTAssertEqual(ConfigStore.freshness(of: document, age: 901), .expired)
    }

    func testSnapshotAgeTracksTheClock() async {
        let clock = MutableClock(epoch)
        let store = makeStore(
            bundled: Fixture.document(version: 1, issuedAt: epoch, maxAge: 300, staleWhileRevalidate: 600),
            transport: ScriptedTransport(steps: []),
            clock: clock)
        let actual15 = await store.snapshot().freshness
        XCTAssertEqual(actual15, .fresh)
        clock.advance(by: 400)
        let actual16 = await store.snapshot().freshness
        XCTAssertEqual(actual16, .staleServeable)
        clock.advance(by: 1_000)
        let actual17 = await store.snapshot().freshness
        XCTAssertEqual(actual17, .expired)
    }

    /// A launch fetch that outruns its budget must return, not wait — and the
    /// budget has to be the thing that decides *when*.
    ///
    /// A single "finished in under five seconds" assertion would pass an
    /// implementation that ignored the budget and used some other fixed
    /// timeout, so this measures two different budgets against the same
    /// permanently-hanging transport and asserts the wait tracked the budget.
    func testLaunchBudgetIsSpentNotExtended() async {
        func elapsed(budget: Duration) async -> (Duration, RefreshOutcome) {
            let store = makeStore(transport: ScriptedTransport(steps: [.hang]))
            let started = ContinuousClock.now
            let outcome = await store.warmUp(budget: budget)
            let took = ContinuousClock.now - started
            let diagnostics = await store.currentDiagnostics()
            XCTAssertEqual(diagnostics.budgetExhaustions, 1)
            let snapshot = await store.snapshot()
            XCTAssertEqual(snapshot.source, .bundledFallback)
            return (took, outcome)
        }

        let (shortWait, shortOutcome) = await elapsed(budget: .milliseconds(150))
        let (longWait, longOutcome) = await elapsed(budget: .milliseconds(1_200))

        XCTAssertEqual(shortOutcome, .budgetExhausted)
        XCTAssertEqual(longOutcome, .budgetExhausted)

        // The transport hangs for 60s. Both waits must be a small multiple of
        // their own budget, and the longer budget must actually wait longer.
        XCTAssertGreaterThanOrEqual(shortWait, .milliseconds(150))
        XCTAssertLessThan(shortWait, .milliseconds(900))
        XCTAssertGreaterThanOrEqual(longWait, .milliseconds(1_200))
        XCTAssertLessThan(longWait, .seconds(4))
        XCTAssertGreaterThan(longWait, shortWait)
    }

    func testLaunchFetchInsideBudgetStillApplies() async {
        let transport = ScriptedTransport(
            steps: [.document(Fixture.document(version: 7, issuedAt: epoch))],
            delay: .milliseconds(10))
        let store = makeStore(transport: transport)
        let actual20 = await store.warmUp(budget: .seconds(5))
        XCTAssertEqual(actual20, .updated(toVersion: 7))
    }

    /// Concurrent background refreshes must coalesce into one request. The test
    /// has real concurrent callers — twelve of them against a transport that is
    /// deliberately slow enough for them to overlap — rather than twelve
    /// sequential calls dressed up as a concurrency test.
    func testConcurrentRefreshesCoalesceIntoOneRequest() async {
        let transport = ScriptedTransport(
            steps: [.document(Fixture.document(version: 12, issuedAt: epoch))],
            delay: .milliseconds(80))
        let store = makeStore(transport: transport)

        let outcomes = await withTaskGroup(of: RefreshOutcome.self) { group in
            for _ in 0..<12 { group.addTask { await store.refresh() } }
            var collected: [RefreshOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let parked = await store.hasInFlightRequest()
        XCTAssertFalse(parked, "the shared request was left parked in the single-flight slot")
        XCTAssertEqual(outcomes.count, 12)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .updated(toVersion: 12) })
        let actual21 = await transport.observedCallCount()
        XCTAssertEqual(actual21, 1)
        let actual22 = await store.currentDiagnostics().acceptedCount
        XCTAssertEqual(actual22, 1)
    }

    /// The single-flight slot must be empty once a refresh has completed.
    ///
    /// The production fix this guards is narrower than the assertion, and the
    /// difference is worth stating rather than dressing up: the slot is
    /// released by the *work*, as its last act on the actor, instead of by the
    /// creating caller after its own continuation resumes. Releasing it in the
    /// caller leaves a window between the fetch finishing and the caller waking
    /// in which an arriving refresh joins an already-completed request and is
    /// silently a no-op — for a push-triggered kill, the one refresh that had to
    /// happen.
    ///
    /// **That interleaving cannot be forced deterministically from outside the
    /// actor**, so this test does not claim to reproduce it. It asserts the
    /// observable invariant instead — no request is left parked in the slot, and
    /// the next refresh reaches the transport — which is what a leak would
    /// break. `testConcurrentRefreshesCoalesceIntoOneRequest` covers the other
    /// half: that genuinely overlapping callers still share one request.
    func testSingleFlightSlotIsEmptyAfterARefreshCompletes() async {
        let transport = ScriptedTransport(steps: [
            .document(Fixture.document(version: 4, issuedAt: epoch)),
            .document(Fixture.document(version: 5, issuedAt: epoch))
        ])
        let store = makeStore(transport: transport)

        let first = await store.refresh()
        let parkedAfterFirst = await store.hasInFlightRequest()
        let second = await store.refresh()
        let parkedAfterSecond = await store.hasInFlightRequest()

        XCTAssertEqual(first, .updated(toVersion: 4))
        XCTAssertEqual(second, .updated(toVersion: 5))
        XCTAssertFalse(parkedAfterFirst)
        XCTAssertFalse(parkedAfterSecond)
        let calls = await transport.observedCallCount()
        XCTAssertEqual(calls, 2)
    }

    /// Across a mixed sequence of newer and replayed documents, the floor only
    /// ever climbs.
    func testVersionFloorNeverMovesBackwardsAcrossAMixedSequence() async {
        let versions = [3, 9, 4, 11, 2, 7, 11, 5]
        let transport = ScriptedTransport(
            steps: versions.map { .document(Fixture.document(version: $0, issuedAt: epoch)) })
        let store = makeStore(transport: transport)

        // The floor after each step, recorded rather than loosely asserted: the
        // interesting shape is that it is non-decreasing while the offered
        // versions are not.
        var observedFloors: [Int] = []
        for _ in versions {
            await store.refresh()
            observedFloors.append(await store.acceptedVersionFloor())
        }
        XCTAssertEqual(observedFloors, [3, 9, 9, 11, 11, 11, 11, 11])
        XCTAssertEqual(zip(observedFloors, observedFloors.dropFirst()).filter { $0 > $1 }.count, 0)
        let actual23 = await store.acceptedVersionFloor()
        XCTAssertEqual(actual23, 11)
        let actual24 = await store.snapshot().document.documentVersion
        XCTAssertEqual(actual24, 11)
    }

    func testRestoreAdoptsLastKnownGoodOnlyWhenItIsNewer() async {
        let saved = Fixture.document(version: 8, issuedAt: epoch)
        let store = makeStore(
            transport: ScriptedTransport(steps: []),
            lastKnownGood: InMemoryLastKnownGoodStore(seed: saved))
        await store.restore()
        let actual25 = await store.snapshot().source
        XCTAssertEqual(actual25, .lastKnownGood)
        let actual26 = await store.acceptedVersionFloor()
        XCTAssertEqual(actual26, 8)
    }

    func testRestoreRefusesAnOlderOrInvalidCache() async {
        let older = Fixture.document(version: 1, issuedAt: epoch)
        let storeA = makeStore(
            bundled: Fixture.document(version: 4, issuedAt: epoch),
            transport: ScriptedTransport(steps: []),
            lastKnownGood: InMemoryLastKnownGoodStore(seed: older))
        await storeA.restore()
        let actual27 = await storeA.snapshot().source
        XCTAssertEqual(actual27, .bundledFallback)

        let corrupt = Fixture.document(version: 99, issuedAt: epoch, flags: [
            Fixture.flag(key: "dup", salt: "a"), Fixture.flag(key: "dup", salt: "b")
        ])
        let storeB = makeStore(
            transport: ScriptedTransport(steps: []),
            lastKnownGood: InMemoryLastKnownGoodStore(seed: corrupt))
        await storeB.restore()
        let actual28 = await storeB.snapshot().source
        XCTAssertEqual(actual28, .bundledFallback)
    }

    func testAcceptedDocumentIsPromotedToLastKnownGood() async {
        let lastKnownGood = InMemoryLastKnownGoodStore()
        let transport = ScriptedTransport(steps: [
            .document(Fixture.document(version: 21, issuedAt: epoch))
        ])
        let store = makeStore(transport: transport, lastKnownGood: lastKnownGood)
        await store.refresh()
        let saved = await lastKnownGood.load()
        XCTAssertEqual(saved?.documentVersion, 21)
    }

    func testRefreshOutcomeDescriptionsAreUseful() {
        XCTAssertEqual(RefreshOutcome.updated(toVersion: 3).description, "updated to v3")
        XCTAssertTrue(RefreshOutcome.updated(toVersion: 3).didChangeDocument)
        XCTAssertFalse(RefreshOutcome.notModified.didChangeDocument)
        XCTAssertTrue(
            RefreshOutcome.rejectedStaleVersion(offered: 2, floor: 5).description
                .contains("below accepted floor"))
        XCTAssertTrue(
            RefreshOutcome.rejectedInvalid([.duplicateFlagKey("a")]).description
                .contains("duplicate flag key"))
    }
}
