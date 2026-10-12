// OutcomeReport — the metric definition, written down as code.
//
// "Completion rate" sounds obvious until you have to pick a denominator.
// Here it is: completed / (tasks whose outcome is known). Interrupted tasks
// (clock discontinuity) and evicted tasks (tracker overflow) are *unknown*,
// not failures, so they are excluded from the denominator and reported
// separately. Getting that wrong biases the rate against whichever arm
// relaunches more — which, for an AI feature that loads a model, is the
// treatment arm.
//
// The headline comparison is treatment vs holdout (intention-to-treat), with
// a 95% interval on the difference in completion rate (Newcombe's method
// built from Wilson score intervals, which behaves at small n and at rates
// near 0 or 1 where the textbook Wald interval does not). The exposure split
// is shown for the treatment arm only and labelled descriptive: it is
// confounded by who chooses to use the suggestion.

import Foundation

public struct RateEstimate: Hashable, Sendable {
    public let successes: UInt64
    public let trials: UInt64

    /// nil when there are no trials.
    public var rate: Double? { trials == 0 ? nil : Double(successes) / Double(trials) }

    /// 95% Wilson score interval, or nil with no trials.
    public var wilson95: ClosedRange<Double>? { wilson95(designEffect: 1) }

    /// 95% Wilson interval with the sample size deflated by a design effect.
    ///
    /// Arms are randomised per **install**, but each install contributes many
    /// tasks, and tasks from one person are correlated. Treating them as
    /// independent makes the interval too narrow. The standard correction is
    /// an effective sample size `n / deff`, with `deff = 1 + (m − 1)·ICC` for
    /// m tasks per install and intra-install correlation ICC. `deff` must be
    /// estimated from install-level data on the server; 1 means "tasks are
    /// independent", which is only true when installs do not differ.
    public func wilson95(designEffect: Double) -> ClosedRange<Double>? {
        guard trials > 0 else { return nil }
        let deff = designEffect.isFinite ? max(1, designEffect) : 1
        let n = max(Double(trials) / deff, 1)
        // The proportion uses the real counts; only its variance uses n_eff.
        let p = Double(min(successes, trials)) / Double(trials)
        let z = 1.959_963_984_540_054
        let z2 = z * z
        let denominator = 1 + z2 / n
        let centre = (p + z2 / (2 * n)) / denominator
        let half = z * (p * (1 - p) / n + z2 / (4 * n * n)).squareRoot() / denominator
        let lower = max(0, centre - half)
        let upper = min(1, centre + half)
        return lower ... max(lower, upper)
    }
}

public struct ArmSummary: Hashable, Sendable {
    public let arm: ExperimentArm
    public let outcomes: OutcomeCounts
    public let timeToIntent: DurationHistogram
    public let ai: AICounts

    /// Tasks whose outcome is known (excludes interrupted and evicted).
    public var knownOutcomeTasks: UInt64 {
        outcomes.total.saturatingSub(outcomes.interrupted).saturatingSub(outcomes.evicted)
    }

    public var completion: RateEstimate {
        RateEstimate(successes: outcomes.completed, trials: knownOutcomeTasks)
    }

    public var medianTimeToIntent: QuantileBound? { timeToIntent.quantileUpperBoundMillis(0.5) }
    public var p90TimeToIntent: QuantileBound? { timeToIntent.quantileUpperBoundMillis(0.9) }

    /// Share of shown suggestions that were used (accepted or edited).
    public var suggestionUseRate: RateEstimate {
        RateEstimate(successes: min(ai.accepted.saturatingAdd(ai.edited), ai.shown), trials: ai.shown)
    }
}

public enum ComparisonVerdict: String, Hashable, Sendable {
    /// One arm has fewer known-outcome tasks than the report's minimum.
    case insufficientData
    /// The 95% interval of (treatment − holdout) is entirely above zero.
    case treatmentBetter
    /// The interval is entirely below zero.
    case treatmentWorse
    /// The interval contains zero.
    case inconclusive
}

public struct ArmComparison: Hashable, Sendable {
    /// Treatment completion rate minus holdout completion rate.
    public let difference: Double?
    public let interval95: ClosedRange<Double>?
    public let verdict: ComparisonVerdict
}

public struct ExposureSummary: Hashable, Sendable {
    public let exposure: AIExposure
    public let outcomes: OutcomeCounts
    public let timeToIntent: DurationHistogram

    public var completion: RateEstimate {
        let known = outcomes.total.saturatingSub(outcomes.interrupted).saturatingSub(outcomes.evicted)
        return RateEstimate(successes: outcomes.completed, trials: known)
    }
}

