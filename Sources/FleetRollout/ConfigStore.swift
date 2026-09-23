import Foundation

// MARK: - Collaborators

public protocol ConfigTransport: Sendable {
    /// Fetches the newest document. `knownVersion` lets the server answer
    /// `notModified` instead of re-sending an identical body.
    func fetch(knownVersion: Int) async throws -> TransportResponse
}

public enum TransportResponse: Sendable {
    case document(ConfigDocument)
    case notModified
}

public protocol DocumentIntegrityVerifying: Sendable {
    /// Throws if the document's signature does not verify. Implementations live
    /// outside this package; see `IntegrityEnvelope` for why.
    func verify(_ document: ConfigDocument) throws
}

/// Accepts everything. For tests, previews and the simulator only — passing this
/// in production means the config channel is unauthenticated.
public struct UnverifiedIntegrity: DocumentIntegrityVerifying {
    public init() {}
    public func verify(_ document: ConfigDocument) throws {}
}

public protocol LastKnownGoodStore: Sendable {
    func load() async -> ConfigDocument?
    func save(_ document: ConfigDocument) async
}

public actor InMemoryLastKnownGoodStore: LastKnownGoodStore {
    private var document: ConfigDocument?
    public init(seed: ConfigDocument? = nil) { self.document = seed }
    public func load() async -> ConfigDocument? { document }
    public func save(_ document: ConfigDocument) async { self.document = document }
}

public protocol WallClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: WallClock {
    public init() {}
    public var now: Date { Date() }
}

// MARK: - Freshness

public enum Freshness: Hashable, Sendable {
    /// Inside `maxAge`.
    case fresh
    /// Past `maxAge` but inside `staleWhileRevalidate`: serve it, refresh behind.
    case staleServeable
    /// Past both windows.
    case expired
}

/// Where the currently served document came from.
public enum ServingSource: String, Hashable, Sendable, Codable {
    case network
    case lastKnownGood
    case bundledFallback
}

public struct ConfigSnapshot: Sendable {
    public let document: ConfigDocument
    public let source: ServingSource
    public let freshness: Freshness
    /// Age of the document at the moment the snapshot was taken.
    public let age: TimeInterval
}

// MARK: - Outcomes

public enum RefreshOutcome: Hashable, Sendable, CustomStringConvertible {
    case updated(toVersion: Int)
    case notModified
    /// The response verified and validated but was not newer than the highest
    /// version this device has ever accepted.
    case rejectedStaleVersion(offered: Int, floor: Int)
    /// Signature verification failed. The document is quarantined: not served,
    /// not promoted to last-known-good.
    case rejectedIntegrity
    /// Structurally invalid. Also quarantined.
    case rejectedInvalid([DocumentDefect])
    /// Transport failed. The previous document keeps serving.
    case transportFailed(String)
    /// The launch budget elapsed before the fetch completed.
    case budgetExhausted

    public var description: String {
        switch self {
        case .updated(let version): return "updated to v\(version)"
        case .notModified: return "not modified"
        case .rejectedStaleVersion(let offered, let floor):
            return "rejected v\(offered): below accepted floor v\(floor)"
        case .rejectedIntegrity: return "rejected: integrity verification failed"
        case .rejectedInvalid(let defects):
            return "rejected: \(defects.map(\.description).joined(separator: "; "))"
        case .transportFailed(let message): return "transport failed: \(message)"
        case .budgetExhausted: return "launch budget exhausted"
        }
    }

    public var didChangeDocument: Bool {
        if case .updated = self { return true }
        return false
    }
}

public enum ConfigStoreError: Error, Sendable {
    case budgetExhausted
}

/// Counters a golden-signals dashboard actually needs.
public struct StoreDiagnostics: Hashable, Sendable {
    public var acceptedCount = 0
    public var notModifiedCount = 0
    public var staleVersionRejections = 0
    public var integrityRejections = 0
    public var validationRejections = 0
    public var transportFailures = 0
    public var budgetExhaustions = 0
    public init() {}
}

// MARK: - Store

