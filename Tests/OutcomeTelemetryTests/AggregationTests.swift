import Foundation
import XCTest
@testable import OutcomeTelemetry

/// Random finished tasks for property tests.
enum Fixtures {
    static let kinds = ["capture-expense", "pay-bill", "search"].compactMap(TelemetryName.init)

    static func task(_ rng: inout SplitMix64, id: UInt64) -> FinishedTask {
        let outcomes: [TaskOutcome] = [.completed, .completed, .timedOut, .interrupted,
                                       .abandoned(.userCancelled), .abandoned(.leftApp), .abandoned(.failed), .abandoned(.evicted)]
        let outcome = outcomes[Int(rng.next() % UInt64(outcomes.count))]
        let exposure = AIExposure.allCases[Int(rng.next() % UInt64(AIExposure.allCases.count))]
        var ai = AICounts()
        for _ in 0 ..< Int(rng.next() % 3) { ai.add(AIEvent.allCases[Int(rng.next() % 4)]) }
        let completed = outcome == .completed
        return FinishedTask(
            id: TaskID(id),
            kind: kinds[Int(rng.next() % UInt64(kinds.count))],
            arm: rng.chance(0.5) ? .treatment : .holdout,
            outcome: outcome,
            exposure: exposure,
            timeToIntentNanos: completed ? rng.next() % nanoseconds(400) : nil,
            furthestStep: rng.chance(0.2) ? nil : Int(rng.next() % 4),
            ai: ai,
            revisits: rng.next() % 3
        )
    }

    static func table(_ rng: inout SplitMix64, tasks: Int) -> AggregateTable {
        var table = AggregateTable()
        for i in 0 ..< tasks { table.add(task(&rng, id: UInt64(i))) }
        return table
    }
}

/// Checks the commutative-monoid laws the journal's coalescing relies on.
/// Returns the first law that failed, or nil. Used against the real merge
/// *and* against a deliberately broken one, so the check itself is tested.
func firstMonoidViolation(
    merge: (AggregateTable, AggregateTable) -> AggregateTable,
    seed: UInt64
) -> String? {
    var rng = SplitMix64(seed: seed)
    for round in 0 ..< 60 {
        let a = Fixtures.table(&rng, tasks: Int(rng.next() % 12))
        let b = Fixtures.table(&rng, tasks: Int(rng.next() % 12))
        let c = Fixtures.table(&rng, tasks: Int(rng.next() % 12))
        if merge(a, b) != merge(b, a) { return "commutativity (round \(round))" }
        if merge(merge(a, b), c) != merge(a, merge(b, c)) { return "associativity (round \(round))" }
        if merge(a, AggregateTable()) != a { return "identity (round \(round))" }
        if merge(a, b).taskCount != a.taskCount.saturatingAdd(b.taskCount) { return "task conservation (round \(round))" }
    }
    return nil
}

final class AggregationTests: XCTestCase {
    func testHistogramBucketBoundaries() {
        XCTAssertEqual(DurationHistogram.bucket(forNanos: 0), 0)
        XCTAssertEqual(DurationHistogram.bucket(forNanos: 249_999_999), 0)
        XCTAssertEqual(DurationHistogram.bucket(forNanos: 250_000_000), 1)
        XCTAssertEqual(DurationHistogram.bucket(forNanos: 255_999_999_999), 10)
        XCTAssertEqual(DurationHistogram.bucket(forNanos: 256_000_000_000), 11)
        XCTAssertEqual(DurationHistogram.bucket(forNanos: .max), 11)
        XCTAssertEqual(DurationHistogram.bucketCount, 12)
    }

    func testQuantilesReportBucketBoundsNotInventedPrecision() {
        var h = DurationHistogram()
        XCTAssertNil(h.quantileUpperBoundMillis(0.5), "empty histogram has no median")
        for seconds in [0.1, 1.5, 1.6, 3.0, 300.0] { h.add(nanos: nanoseconds(seconds)) }
        XCTAssertEqual(h.quantileUpperBoundMillis(0.5), .atMost(2_000))
        XCTAssertEqual(h.quantileUpperBoundMillis(0), .atMost(250))
        XCTAssertEqual(h.quantileUpperBoundMillis(1), .above(256_000))
        XCTAssertEqual(h.quantileUpperBoundMillis(.nan), nil)
        XCTAssertEqual(h.quantileUpperBoundMillis(7), .above(256_000), "q is clamped to 1")
        XCTAssertEqual(QuantileBound.atMost(500).label, "≤ 500 ms")
        XCTAssertEqual(QuantileBound.above(256_000).label, "> 256 s")
    }

    func testAggregateMergeIsACommutativeMonoid() {
        XCTAssertNil(firstMonoidViolation(merge: { var x = $0; x.merge($1); return x }, seed: 1))
    }

