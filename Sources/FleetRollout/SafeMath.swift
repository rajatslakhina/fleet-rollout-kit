import Foundation

/// Non-trapping integer arithmetic.
///
/// Every arithmetic operation in this package that could trap funnels through
/// here. That is not defensive style for its own sake: a remote-config client
/// evaluates numbers that arrived over the network from a CDN, so `+`, `*`,
/// `/`, `%` and `Int(Double)` are all reachable with attacker- or
/// corruption-influenced operands. A trap in that position is a remotely
/// triggerable crash loop on a fleet that, as of iOS 27, cannot downgrade its
/// way out of it.
public enum SafeMath {

    /// Addition that saturates at `Int.min` / `Int.max` instead of trapping.
    @inlinable
    public static func addingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? Int.max : Int.min
    }

    /// Multiplication that saturates instead of trapping.
    @inlinable
    public static func multiplyingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return product }
        let negative = (lhs < 0) != (rhs < 0)
        return negative ? Int.min : Int.max
    }

    /// Division that returns `nil` rather than trapping.
    ///
    /// Two distinct traps are covered: a zero divisor, and `Int.min / -1`, which
    /// overflows because `-Int.min` is not representable.
    @inlinable
    public static func dividing(_ lhs: Int, by rhs: Int) -> Int? {
        guard rhs != 0 else { return nil }
        let (quotient, overflow) = lhs.dividedReportingOverflow(by: rhs)
        return overflow ? nil : quotient
    }

    /// Remainder that returns `nil` rather than trapping, for the same two cases.
    @inlinable
    public static func remainder(_ lhs: Int, _ rhs: Int) -> Int? {
        guard rhs != 0 else { return nil }
        let (remainder, overflow) = lhs.remainderReportingOverflow(dividingBy: rhs)
        return overflow ? nil : remainder
    }

    /// `Int(_: Double)` traps on NaN, on infinities, and on any value outside
    /// `Int`'s representable range. The bounds are derived from `Int.max` and
    /// `Int.min` rather than from 64-bit literals because `Int` is 32-bit on
    /// watchOS, where a hardcoded `9_223_372_036_854_775_807` is wrong.
    @inlinable
    public static func clampedInt(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        let upper = Double(Int.max)
        let lower = Double(Int.min)
        if value >= upper { return Int.max }
        if value <= lower { return Int.min }
        return Int(value)
    }

    /// Clamps an index into `0..<count`, returning `nil` for an empty collection.
    @inlinable
    public static func clampedIndex(_ index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        if index < 0 { return 0 }
        if index >= count { return count - 1 }
        return index
    }

    /// Percentage of `whole` represented by `part`, defined as `0` when `whole`
    /// is not positive rather than producing NaN or infinity.
    @inlinable
    public static func percentage(_ part: Int, of whole: Int) -> Double {
        guard whole > 0 else { return 0 }
        return (Double(part) / Double(whole)) * 100
    }
}