/// Serves configuration with stale-while-revalidate, a monotonic version floor,
/// quarantine on integrity failure, and a hard launch-time budget.
///
/// ## The two consistency answers in one system
///
/// Reading a *stale* "feature is on" is usually fine — that is what
/// stale-while-revalidate is for, and blocking a launch on a config fetch is a
/// far more reliable way to hurt users than a five-minute-old flag value. But
/// reading a stale "feature is on" *after it has been killed* is the one thing
/// this system exists to prevent. So the config path is availability-first and
/// the kill path is correctness-first, and the two are reconciled by the version
/// floor: once this device has accepted version N, no version below N is ever
/// served again, from any source, including its own last-known-good cache. A CDN
/// edge serving a stale object, or a replayed response, cannot resurrect a
/// killed feature.
public actor ConfigStore {

    private let transport: ConfigTransport
    private let verifier: DocumentIntegrityVerifying
    private let lastKnownGood: LastKnownGoodStore
    private let clock: WallClock
    private let bundledFallback: ConfigDocument
    private let acceptance: DocumentAcceptancePolicy

    private var current: ConfigDocument
    private var currentSource: ServingSource
    /// Highest document version ever accepted. Never decreases.
    private var versionFloor: Int
    private var inFlight: Task<RefreshOutcome, Never>?
    private var diagnostics = StoreDiagnostics()

    public init(
        bundledFallback: ConfigDocument,
        transport: ConfigTransport,
        verifier: DocumentIntegrityVerifying = UnverifiedIntegrity(),
        lastKnownGood: LastKnownGoodStore = InMemoryLastKnownGoodStore(),
        clock: WallClock = SystemClock(),
        acceptance: DocumentAcceptancePolicy = MonotonicVersionFloorPolicy()
    ) {
        self.bundledFallback = bundledFallback
        self.transport = transport
        self.verifier = verifier
        self.lastKnownGood = lastKnownGood
        self.clock = clock
        self.acceptance = acceptance
        self.current = bundledFallback
        self.currentSource = .bundledFallback
        self.versionFloor = bundledFallback.documentVersion
    }

    /// Loads last-known-good from disk, if it is not below the floor.
    public func restore() async {
        guard let saved = await lastKnownGood.load() else { return }
        // Re-read actor state after the suspension rather than trusting a value
        // captured before it: a push-triggered refresh may have landed a newer
        // document while this `await` was suspended, and promoting the cached
        // one over it would be a silent downgrade.
        guard saved.documentVersion > versionFloor,
              acceptance.shouldAccept(
                offeredVersion: saved.documentVersion, acceptedFloor: versionFloor) else { return }
        guard DocumentValidator.fatalDefects(in: saved).isEmpty else { return }
        current = saved
        currentSource = .lastKnownGood
        versionFloor = saved.documentVersion
    }

    public func snapshot() -> ConfigSnapshot {
        let age = clock.now.timeIntervalSince(current.issuedAt)
        return ConfigSnapshot(
            document: current,
            source: currentSource,
            freshness: Self.freshness(of: current, age: age),
            age: age)
    }

    public func evaluator(fallback: FallbackCatalog) -> Evaluator {
        Evaluator(document: current, fallback: fallback)
    }

    public func currentDiagnostics() -> StoreDiagnostics { diagnostics }

    public func acceptedVersionFloor() -> Int { versionFloor }

    static func freshness(of document: ConfigDocument, age: TimeInterval) -> Freshness {
        if age <= document.maxAge { return .fresh }
        if age <= document.maxAge + max(document.staleWhileRevalidate, 0) { return .staleServeable }
        return .expired
    }

    // MARK: Refresh

    /// Background refresh. Single-flight: concurrent callers share one request.
    @discardableResult
    public func refresh() async -> RefreshOutcome {
        if let existing = inFlight {
            return await existing.value
        }
        let task = Task<RefreshOutcome, Never> { [knownVersion = current.documentVersion] in
            await self.performRefresh(knownVersion: knownVersion, budget: nil)
        }
        inFlight = task
        let outcome = await task.value
        // Re-read, do not assume: another caller may already have cleared and
        // replaced the slot while this continuation was suspended.
        if inFlight == task { inFlight = nil }
        return outcome
    }

    /// Launch-time blocking fetch with a hard budget.
    ///
    /// The budget is a deadline on the *whole* attempt and it is spent, not
    /// extended. On expiry the in-flight request is genuinely cancelled rather
    /// than left running: a launch fetch that outlives its budget is competing
    /// for the same connection pool as the first screen's own traffic, and one
    /// wasted request costs less than that contention.
    ///
    /// Deliberately does **not** join the single-flight slot. Sharing it would
    /// mean either a background caller inheriting the launch deadline or the
    /// launch inheriting an unbounded one — the deadline has to belong to the
    /// caller that declared it.
    @discardableResult
    public func warmUp(budget: Duration) async -> RefreshOutcome {
        await performRefresh(knownVersion: current.documentVersion, budget: budget)
    }

    private func performRefresh(knownVersion: Int, budget: Duration?) async -> RefreshOutcome {
        let response: TransportResponse
        do {
            if let budget {
                response = try await Self.fetch(
                    from: transport, knownVersion: knownVersion, within: budget)
            } else {
                response = try await transport.fetch(knownVersion: knownVersion)
            }
        } catch is ConfigStoreError {
            diagnostics.budgetExhaustions += 1
            return .budgetExhausted
        } catch {
            diagnostics.transportFailures += 1
            return .transportFailed(String(describing: error))
        }

        guard case .document(let incoming) = response else {
            diagnostics.notModifiedCount += 1
            return .notModified
        }

        // Order matters. Integrity first: a document that fails verification is
        // not evidence of anything, including of its own version number, so it
        // must not be allowed to move the floor or to report defects that a
        // dashboard would then attribute to the real publisher.
        do {
            try verifier.verify(incoming)
        } catch {
            diagnostics.integrityRejections += 1
            return .rejectedIntegrity
        }

        let defects = DocumentValidator.fatalDefects(in: incoming)
        guard defects.isEmpty else {
            diagnostics.validationRejections += 1
            return .rejectedInvalid(defects)
        }

        // `versionFloor` is read here, after every suspension point above, not
        // from a value captured before the fetch.
        guard acceptance.shouldAccept(
            offeredVersion: incoming.documentVersion, acceptedFloor: versionFloor) else {
            diagnostics.staleVersionRejections += 1
            return .rejectedStaleVersion(offered: incoming.documentVersion, floor: versionFloor)
        }

        current = incoming
        currentSource = .network
        versionFloor = incoming.documentVersion
        diagnostics.acceptedCount += 1
        await lastKnownGood.save(incoming)
        return .updated(toVersion: incoming.documentVersion)
    }

    private static func fetch(
        from transport: ConfigTransport,
        knownVersion: Int,
        within budget: Duration
    ) async throws -> TransportResponse {
        try await withThrowingTaskGroup(of: TransportResponse.self) { group in
            group.addTask { try await transport.fetch(knownVersion: knownVersion) }
            group.addTask {
                try await Task.sleep(for: budget)
                throw ConfigStoreError.budgetExhausted
            }
            guard let first = try await group.next() else {
                throw ConfigStoreError.budgetExhausted
            }
            group.cancelAll()
            return first
        }
    }
}