    func testTheMonoidCheckRejectsABrokenMerge() {
        // "Last writer wins" per row — a plausible-looking bug that would make
        // coalescing under back-pressure silently lose tasks.
        let lastWriterWins: (AggregateTable, AggregateTable) -> AggregateTable = { a, b in
            var out = AggregateTable()
            for (key, row) in a.rows { out.add(row, at: key) }
            for (key, row) in b.rows where a.rows[key] == nil { out.add(row, at: key) }
            return out
        }
        XCTAssertNotNil(firstMonoidViolation(merge: lastWriterWins, seed: 1))
    }

    func testAggregateTableRoundTripsThroughJSON() throws {
        var rng = SplitMix64(seed: 3)
        let table = Fixtures.table(&rng, tasks: 40)
        let decoded = try JSONDecoder().decode(AggregateTable.self, from: JSONEncoder().encode(table))
        XCTAssertEqual(decoded, table)
    }

    func testDecodingRejectsWrongShapes() {
        XCTAssertThrowsError(try JSONDecoder().decode(DurationHistogram.self, from: Data("[1,2,3]".utf8)))
        var row = OutcomeAggregate()
        row.noStepReached = 1
        let good = (try? JSONEncoder().encode(row)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let bad = good.replacingOccurrences(of: "\"dropOff\":[0,0,0,0,0,0,0,0,0,0,0,0]", with: "\"dropOff\":[0]")
        XCTAssertNotEqual(good, bad, "fixture must actually change the shape")
        XCTAssertThrowsError(try JSONDecoder().decode(OutcomeAggregate.self, from: Data(bad.utf8)))
    }

    func testDropOffAndRevisitsAccumulate() throws {
        var row = OutcomeAggregate()
        let kind = SampleSchema.captureExpense
        func t(_ outcome: TaskOutcome, step: Int?) -> FinishedTask {
            FinishedTask(id: TaskID(1), kind: kind, arm: .holdout, outcome: outcome, exposure: .none,
                         timeToIntentNanos: outcome == .completed ? nanoseconds(3) : nil,
                         furthestStep: step, ai: AICounts(), revisits: 2)
        }
        row.add(t(.abandoned(.userCancelled), step: 2))
        row.add(t(.timedOut, step: nil))
        row.add(t(.completed, step: 3))
        row.add(t(.abandoned(.failed), step: 99)) // out of range: counted, never indexed
        XCTAssertEqual(row.dropOff[2], 1)
        XCTAssertEqual(row.noStepReached, 2)
        XCTAssertEqual(row.timeToIntent.total, 1)
        XCTAssertEqual(row.revisits, 8)
        XCTAssertEqual(row.taskCount, 4)
    }
}

final class PrivacyGateTests: XCTestCase {
    /// Per-arm outcome counts across every place a task can be after the gate.
    static func armOutcomes(_ out: PrivacyGate.Output) -> [ExperimentArm: OutcomeCounts] {
        var result: [ExperimentArm: OutcomeCounts] = [:]
        for (key, row) in out.published.rows { result[key.arm, default: OutcomeCounts()].merge(row.outcomes) }
        for (key, row) in out.carried { result[key.arm, default: OutcomeCounts()].merge(row.aggregate.outcomes) }
        for (key, counts) in out.outcomeOnly { result[key.arm, default: OutcomeCounts()].merge(counts) }
        return result
    }

    /// Checks the gate's three promises over random inputs: task
    /// conservation, per-arm outcome conservation (so the causal comparison
    /// is unbiased), and no published detail row under k.
    func firstGateViolation(_ apply: (AggregateTable, [AggregateKey: PrivacyGate.Carried]) -> PrivacyGate.Output, k: UInt64, seed: UInt64) -> String? {
        var rng = SplitMix64(seed: seed)
        var carried: [AggregateKey: PrivacyGate.Carried] = [:]
        for round in 0 ..< 80 {
            let fresh = Fixtures.table(&rng, tasks: Int(rng.next() % 25))
            var expected: [ExperimentArm: OutcomeCounts] = [:]
            for (key, row) in fresh.rows { expected[key.arm, default: OutcomeCounts()].merge(row.outcomes) }
            for (key, row) in carried { expected[key.arm, default: OutcomeCounts()].merge(row.aggregate.outcomes) }
            let out = apply(fresh, carried)
            let carriedIn = carried.values.reduce(UInt64(0)) { $0 + $1.aggregate.taskCount }
            let carriedOut = out.carried.values.reduce(UInt64(0)) { $0 + $1.aggregate.taskCount }
            if fresh.taskCount + carriedIn != out.published.taskCount + carriedOut + out.outcomeOnlyTasks {
                return "task conservation (round \(round))"
            }
            let actual = Self.armOutcomes(out)
            for arm in ExperimentArm.allCases where (expected[arm] ?? OutcomeCounts()) != (actual[arm] ?? OutcomeCounts()) {
                return "per-arm outcome conservation for \(arm) (round \(round))"
            }
            if let small = out.published.rows.first(where: { $0.value.taskCount < k }) {
                return "row \(small.key) published with \(small.value.taskCount) < k (round \(round))"
            }
            carried = out.carried
        }
        return nil
    }

