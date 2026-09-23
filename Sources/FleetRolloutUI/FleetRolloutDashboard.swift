#if canImport(SwiftUI)
import SwiftUI
import FleetRollout

/// Live state behind the dashboard.
///
/// Every number this object publishes is produced by the *real* evaluator and
/// the *real* simulator — nothing here is a mock or a canned figure. Moving the
/// ramp slider re-runs a whole synthetic fleet through `Evaluator.evaluate` on
/// each change, which is the point: a rollout dashboard that shows you a
/// projection computed by different code than production is a dashboard that
/// lies exactly when it matters.
@MainActor
public final class FleetRolloutViewModel: ObservableObject {

    public let baseDocument: ConfigDocument
    public let fallback: FallbackCatalog
    public let fleet: [DeviceContext]

    /// Ramp width, in basis points of the 10,000-point bucket space.
    @Published public var rampBasisPoints: Int {
        didSet { recompute() }
    }
    @Published public var killed: Bool = false {
        didSet { recompute() }
    }
    /// When false, silent push and background refresh are assumed not to fire.
    @Published public var trustBestEffortChannels: Bool = true {
        didSet { recomputePropagation() }
    }
    @Published public var inspectedDeviceIndex: Int = 0 {
        didSet { recompute() }
    }

    @Published public private(set) var document: ConfigDocument
    @Published public private(set) var assignments: [Assignment] = []
    @Published public private(set) var histogram: ExposureHistogram?
    @Published public private(set) var propagation: PropagationReport?
    @Published public private(set) var defects: [DocumentDefect] = []

    public let primaryFlagKey: String
    public let treatedVariantKeys: Set<String>

    public init(
        document: ConfigDocument,
        fallback: FallbackCatalog,
        primaryFlagKey: String,
        treatedVariantKeys: Set<String>,
        fleetSize: Int = 2_000
    ) {
        self.baseDocument = document
        self.document = document
        self.fallback = fallback
        self.primaryFlagKey = primaryFlagKey
        self.treatedVariantKeys = treatedVariantKeys
        self.fleet = FleetSimulator.makeFleet(size: max(1, fleetSize))
        let initialRamp = document.flags
            .first { $0.key == primaryFlagKey }?
            .rules.first?.bucketRange.upperBasisPoints ?? 1_000
        self.rampBasisPoints = initialRamp
        recompute()
    }

    public var inspectedDevice: DeviceContext? {
        guard let index = SafeMath.clampedIndex(inspectedDeviceIndex, count: fleet.count) else {
            return nil
        }
        return fleet[index]
    }

    public var rampPercent: Double { Double(rampBasisPoints) / 100 }

    public func recompute() {
        var updated = baseDocument.updatingFlag(
            primaryFlagKey,
            bumpingVersionTo: SafeMath.addingSaturating(baseDocument.documentVersion, 1)
        ) { $0.ramped(toBasisPoints: rampBasisPoints) }

        if killed {
            updated = updated.killingAll(
                bumpingVersionTo: SafeMath.addingSaturating(updated.documentVersion, 1))
        }
        document = updated
        defects = DocumentValidator.defects(in: updated)

        let evaluator = Evaluator(document: updated, fallback: fallback)
        if let device = inspectedDevice {
            assignments = evaluator.evaluateAll(for: device)
        } else {
            assignments = []
        }
        histogram = FleetSimulator.exposure(
            of: primaryFlagKey,
            evaluator: evaluator,
            fleet: fleet,
            treatedVariantKeys: treatedVariantKeys)
        recomputePropagation()
    }

    public func recomputePropagation() {
        let channels: Set<PropagationChannel> = trustBestEffortChannels
            ? Set(PropagationChannel.allCases)
            : Set(PropagationChannel.allCases.filter(\.isGuaranteed))
        propagation = PropagationSimulator.timeToKill(
            fleetSize: fleet.count,
            channels: channels)
    }

    public func stepInspectedDevice(by delta: Int) {
        guard !fleet.isEmpty else { return }
        let next = SafeMath.addingSaturating(inspectedDeviceIndex, delta)
        inspectedDeviceIndex = SafeMath.clampedIndex(next, count: fleet.count) ?? 0
    }
}

/// The dashboard.
public struct FleetRolloutDashboard: View {

    @StateObject private var model: FleetRolloutViewModel

    public init(
        document: ConfigDocument,
        fallback: FallbackCatalog,
        primaryFlagKey: String,
        treatedVariantKeys: Set<String>,
        fleetSize: Int = 2_000
    ) {
        _model = StateObject(wrappedValue: FleetRolloutViewModel(
            document: document,
            fallback: fallback,
            primaryFlagKey: primaryFlagKey,
            treatedVariantKeys: treatedVariantKeys,
            fleetSize: fleetSize))
    }

    public var body: some View {
        NavigationStack {
            List {
                rampSection
                exposureSection
                inspectorSection
                propagationSection
                integritySection
            }
            .navigationTitle("Fleet Rollout")
        }
    }

    // MARK: Ramp

