// Saturating arithmetic used everywhere a counter or a duration is combined.
//
// Telemetry counters are merged across batches, coalesced under back-pressure
// and summed in reports. A trapping `+` in any of those paths would turn a
// long-lived install into a crash on launch, so every combination goes
// through these helpers instead of the raw operators.

extension UInt64 {
    /// `self + other`, clamped at `UInt64.max` instead of trapping.
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }

    /// `self - other`, clamped at zero instead of trapping.
    func saturatingSub(_ other: UInt64) -> UInt64 {
        other >= self ? 0 : self - other
    }

    /// `self * other`, clamped at `UInt64.max` instead of trapping.
    func saturatingMul(_ other: UInt64) -> UInt64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : product
    }
}

extension UInt64 {
    /// Converts a `Double` to `UInt64` without trapping on NaN, infinity,
    /// negatives or values above `UInt64.max`.
    static func clamping(_ value: Double) -> UInt64 {
        guard value.isFinite else { return value.isNaN ? 0 : (value > 0 ? .max : 0) }
        if value <= 0 { return 0 }
        if value >= Double(UInt64.max) { return .max }
        return UInt64(value)
    }

    /// Converts a non-negative `Int` to `UInt64`; negatives become zero.
    static func clamping(_ value: Int) -> UInt64 {
        value <= 0 ? 0 : UInt64(value)
    }
}
