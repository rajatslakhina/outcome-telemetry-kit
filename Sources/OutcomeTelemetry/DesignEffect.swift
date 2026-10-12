// Design effect for per-install randomisation — a server-side estimate.
//
// Arms are assigned per install, so the unit of randomisation is the install,
// not the task. Tasks from the same person are correlated (some people give
// up more easily), and an interval that treats them as independent is too
// narrow. The fix is to estimate the intra-install correlation (ICC) from
// install-level counts and inflate the variance by deff = 1 + (m̄ − 1)·ICC.
//
// This needs install-level data, which the client deliberately never sends
// in identifiable form; a backend computes it from per-install aggregates it
// already holds (or from a dedicated, consented calibration study) and passes
// the result to `OutcomeReport(designEffect:)`.

/// Completed and known-outcome task counts for one install.
public struct InstallOutcome: Hashable, Sendable {
    public let arm: ExperimentArm
    public private(set) var completed: UInt64
    public private(set) var known: UInt64

    public init(arm: ExperimentArm, completed: UInt64, known: UInt64) {
        self.arm = arm
        self.known = known
        self.completed = min(completed, known)
    }

    /// Adds one finished task. Interrupted and evicted outcomes are unknown
    /// and do not count, matching `OutcomeReport`'s denominator.
    mutating func record(_ outcome: TaskOutcome?) {
        switch outcome {
        case .none, .interrupted?, .abandoned(.evicted)?: return
        case .completed?:
            completed = completed.saturatingAdd(1)
            known = known.saturatingAdd(1)
        default:
            known = known.saturatingAdd(1)
        }
    }
}

public enum DesignEffect {
    /// One-way ANOVA estimate of the ICC of a binary outcome, computed within
    /// each arm (so the treatment effect itself is not mistaken for
    /// clustering) and pooled, then `deff = 1 + (m̄ − 1)·ICC`. Returns 1 when
    /// there is not enough data, and never less than 1.
    public static func estimate(_ installs: [InstallOutcome]) -> Double {
        var withinSS = 0.0, betweenSS = 0.0
        var groups = 0, total = 0.0, sumSquares = 0.0
        var betweenDF = 0
        for arm in ExperimentArm.allCases {
            let members = installs.filter { $0.arm == arm && $0.known > 0 }
            guard members.count >= 2 else { continue }
            let n = members.reduce(0.0) { $0 + Double($1.known) }
            let p = members.reduce(0.0) { $0 + Double($1.completed) } / n
            for install in members {
                let ni = Double(install.known)
                let pi = Double(install.completed) / ni
                betweenSS += ni * (pi - p) * (pi - p)
                withinSS += ni * pi * (1 - pi)
                sumSquares += ni * ni
            }
            groups += members.count
            betweenDF += members.count - 1
            total += n
        }
        let withinDF = total - Double(groups)
        guard betweenDF > 0, withinDF > 0, total > 0 else { return 1 }
        let msb = betweenSS / Double(betweenDF)
        let msw = withinSS / withinDF
        let n0 = (total - sumSquares / total) / Double(betweenDF)
        let denominator = msb + (n0 - 1) * msw
        guard denominator > 0, denominator.isFinite else { return 1 }
        let icc = min(max((msb - msw) / denominator, 0), 1)
        let meanClusterSize = total / Double(groups)
        let deff = 1 + (meanClusterSize - 1) * icc
        return deff.isFinite ? max(1, deff) : 1
    }
}
