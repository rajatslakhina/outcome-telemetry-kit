import Foundation
import XCTest
@testable import OutcomeTelemetry

final class CohortTests: XCTestCase {
    func testFNV1aMatchesPublishedVectors() {
        // Reference values from the FNV specification's test suite.
        XCTAssertEqual(CohortAssigner.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(CohortAssigner.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(CohortAssigner.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testAssignmentIsPinnedAcrossProcesses() {
        // Golden buckets, computed once from the FNV-1a specification (in
        // Python, outside this codebase) and frozen here. A per-process-seeded
        // hash such as `Hasher` would still agree with itself inside one test
        // run — which is why the check is against literals, not a second call.
        let assigner = CohortAssigner(treatmentPerMille: 500, salt: "ai-autocategory-2026q4")
        let buckets = (0 ..< 5).map { assigner.bucket(forInstall: "install-\($0)") }
        XCTAssertEqual(buckets, [225, 14, 803, 592, 69])
        XCTAssertEqual((0 ..< 5).map { assigner.arm(forInstall: "install-\($0)") },
                       [.treatment, .treatment, .holdout, .holdout, .treatment])
    }

    func testSplitMatchesTheConfiguredShare() {
        let assigner = CohortAssigner(treatmentPerMille: 300, salt: "s")
        let treated = (0 ..< 20_000).filter { assigner.arm(forInstall: "i\($0)") == .treatment }.count
        XCTAssertEqual(Double(treated) / 20_000, 0.3, accuracy: 0.015)
        XCTAssertTrue((0 ..< 500).allSatisfy { CohortAssigner(treatmentPerMille: 0, salt: "s").arm(forInstall: "i\($0)") == .holdout })
        XCTAssertTrue((0 ..< 500).allSatisfy { CohortAssigner(treatmentPerMille: 5_000, salt: "s").arm(forInstall: "i\($0)") == .treatment })
    }

    func testChangingTheSaltReRandomises() {
        let a = CohortAssigner(treatmentPerMille: 500, salt: "one")
        let b = CohortAssigner(treatmentPerMille: 500, salt: "two")
        let moved = (0 ..< 2_000).filter { a.arm(forInstall: "i\($0)") != b.arm(forInstall: "i\($0)") }.count
        XCTAssertEqual(Double(moved) / 2_000, 0.5, accuracy: 0.05)
    }
}

final class ReportTests: XCTestCase {
    func testWilsonIntervalMatchesReferenceValues() throws {
        let zero = try XCTUnwrap(RateEstimate(successes: 0, trials: 10).wilson95)
        XCTAssertEqual(zero.lowerBound, 0, accuracy: 1e-4)
        XCTAssertEqual(zero.upperBound, 0.2775, accuracy: 1e-4)
        let half = try XCTUnwrap(RateEstimate(successes: 5, trials: 10).wilson95)
        XCTAssertEqual(half.lowerBound, 0.2366, accuracy: 1e-4)
        XCTAssertEqual(half.upperBound, 0.7634, accuracy: 1e-4)
        XCTAssertNil(RateEstimate(successes: 0, trials: 0).wilson95)
        XCTAssertNil(RateEstimate(successes: 0, trials: 0).rate)
        let overfull = try XCTUnwrap(RateEstimate(successes: 12, trials: 10).wilson95)
        XCTAssertLessThanOrEqual(overfull.upperBound, 1)
    }

    func testNewcombeIntervalMatchesThePublishedExample() throws {
        // Newcombe (1998), Table II, example (a): 56/70 vs 48/80 → 0.2000,
        // 95% CI 0.0524 to 0.3339 (method 10).
        let c = OutcomeReport.compare(RateEstimate(successes: 56, trials: 70), RateEstimate(successes: 48, trials: 80), minTrials: 30)
        let interval = try XCTUnwrap(c.interval95)
        XCTAssertEqual(try XCTUnwrap(c.difference), 0.2, accuracy: 1e-9)
        XCTAssertEqual(interval.lowerBound, 0.0524, accuracy: 1e-4)
        XCTAssertEqual(interval.upperBound, 0.3339, accuracy: 1e-4)
        XCTAssertEqual(c.verdict, .treatmentBetter)
    }

    func testDesignEffectWidensTheIntervalWithoutMovingThePointEstimate() throws {
        let t = RateEstimate(successes: 300, trials: 400)
        let h = RateEstimate(successes: 270, trials: 400)
        let independent = OutcomeReport.compare(t, h, minTrials: 30, designEffect: 1)
        let clustered = OutcomeReport.compare(t, h, minTrials: 30, designEffect: 3)
        let narrow = try XCTUnwrap(independent.interval95)
        let wide = try XCTUnwrap(clustered.interval95)
        XCTAssertEqual(independent.difference, clustered.difference)
        XCTAssertLessThan(wide.lowerBound, narrow.lowerBound)
        XCTAssertGreaterThan(wide.upperBound, narrow.upperBound)
        XCTAssertEqual(independent.verdict, .treatmentBetter)
        XCTAssertEqual(clustered.verdict, .inconclusive, "the same gap is not evidence once clustering is priced in")
        // deff below 1, NaN or infinite is treated as 1.
        for bad in [0.2, Double.nan, Double.infinity] {
            XCTAssertEqual(OutcomeReport.compare(t, h, minTrials: 30, designEffect: bad).interval95, narrow)
        }
    }

    func testDesignEffectEstimator() {
        // Every install identical in rate: no clustering, deff ≈ 1.
        let flat = (0 ..< 40).map { InstallOutcome(arm: $0 % 2 == 0 ? .treatment : .holdout, completed: 6, known: 10) }
        XCTAssertEqual(DesignEffect.estimate(flat), 1, accuracy: 1e-9)
        // All-or-nothing installs: ICC = 1, deff = cluster size.
        let extreme = (0 ..< 40).map { InstallOutcome(arm: $0 % 2 == 0 ? .treatment : .holdout, completed: $0 % 4 < 2 ? 10 : 0, known: 10) }
        XCTAssertEqual(DesignEffect.estimate(extreme), 10, accuracy: 1e-6)
        // A difference *between arms* is the treatment effect, not clustering.
        let byArm = (0 ..< 40).map { InstallOutcome(arm: $0 % 2 == 0 ? .treatment : .holdout, completed: $0 % 2 == 0 ? 9 : 5, known: 10) }
        XCTAssertEqual(DesignEffect.estimate(byArm), 1, accuracy: 1e-9)
        XCTAssertEqual(DesignEffect.estimate([]), 1)
        XCTAssertEqual(DesignEffect.estimate([InstallOutcome(arm: .holdout, completed: 5, known: 0)]), 1)
        XCTAssertEqual(InstallOutcome(arm: .holdout, completed: 9, known: 3).completed, 3, "completed is clamped to known")
    }

    func testVerdictsAndTheMinimumSampleGuard() {
        let small = OutcomeReport.compare(RateEstimate(successes: 9, trials: 10), RateEstimate(successes: 1, trials: 10), minTrials: 30)
        XCTAssertEqual(small.verdict, .insufficientData, "a big gap on 10 tasks is not evidence")
        XCTAssertNil(small.interval95)
        XCTAssertEqual(OutcomeReport.compare(RateEstimate(successes: 50, trials: 100), RateEstimate(successes: 52, trials: 100), minTrials: 30).verdict, .inconclusive)
        XCTAssertEqual(OutcomeReport.compare(RateEstimate(successes: 30, trials: 100), RateEstimate(successes: 70, trials: 100), minTrials: 30).verdict, .treatmentWorse)
        XCTAssertEqual(OutcomeReport.compare(RateEstimate(successes: 0, trials: 0), RateEstimate(successes: 0, trials: 0), minTrials: 0).verdict, .insufficientData)
    }

    func testUnknownOutcomesAreExcludedFromTheDenominator() {
        var table = AggregateTable()
        let kind = SampleSchema.captureExpense
        let outcomes: [TaskOutcome] = [.completed, .completed, .abandoned(.userCancelled), .interrupted, .interrupted, .abandoned(.evicted)]
        for (i, outcome) in outcomes.enumerated() {
            table.add(FinishedTask(id: TaskID(UInt64(i)), kind: kind, arm: .holdout, outcome: outcome, exposure: .none,
                                   timeToIntentNanos: outcome == .completed ? nanoseconds(3) : nil,
                                   furthestStep: nil, ai: AICounts(), revisits: 0))
        }
        let report = OutcomeReport(kind: kind, table: table)
        XCTAssertEqual(report.holdout.completion.trials, 3, "interrupted and evicted are unknown, not failures")
        XCTAssertEqual(report.holdout.completion.rate ?? -1, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(report.treatment.completion.trials, 0)
        XCTAssertEqual(report.comparison.verdict, .insufficientData)
    }

    func testCoarsenedRowsCountTowardTheArmButNotTheExposureSplit() {
        var table = AggregateTable()
        var row = OutcomeAggregate()
        row.outcomes.completed = 4
        table.add(row, at: AggregateKey(kind: SampleSchema.captureExpense, arm: .treatment, exposure: nil))
        table.add(row, at: AggregateKey(kind: SampleSchema.captureExpense, arm: .treatment, exposure: .accepted))
        var reduced = OutcomeCounts()
        reduced.completed = 2
        reduced.userCancelled = 7
        let report = OutcomeReport(kind: SampleSchema.captureExpense, table: table,
                                   outcomeOnly: [AggregateKey(kind: SampleSchema.captureExpense, arm: .holdout, exposure: nil): reduced])
        XCTAssertEqual(report.treatment.outcomes.completed, 8)
        XCTAssertEqual(report.exposures.map(\.exposure), [.accepted])
        XCTAssertEqual(report.coarsenedTreatmentTasks, 4)
        XCTAssertEqual(report.outcomeOnlyTasks, 9)
        XCTAssertEqual(report.holdout.completion.trials, 9, "outcome-only counts are in the arm's rate")
        XCTAssertEqual(report.holdout.completion.successes, 2)
        XCTAssertEqual(report.holdout.timeToIntent.total, 0, "…but not in its durations")
    }
}

/// The demo's configuration, in one place, so the README's numbers are pinned.
enum DemoFleet {
    static let installs = 240
    static let tasksPerInstall = 12
    static let seed: UInt64 = 2026
    static let cohorts = CohortAssigner(treatmentPerMille: 500, salt: "ai-autocategory-2026q4")
    static let gate = PrivacyGate(k: 3, maxCarries: 0)

    static func run(gate: PrivacyGate = gate, seed: UInt64 = seed) async -> (FleetResult, OutcomeReport) {
        let collector = InMemoryCollector()
        let result = await FleetSimulator.run(installs: installs, tasksPerInstall: tasksPerInstall, seed: seed,
                                              cohorts: cohorts, gate: gate, collector: collector)
        let table = await collector.table
        let outcomeOnly = await collector.outcomeOnly
        let report = OutcomeReport(kind: SampleSchema.captureExpense, table: table, outcomeOnly: outcomeOnly,
                                   designEffect: result.designEffect)
        return (result, report)
    }
}

final class SimulationTests: XCTestCase {
    func testFleetRunIsDeterministicAndConserved() async {
        let (a, reportA) = await DemoFleet.run()
        let (b, reportB) = await DemoFleet.run()
        XCTAssertEqual(reportA, reportB)
        XCTAssertEqual(a.finishedTasks, b.finishedTasks)
        XCTAssertEqual(a.conservedInstalls, a.installs)
        let collector = InMemoryCollector()
        let c = await FleetSimulator.run(installs: 60, tasksPerInstall: 6, seed: 1, cohorts: DemoFleet.cohorts,
                                         gate: DemoFleet.gate, collector: collector)
        let serverTasks = await collector.taskCount
        XCTAssertEqual(serverTasks, c.finishedTasks, "every simulated task reached the server exactly once")
    }

    func testThePrivacyGateDoesNotMoveTheArmComparison() async throws {
        // The regression that motivated outcome-only rows: with the gate on,
        // the arm comparison must equal the ungated one exactly, on several seeds.
        for seed in DemoFleet.seed ... DemoFleet.seed + 4 {
            let (_, gated) = await DemoFleet.run(seed: seed)
            let (_, open) = await DemoFleet.run(gate: PrivacyGate(k: 1, maxCarries: 0), seed: seed)
            XCTAssertEqual(gated.treatment.completion, open.treatment.completion, "seed \(seed)")
            XCTAssertEqual(gated.holdout.completion, open.holdout.completion, "seed \(seed)")
            XCTAssertEqual(gated.comparison, open.comparison, "seed \(seed)")
            XCTAssertGreaterThan(gated.outcomeOnlyTasks, 0, "seed \(seed): the gate actually reduced rows")
        }
    }

    func testDroppingTheArmOfReducedRowsWouldInflateTheEffect() async throws {
        // Emulates this library's first design (reduced rows lost their arm)
        // by building the report without the outcome-only rows, and pins the
        // inflation range the README quotes.
        var inflations: [Double] = []
        for seed in DemoFleet.seed ... DemoFleet.seed + 4 {
            let collector = InMemoryCollector()
            _ = await FleetSimulator.run(installs: DemoFleet.installs, tasksPerInstall: DemoFleet.tasksPerInstall, seed: seed,
                                        cohorts: DemoFleet.cohorts, gate: DemoFleet.gate, collector: collector)
            let table = await collector.table
            let outcomeOnly = await collector.outcomeOnly
            let current = OutcomeReport(kind: SampleSchema.captureExpense, table: table, outcomeOnly: outcomeOnly)
            let oldDesign = OutcomeReport(kind: SampleSchema.captureExpense, table: table)
            inflations.append(try XCTUnwrap(oldDesign.comparison.difference) - XCTUnwrap(current.comparison.difference))
        }
        XCTAssertTrue(inflations.allSatisfy { $0 > 0 }, "\(inflations)")
        XCTAssertEqual(try XCTUnwrap(inflations.min()), 0.008, accuracy: 0.0015)
        XCTAssertEqual(try XCTUnwrap(inflations.max()), 0.027, accuracy: 0.0015)
    }

    func testReadmeHeadlineNumbers() async throws {
        let (result, report) = await DemoFleet.run()
        XCTAssertEqual(result.finishedTasks, 2_880)
        XCTAssertEqual(result.treatmentInstalls, 125)
        XCTAssertEqual(report.treatment.completion, RateEstimate(successes: Self.pinned.tCompleted, trials: Self.pinned.tKnown))
        XCTAssertEqual(report.holdout.completion, RateEstimate(successes: Self.pinned.hCompleted, trials: Self.pinned.hKnown))
        XCTAssertEqual(result.designEffect, Self.pinned.deff, accuracy: 0.005)
        let interval = try XCTUnwrap(report.comparison.interval95)
        XCTAssertEqual(interval.lowerBound, Self.pinned.low, accuracy: 0.0005)
        XCTAssertEqual(interval.upperBound, Self.pinned.high, accuracy: 0.0005)
        XCTAssertEqual(report.comparison.verdict, Self.pinned.verdict)
        let accepted = try XCTUnwrap(report.exposures.first { $0.exposure == .accepted }?.completion)
        XCTAssertEqual(accepted, RateEstimate(successes: Self.pinned.aCompleted, trials: Self.pinned.aKnown))
    }

    /// The numbers quoted in both READMEs (seed 2026, 240 installs × 12 tasks,
    /// k = 3). If the simulator or the statistics change, this fails first.
    static let pinned = (tCompleted: UInt64(1_164), tKnown: UInt64(1_500), hCompleted: UInt64(993), hKnown: UInt64(1_380),
                         aCompleted: UInt64(561), aKnown: UInt64(603), deff: 1.51, low: 0.0174, high: 0.0954,
                         verdict: ComparisonVerdict.treatmentBetter)

    func testExposureSplitOverstatesTheEffectTheArmsMeasure() async throws {
        // The demo's central claim: "tasks that used the suggestion" look far
        // better than the feature's causal effect, because acceptance is
        // correlated with easy receipts. Measured without the gate so the
        // exposure split covers every task.
        let (_, report) = await DemoFleet.run(gate: PrivacyGate(k: 1, maxCarries: 0))
        let itt = try XCTUnwrap(report.comparison.difference)
        let holdoutRate = try XCTUnwrap(report.holdout.completion.rate)
        let accepted = try XCTUnwrap(report.exposures.first { $0.exposure == .accepted }?.completion.rate)
        XCTAssertGreaterThan(itt, 0, "the feature does help")
        XCTAssertGreaterThan(accepted - holdoutRate, itt * 2, "the confounded comparison more than doubles it")
    }
}