    func testGateConservesTasksAndArmOutcomesAndNeverPublishesASmallRow() {
        let gate = PrivacyGate(k: 5, maxCarries: 2)
        XCTAssertNil(firstGateViolation(gate.apply, k: 5, seed: 11))
        XCTAssertNil(firstGateViolation(PrivacyGate(k: 8, maxCarries: 0).apply, k: 8, seed: 12))
    }

    func testTheGateCheckCatchesAGateThatSkipsTheCoarseThreshold() {
        // Bug: publish the coarse row even when it is still below k.
        let leaky: (AggregateTable, [AggregateKey: PrivacyGate.Carried]) -> PrivacyGate.Output = { fresh, carried in
            var out = PrivacyGate(k: 1, maxCarries: 0).apply(fresh: fresh, carriedIn: carried)
            out.carried = [:]
            return out
        }
        XCTAssertNotNil(firstGateViolation(leaky, k: 5, seed: 11))
    }

    func testTheGateCheckCatchesAGateThatLosesTheArmOfReducedRows() {
        // The design this library started with: rows that never reach k were
        // reduced to a count with no arm. Emulated here by filing every
        // reduced row under one arm — task totals still balance, but the
        // per-arm outcomes (the experiment's primary metric) do not.
        let armless: (AggregateTable, [AggregateKey: PrivacyGate.Carried]) -> PrivacyGate.Output = { fresh, carried in
            var out = PrivacyGate(k: 5, maxCarries: 0).apply(fresh: fresh, carriedIn: carried)
            var lumped: [AggregateKey: OutcomeCounts] = [:]
            for (key, counts) in out.outcomeOnly {
                lumped[AggregateKey(kind: key.kind, arm: .treatment, exposure: nil), default: OutcomeCounts()].merge(counts)
            }
            out.outcomeOnly = lumped
            return out
        }
        XCTAssertEqual(firstGateViolation(armless, k: 5, seed: 11).map { $0.hasPrefix("per-arm") }, true)
    }

    func testSmallRowsAreCoarsenedThenCarriedThenReducedToOutcomeCounts() throws {
        let gate = PrivacyGate(k: 5, maxCarries: 1)
        let kind = SampleSchema.captureExpense
        func tasks(_ n: Int, exposure: AIExposure, outcome: TaskOutcome = .completed) -> AggregateTable {
            var t = AggregateTable()
            for i in 0 ..< n {
                t.add(FinishedTask(id: TaskID(UInt64(i)), kind: kind, arm: .treatment, outcome: outcome, exposure: exposure,
                                   timeToIntentNanos: outcome == .completed ? nanoseconds(2) : nil, furthestStep: 3, ai: AICounts(), revisits: 0))
            }
            return t
        }
        // 6 accepted (≥ k) + 2 none + 2 shownOnly: the two small rows coarsen
        // into 4 < k, so they are carried.
        var fresh = tasks(6, exposure: .accepted)
        fresh.merge(tasks(2, exposure: .none))
        fresh.merge(tasks(2, exposure: .shownOnly))
        let first = gate.apply(fresh: fresh, carriedIn: [:])
        XCTAssertEqual(first.published.taskCount, 6)
        XCTAssertEqual(first.carried.values.first?.aggregate.taskCount, 4)
        XCTAssertNil(first.published.rows[AggregateKey(kind: kind, arm: .treatment, exposure: nil)])

        // One more small task lifts the carried coarse row to 5: published.
        let second = gate.apply(fresh: tasks(1, exposure: .edited), carriedIn: first.carried)
        XCTAssertEqual(second.published.rows[AggregateKey(kind: kind, arm: .treatment, exposure: nil)]?.taskCount, 5)
        XCTAssertTrue(second.carried.isEmpty)

        // A row that never reaches k keeps its arm and outcomes, nothing else.
        let a = gate.apply(fresh: tasks(1, exposure: .none, outcome: .abandoned(.failed)), carriedIn: [:])
        let b = gate.apply(fresh: AggregateTable(), carriedIn: a.carried)
        XCTAssertTrue(b.carried.isEmpty)
        XCTAssertTrue(b.published.isEmpty)
        let reduced = try XCTUnwrap(b.outcomeOnly[AggregateKey(kind: kind, arm: .treatment, exposure: nil)])
        XCTAssertEqual(reduced.failed, 1)
        XCTAssertEqual(b.outcomeOnlyTasks, 1)
    }

    func testKOfOnePublishesEverything() {
        var rng = SplitMix64(seed: 5)
        let table = Fixtures.table(&rng, tasks: 30)
        let out = PrivacyGate(k: 0, maxCarries: 0).apply(fresh: table, carriedIn: [:])
        XCTAssertEqual(out.published, table)
        XCTAssertEqual(PrivacyGate(k: 0, maxCarries: -1).k, 1)
    }
}