public struct OutcomeReport: Hashable, Sendable {
    public let kind: TelemetryName
    public let treatment: ArmSummary
    public let holdout: ArmSummary
    public let comparison: ArmComparison
    /// Treatment-arm rows split by exposure. Descriptive only (confounded).
    /// Rows the privacy gate coarsened (exposure = nil) are not in here; their
    /// count is `coarsenedTreatmentTasks`.
    public let exposures: [ExposureSummary]
    public let coarsenedTreatmentTasks: UInt64
    /// Tasks of this kind the privacy gate reduced to outcome counts. They are
    /// in the arm completion rates; they are not in the durations or the
    /// exposure split.
    public let outcomeOnlyTasks: UInt64
    /// The design effect the intervals were computed with (≥ 1).
    public let designEffect: Double
    /// Funnel drop-off for tasks that did not complete, both arms, by step index.
    public let dropOff: [UInt64]
    public let noStepReached: UInt64

    /// Builds the report for `kind`.
    ///
    /// - Parameters:
    ///   - table: detail rows received by the server.
    ///   - outcomeOnly: outcome counts of rows the privacy gate reduced. They
    ///     count toward each arm's completion rate (dropping them would bias
    ///     the comparison) but carry no durations or exposure.
    ///   - minTasksPerArm: below it the verdict is `.insufficientData`.
    ///   - designEffect: variance inflation for per-install randomisation
    ///     (see `RateEstimate.wilson95(designEffect:)`).
    public init(
        kind: TelemetryName,
        table: AggregateTable,
        outcomeOnly: [AggregateKey: OutcomeCounts] = [:],
        minTasksPerArm: UInt64 = 30,
        designEffect: Double = 1
    ) {
        var byArm: [ExperimentArm: OutcomeAggregate] = [:]
        var byExposure: [AIExposure: OutcomeAggregate] = [:]
        var coarsened: UInt64 = 0
        var allArms = OutcomeAggregate()
        for (key, row) in table.rows where key.kind == kind {
            byArm[key.arm, default: OutcomeAggregate()].merge(row)
            allArms.merge(row)
            if key.arm == .treatment {
                if let exposure = key.exposure {
                    byExposure[exposure, default: OutcomeAggregate()].merge(row)
                } else {
                    coarsened = coarsened.saturatingAdd(row.taskCount)
                }
            }
        }
        var countsOnly: [ExperimentArm: OutcomeCounts] = [:]
        var reduced: UInt64 = 0
        for (key, counts) in outcomeOnly where key.kind == kind {
            countsOnly[key.arm, default: OutcomeCounts()].merge(counts)
            reduced = reduced.saturatingAdd(counts.total)
        }
        func summary(_ arm: ExperimentArm) -> ArmSummary {
            let row = byArm[arm] ?? OutcomeAggregate()
            var outcomes = row.outcomes
            outcomes.merge(countsOnly[arm] ?? OutcomeCounts())
            return ArmSummary(arm: arm, outcomes: outcomes, timeToIntent: row.timeToIntent, ai: row.ai)
        }
        self.kind = kind
        treatment = summary(.treatment)
        holdout = summary(.holdout)
        comparison = Self.compare(treatment.completion, holdout.completion, minTrials: max(1, minTasksPerArm), designEffect: designEffect)
        exposures = AIExposure.allCases.compactMap { exposure in
            byExposure[exposure].map { ExposureSummary(exposure: exposure, outcomes: $0.outcomes, timeToIntent: $0.timeToIntent) }
        }
        coarsenedTreatmentTasks = coarsened
        outcomeOnlyTasks = reduced
        self.designEffect = designEffect.isFinite ? max(1, designEffect) : 1
        dropOff = allArms.dropOff
        noStepReached = allArms.noStepReached
    }

    /// Newcombe (1998) method 10: difference of two proportions with an
    /// interval built from each arm's Wilson interval.
    static func compare(_ t: RateEstimate, _ h: RateEstimate, minTrials: UInt64, designEffect: Double = 1) -> ArmComparison {
        guard t.trials >= minTrials, h.trials >= minTrials,
              let p1 = t.rate, let p2 = h.rate,
              let w1 = t.wilson95(designEffect: designEffect), let w2 = h.wilson95(designEffect: designEffect)
        else {
            let difference: Double? = {
                guard let p1 = t.rate, let p2 = h.rate else { return nil }
                return p1 - p2
            }()
            return ArmComparison(difference: difference, interval95: nil, verdict: .insufficientData)
        }
        let d = p1 - p2
        let lower = d - ((p1 - w1.lowerBound) * (p1 - w1.lowerBound) + (w2.upperBound - p2) * (w2.upperBound - p2)).squareRoot()
        let upper = d + ((w1.upperBound - p1) * (w1.upperBound - p1) + (p2 - w2.lowerBound) * (p2 - w2.lowerBound)).squareRoot()
        let interval = max(-1, lower) ... max(max(-1, lower), min(1, upper))
        let verdict: ComparisonVerdict
        if interval.lowerBound > 0 {
            verdict = .treatmentBetter
        } else if interval.upperBound < 0 {
            verdict = .treatmentWorse
        } else {
            verdict = .inconclusive
        }
        return ArmComparison(difference: d, interval95: interval, verdict: verdict)
    }
}
