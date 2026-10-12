// PrivacyGate — no uploaded *detail* row may describe fewer than `k` tasks.
//
// What this is, precisely: minimum-count coarsening **per install**. Every
// batch comes from one install, so a published row of 5 tasks is still one
// person's behaviour summary; this gate is not k-anonymity across users.
// What it buys is that the server never receives a detail row that is, in
// effect, a single raw event ("one task, accepted the suggestion, 4–8 s").
// Anonymity across users needs a server-side control — a cross-install
// minimum before any slice is shown, or differential privacy — and the
// README says so.
//
// The ladder, per (kind, arm):
//
//   1. Detail rows (exposure, histogram, funnel, AI counts) with ≥ k tasks
//      are published as they are.
//   2. Smaller rows lose their exposure dimension and are merged into one
//      coarse detail row (exposure = nil). If that reaches k it is published.
//   3. Otherwise the coarse row is carried into the next seal, where new
//      tasks may lift it over k.
//   4. A row carried `maxCarries` times without reaching k is reduced to its
//      **outcome counts only**, keyed by (kind, arm): no exposure, no
//      durations, no funnel, no AI counts.
//
// Why rung 4 keeps the arm and the outcomes. An earlier design reduced such
// rows to one bare integer per batch. That biased the headline metric:
// AI-on tasks are split across four exposure rows, so they fall below k far
// more often than holdout tasks, and the tasks that fall below k skew toward
// unfinished ones. Dropping their arm and outcome inflated the measured
// effect of the AI feature by 0.8–2.7 points on five simulated fleets. Completion
// counts per arm are the primary metric of a randomised experiment, so they
// are never dropped; only detail is. Tests assert that the gated arm
// comparison equals the ungated one exactly, that the gate property check
// rejects an arm-less variant, and pin the inflation range above.

public struct PrivacyGate: Hashable, Sendable {
    /// Minimum tasks per published detail row. 1 disables the gate.
    public let k: UInt64
    /// Seals a small row may be carried through before it is reduced to counts.
    public let maxCarries: Int

    public init(k: UInt64, maxCarries: Int) {
        self.k = max(1, k)
        self.maxCarries = max(0, maxCarries)
    }

    /// A row held back because it was below `k`.
    public struct Carried: Hashable, Sendable, Codable {
        public var aggregate: OutcomeAggregate
        public var carries: Int
    }

    public struct Output: Hashable, Sendable {
        /// Detail rows, each with ≥ k tasks.
        public var published = AggregateTable()
        public var carried: [AggregateKey: Carried] = [:]
        /// Outcome counts of rows that never reached k, keyed (kind, arm, nil).
        public var outcomeOnly: [AggregateKey: OutcomeCounts] = [:]

        public var outcomeOnlyTasks: UInt64 {
            outcomeOnly.values.reduce(0) { $0.saturatingAdd($1.total) }
        }
    }

    /// Applies the ladder to `fresh` plus whatever was carried from earlier
    /// seals. Conserves tasks exactly, and conserves each arm's outcome counts:
    /// `fresh + carriedIn == published + carriedOut + outcomeOnly`.
    public func apply(fresh: AggregateTable, carriedIn: [AggregateKey: Carried]) -> Output {
        var output = Output()
        struct Group: Hashable { let kind: TelemetryName; let arm: ExperimentArm }
        var groups: [Group: [(AggregateKey, OutcomeAggregate)]] = [:]
        for (key, value) in fresh.rows {
            groups[Group(kind: key.kind, arm: key.arm), default: []].append((key, value))
        }
        var carriedByGroup: [Group: Carried] = [:]
        for (key, value) in carriedIn {
            let group = Group(kind: key.kind, arm: key.arm)
            if var existing = carriedByGroup[group] {
                existing.aggregate.merge(value.aggregate)
                existing.carries = max(existing.carries, value.carries)
                carriedByGroup[group] = existing
            } else {
                carriedByGroup[group] = value
            }
            if groups[group] == nil { groups[group] = [] }
        }

        for group in groups.keys.sorted(by: { ($0.kind, $0.arm.rawValue) < ($1.kind, $1.arm.rawValue) }) {
            var coarse = OutcomeAggregate()
            var carries = 0
            if let carried = carriedByGroup[group] {
                coarse.merge(carried.aggregate)
                carries = carried.carries
            }
            for (key, value) in groups[group] ?? [] {
                if value.taskCount >= k {
                    output.published.add(value, at: key)
                } else {
                    coarse.merge(value)
                }
            }
            guard coarse.taskCount > 0 else { continue }
            let coarseKey = AggregateKey(kind: group.kind, arm: group.arm, exposure: nil)
            if coarse.taskCount >= k {
                output.published.add(coarse, at: coarseKey)
            } else if carries < maxCarries {
                output.carried[coarseKey] = Carried(aggregate: coarse, carries: carries + 1)
            } else {
                output.outcomeOnly[coarseKey, default: OutcomeCounts()].merge(coarse.outcomes)
            }
        }
        return output
    }
}
