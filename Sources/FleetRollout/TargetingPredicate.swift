import Foundation

/// The targeting language.
///
/// Two deliberate omissions define it:
///
/// 1. **There is no ordering operator over build trains.** `onTrain` takes a
///    set. You cannot write `osVersion >= 27.1`, because on a forked release
///    graph that expression is not merely imprecise, it is wrong: it matches
///    27.2 devices that never ran 27.1. Making the wrong thing inexpressible is
///    cheaper than reviewing for it on every flag, forever.
/// 2. **There is no arbitrary expression evaluation.** The language is a closed
///    enum with a bounded depth, so a corrupt or hostile document cannot make
///    the client do unbounded work or blow its stack.
public indirect enum TargetingPredicate: Hashable, Sendable, Codable {
    case always
    case never
    /// Matches if the device's build train identifier is in the set.
    case onTrain(Set<String>)
    /// Matches if the device's train lineage is in the set. Useful for "anything
    /// device-exclusive" without enumerating trains that do not exist yet.
    case onLineage(Set<BuildTrain.Lineage>)
    case deviceClass(Set<DeviceClass>)
    case posture(PostureCapability)
    case appBuildAtLeast(Int)
    case appBuildAtMost(Int)
    case attribute(key: String, anyOf: Set<String>)
    case all([TargetingPredicate])
    case any([TargetingPredicate])
    case not(TargetingPredicate)
}

extension TargetingPredicate {
    /// Maximum nesting depth accepted from a document.
    ///
    /// Evaluation is recursive, and the document is remote input. 32 is far
    /// beyond any hand-written rule and far below a stack-exhausting depth.
    public static let maximumDepth = 32

    /// Structural depth, saturating at `maximumDepth + 1`.
    ///
    /// Computed with an explicit stack rather than by recursion. The recursive
    /// version is the obvious one and it is wrong here for the same reason the
    /// evaluator is depth-bounded: the input is a remote document, and a
    /// recursive `depth()` blows the stack on exactly the pathological input it
    /// was added to detect — it has to walk all the way down before it can
    /// discover that it went too far.
    ///
    /// The outer defence is still the decoder: `JSONDecoder` imposes its own
    /// nesting limit long before a document reaches this code. This is the
    /// second one, for documents that arrive by any other route.
    public func depth() -> Int {
        let ceiling = SafeMath.addingSaturating(Self.maximumDepth, 1)
        var deepest = 0
        var stack: [(node: TargetingPredicate, depth: Int)] = [(self, 1)]

        while let entry = stack.popLast() {
            deepest = max(deepest, entry.depth)
            if deepest >= ceiling { return ceiling }
            let childDepth = SafeMath.addingSaturating(entry.depth, 1)
            switch entry.node {
            case .all(let children), .any(let children):
                for child in children { stack.append((child, childDepth)) }
            case .not(let child):
                stack.append((child, childDepth))
            default:
                continue
            }
        }
        return deepest
    }
}

/// Outcome of matching a predicate against a device.
public enum PredicateMatch: Hashable, Sendable {
    case matched
    case notMatched
    /// The predicate exceeded `TargetingPredicate.maximumDepth`. Treated as a
    /// distinct outcome rather than as `notMatched`, because "we refused to
    /// evaluate this" and "this device is not in the audience" are different
    /// facts and only one of them should page someone.
    case refusedDepthExceeded

    public var isMatch: Bool { self == .matched }
}

extension TargetingPredicate {

    /// Evaluates the predicate. Pure: no I/O, no clock, no device access.
    public func matches(_ context: DeviceContext) -> PredicateMatch {
        evaluate(context, depth: 0)
    }

    private func evaluate(_ context: DeviceContext, depth: Int) -> PredicateMatch {
        guard depth < Self.maximumDepth else { return .refusedDepthExceeded }
        let next = SafeMath.addingSaturating(depth, 1)

        switch self {
        case .always:
            return .matched
        case .never:
            return .notMatched
        case .onTrain(let identifiers):
            return identifiers.contains(context.buildTrain.identifier) ? .matched : .notMatched
        case .onLineage(let lineages):
            return lineages.contains(context.buildTrain.lineage) ? .matched : .notMatched
        case .deviceClass(let classes):
            return classes.contains(context.deviceClass) ? .matched : .notMatched
        case .posture(let posture):
            return context.posture == posture ? .matched : .notMatched
        case .appBuildAtLeast(let minimum):
            return context.appBuild >= minimum ? .matched : .notMatched
        case .appBuildAtMost(let maximum):
            return context.appBuild <= maximum ? .matched : .notMatched
        case .attribute(let key, let allowed):
            guard let value = context.attributes[key] else { return .notMatched }
            return allowed.contains(value) ? .matched : .notMatched

        case .all(let children):
            // An empty `all` is vacuously true, matching boolean algebra. It is
            // also the shape a mis-serialised rule takes, so `DocumentValidator`
            // rejects empty groups outright rather than letting one become an
            // accidental 100% rollout.
            for child in children {
                let result = child.evaluate(context, depth: next)
                if result != .matched { return result }
            }
            return .matched

        case .any(let children):
            var sawRefusal = false
            for child in children {
                switch child.evaluate(context, depth: next) {
                case .matched: return .matched
                case .refusedDepthExceeded: sawRefusal = true
                case .notMatched: continue
                }
            }
            // A refusal anywhere in a disjunction means the answer is unknown,
            // not false: one of the branches we declined to evaluate may have
            // matched.
            return sawRefusal ? .refusedDepthExceeded : .notMatched

        case .not(let child):
            switch child.evaluate(context, depth: next) {
            case .matched: return .notMatched
            case .notMatched: return .matched
            // Negating "unknown" is still "unknown". Returning `.matched` here
            // would turn a document we refused to parse into a rollout.
            case .refusedDepthExceeded: return .refusedDepthExceeded
            }
        }
    }
}