    private var rampSection: some View {
        Section {
            HStack {
                Text("Ramp")
                Spacer()
                Text(String(format: "%.2f%%", model.rampPercent))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.killed ? .secondary : .primary)
            }
            Slider(
                value: Binding(
                    get: { Double(model.rampBasisPoints) },
                    set: { model.rampBasisPoints = SafeMath.clampedInt($0.rounded()) }),
                in: 0...Double(StableBucketer.bucketSpace),
                step: 25)
            .disabled(model.killed)

            Toggle("Kill switch engaged", isOn: Binding(
                get: { model.killed },
                set: { model.killed = $0 }))
            .tint(.red)
        } header: {
            Text("Rollout — \(model.primaryFlagKey)")
        } footer: {
            Text(model.killed
                 ? "Killed. Every flag resolves to the app's compiled-in fallback, "
                     + "ignoring every rule and every bucket."
                 : "Ramping changes the bucket width only. The salt never changes, "
                     + "so a device already in the treatment never falls out of it as the ramp grows.")
        }
    }

    // MARK: Exposure

    private var exposureSection: some View {
        Section("Fleet exposure — \(model.fleet.count) simulated devices") {
            if let histogram = model.histogram {
                ForEach(histogram.byVariant.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    ShareRow(
                        label: entry.key,
                        count: entry.value,
                        total: histogram.fleetSize,
                        tint: model.treatedVariantKeys.contains(entry.key) ? .green : .gray)
                }
                if !histogram.treatedByTrain.isEmpty {
                    DisclosureGroup("Treated devices by OS train") {
                        ForEach(histogram.treatedByTrain.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                            LabeledContent(entry.key, value: "\(entry.value)")
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
                DisclosureGroup("Evaluation reasons") {
                    ForEach(histogram.byReason.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { entry in
                        LabeledContent(entry.key.rawValue, value: "\(entry.value)")
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            } else {
                Text("No fleet").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Inspector

    private var inspectorSection: some View {
        Section {
            if let device = model.inspectedDevice {
                LabeledContent("Identifier", value: device.stableIdentifier)
                LabeledContent("OS train", value: device.buildTrain.identifier)
                LabeledContent("Lineage", value: device.buildTrain.lineage.rawValue)
                LabeledContent("Device class", value: device.deviceClass.rawValue)
                LabeledContent("App build", value: "\(device.appBuild)")
                Stepper("Inspect another device",
                        onIncrement: { model.stepInspectedDevice(by: 1) },
                        onDecrement: { model.stepInspectedDevice(by: -1) })

                ForEach(model.assignments, id: \.flagKey) { assignment in
                    AssignmentRow(assignment: assignment)
                }
            } else {
                Text("No device selected").foregroundStyle(.secondary)
            }
        } header: {
            Text("Why this device got this value")
        } footer: {
            Text("Every assignment carries its reason, its bucket and the rule id that served it. "
                 + "\"What is the value\" is never the question during an incident; "
                 + "\"why did this device get it\" is.")
        }
    }

    // MARK: Propagation

    private var propagationSection: some View {
        Section {
            Toggle("Trust silent push and background refresh", isOn: Binding(
                get: { model.trustBestEffortChannels },
                set: { model.trustBestEffortChannels = $0 }))

            if let report = model.propagation {
                LabeledContent("p50", value: Self.duration(report.p50))
                LabeledContent("p95", value: Self.duration(report.p95))
                LabeledContent("p99", value: Self.duration(report.p99))
                LabeledContent("Coverage in 1h",
                               value: String(format: "%.1f%%", report.coverage * 100))
                LabeledContent("Never reached", value: "\(report.unreachedCount)")
                let slo = PropagationSLO.standard
                Label(
                    report.meets(slo) ? "Meets 95% / 15 min SLO" : "Misses 95% / 15 min SLO",
                    systemImage: report.meets(slo) ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(report.meets(slo) ? .green : .orange)
            }
        } header: {
            Text("Time to kill")
        } footer: {
            Text("Silent push and background refresh are best-effort by Apple's own documentation. "
                 + "Turn them off above to see the floor the kill switch actually guarantees.")
        }
    }

    private var integritySection: some View {
        Section("Document") {
            LabeledContent("Version", value: "\(model.document.documentVersion)")
            LabeledContent("Schema", value: "\(model.document.schemaVersion)")
            LabeledContent("Signing key", value: model.document.integrity.keyIdentifier)
            if model.defects.isEmpty {
                Label("No structural defects", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                ForEach(model.defects.map(\.description), id: \.self) { defect in
                    Label(defect, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        return String(format: "%.1fm", seconds / 60)
    }
}

struct ShareRow: View {
    let label: String
    let count: Int
    let total: Int
    let tint: Color

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(count) / Double(total), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(.body, design: .monospaced))
                Spacer()
                Text(String(format: "%@  %.2f%%", "\(count)", fraction * 100))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(tint)
        }
        .padding(.vertical, 2)
    }
}

struct AssignmentRow: View {
    let assignment: Assignment

    var tint: Color {
        switch assignment.reason {
        case .ruleMatch: return .green
        case .defaultVariant: return .secondary
        case .killed: return .red
        case .unknownFlag, .noDocument: return .orange
        case .refusedMalformedRule: return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(assignment.flagKey).font(.system(.footnote, design: .monospaced))
                Spacer()
                Text(assignment.variantKey)
                    .font(.system(.footnote, design: .monospaced).bold())
            }
            HStack(spacing: 8) {
                Text(assignment.reason.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: Capsule())
                    .foregroundStyle(tint)
                if let bucket = assignment.bucket {
                    Text("bucket \(bucket)").font(.caption2).foregroundStyle(.secondary)
                }
                if let rule = assignment.matchedRuleID {
                    Text("rule \(rule)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
