// On-device aggregation — the second privacy control, and the reason
// back-pressure in this SDK never has to drop data.
//
// Finished tasks are folded into rows keyed by (kind, arm, exposure). A row
// holds counts and a fixed-bucket duration histogram; it never holds a task
// id, a timestamp, an exact duration or an event sequence. What leaves the
// device is "37 capture-expense tasks in the treatment arm completed, 9 of
// them in 4–8 s", not "user X did Y at 14:02:11".
//
// Every type here is a commutative monoid under `merge` (associative,
// commutative, with an empty identity). That one algebraic property is what
// lets the journal coalesce batches under back-pressure, lets the server sum
// batches in any order, and lets a report be computed from any subset of
// rows. The property is tested directly, with a deliberately broken merge
// that the same test must reject.

/// Fixed log-scale histogram of durations. Bucket upper bounds in ms:
/// 250, 500, 1 000, 2 000, 4 000, 8 000, 16 000, 32 000, 64 000, 128 000,
/// 256 000, then +∞. The shape never changes, so two histograms always merge.
public struct DurationHistogram: Hashable, Sendable, Codable {
    public static let upperBoundsMillis: [UInt64] = [250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000, 256_000]
    public static var bucketCount: Int { upperBoundsMillis.count + 1 }

    public private(set) var counts: [UInt64]

    public init() { counts = Array(repeating: 0, count: Self.bucketCount) }

    /// Index of the bucket that holds `nanos`.
    public static func bucket(forNanos nanos: UInt64) -> Int {
        let millis = nanos / 1_000_000
        return upperBoundsMillis.firstIndex { millis < $0 } ?? upperBoundsMillis.count
    }

    public mutating func add(nanos: UInt64) {
        let index = Self.bucket(forNanos: nanos)
        guard counts.indices.contains(index) else { return }
        counts[index] = counts[index].saturatingAdd(1)
    }

    public var total: UInt64 { counts.reduce(0) { $0.saturatingAdd($1) } }

    public mutating func merge(_ other: DurationHistogram) {
        // Both arrays have `bucketCount` elements by construction; decoding
        // re-validates that, and `zip` would truncate rather than trap anyway.
        counts = zip(counts, other.counts).map { $0.saturatingAdd($1) }
    }

    /// Upper bound (ms) of the bucket containing quantile `q` (0...1), or nil
    /// for an empty histogram. Returns `nil` for the open-ended last bucket's
    /// bound, reported as "> 256 s" by the UI. Never interpolates: a bucketed
    /// histogram cannot honestly claim more precision than its buckets.
    public func quantileUpperBoundMillis(_ q: Double) -> QuantileBound? {
        let n = total
        guard n > 0, q.isFinite else { return nil }
        let clampedQ = min(max(q, 0), 1)
        // Rank of the target observation, 1-based, in 1...n.
        let rank = max(1, UInt64.clamping((clampedQ * Double(n)).rounded(.up)))
        var seen: UInt64 = 0
        for (index, count) in counts.enumerated() {
            seen = seen.saturatingAdd(count)
            if seen >= rank {
                return Self.upperBoundsMillis.indices.contains(index)
                    ? .atMost(Self.upperBoundsMillis[index])
                    : .above(Self.upperBoundsMillis.last ?? 0)
            }
        }
        return .above(Self.upperBoundsMillis.last ?? 0)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([UInt64].self)
        guard decoded.count == Self.bucketCount else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "histogram shape mismatch"))
        }
        counts = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counts)
    }
}

/// A bucket bound reported for a quantile.
public enum QuantileBound: Hashable, Sendable {
    case atMost(UInt64)
    case above(UInt64)

    public var label: String {
        switch self {
        case let .atMost(ms): return "≤ " + Self.format(ms)
        case let .above(ms): return "> " + Self.format(ms)
        }
    }

    public var sortKey: UInt64 {
        switch self {
        case let .atMost(ms): return ms
        case let .above(ms): return ms.saturatingAdd(1)
        }
    }

    static func format(_ ms: UInt64) -> String {
        ms < 1_000 ? "\(ms) ms" : "\(ms / 1_000) s"
    }
}

/// Grouping key of an aggregate row. Every component is from a closed set
/// or a validated `TelemetryName`.
public struct AggregateKey: Hashable, Comparable, Sendable, Codable {
    public let kind: TelemetryName
    public let arm: ExperimentArm
    /// nil means "all exposures" — the coarser row the privacy gate falls
    /// back to when a per-exposure row is too small.
    public let exposure: AIExposure?

    public init(kind: TelemetryName, arm: ExperimentArm, exposure: AIExposure?) {
        self.kind = kind
        self.arm = arm
        self.exposure = exposure
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.kind.rawValue, lhs.arm.rawValue, lhs.exposure?.rawValue ?? -1)
            < (rhs.kind.rawValue, rhs.arm.rawValue, rhs.exposure?.rawValue ?? -1)
    }
}

/// Outcome counts for a group of tasks.
public struct OutcomeCounts: Hashable, Sendable, Codable {
    public var completed: UInt64 = 0
    public var timedOut: UInt64 = 0
    public var interrupted: UInt64 = 0
    public var userCancelled: UInt64 = 0
    public var leftApp: UInt64 = 0
    public var failed: UInt64 = 0
    public var evicted: UInt64 = 0

    public init() {}

    public var abandoned: UInt64 {
        userCancelled.saturatingAdd(leftApp).saturatingAdd(failed).saturatingAdd(evicted)
    }

    public var total: UInt64 {
        completed.saturatingAdd(timedOut).saturatingAdd(interrupted).saturatingAdd(abandoned)
    }

    mutating func add(_ outcome: TaskOutcome) {
        switch outcome {
        case .completed: completed = completed.saturatingAdd(1)
        case .timedOut: timedOut = timedOut.saturatingAdd(1)
        case .interrupted: interrupted = interrupted.saturatingAdd(1)
        case let .abandoned(reason):
            switch reason {
            case .userCancelled: userCancelled = userCancelled.saturatingAdd(1)
            case .leftApp: leftApp = leftApp.saturatingAdd(1)
            case .failed: failed = failed.saturatingAdd(1)
            case .evicted: evicted = evicted.saturatingAdd(1)
            }
        }
    }

    public mutating func merge(_ other: OutcomeCounts) {
        completed = completed.saturatingAdd(other.completed)
        timedOut = timedOut.saturatingAdd(other.timedOut)
        interrupted = interrupted.saturatingAdd(other.interrupted)
        userCancelled = userCancelled.saturatingAdd(other.userCancelled)
        leftApp = leftApp.saturatingAdd(other.leftApp)
        failed = failed.saturatingAdd(other.failed)
        evicted = evicted.saturatingAdd(other.evicted)
    }
}

/// One aggregate row: everything the server learns about a group of tasks.
public struct OutcomeAggregate: Hashable, Sendable, Codable {
    public var outcomes = OutcomeCounts()
    /// Time-to-intent of completed, measurable tasks.
    public var timeToIntent = DurationHistogram()
    /// For tasks that did not complete: how many stopped after each funnel
    /// step (index), plus `noStepReached`. Fixed size `TaskDefinition.maxSteps`.
    public private(set) var dropOff: [UInt64] = Array(repeating: 0, count: TaskDefinition.maxSteps)
    public var noStepReached: UInt64 = 0
    public var ai = AICounts()
    public var revisits: UInt64 = 0

    public init() {}

    public var taskCount: UInt64 { outcomes.total }

    public mutating func add(_ task: FinishedTask) {
        outcomes.add(task.outcome)
        if case .completed = task.outcome, let nanos = task.timeToIntentNanos {
            timeToIntent.add(nanos: nanos)
        } else if case .completed = task.outcome {
            // A completed task always carries a duration (the ledger turns an
            // unmeasurable completion into `.interrupted`), so nothing to do.
        } else if let step = task.furthestStep, dropOff.indices.contains(step) {
            dropOff[step] = dropOff[step].saturatingAdd(1)
        } else {
            noStepReached = noStepReached.saturatingAdd(1)
        }
        ai.merge(task.ai)
        revisits = revisits.saturatingAdd(task.revisits)
    }

    public mutating func merge(_ other: OutcomeAggregate) {
        outcomes.merge(other.outcomes)
        timeToIntent.merge(other.timeToIntent)
        dropOff = zip(dropOff, other.dropOff).map { $0.saturatingAdd($1) }
        noStepReached = noStepReached.saturatingAdd(other.noStepReached)
        ai.merge(other.ai)
        revisits = revisits.saturatingAdd(other.revisits)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcomes = try c.decode(OutcomeCounts.self, forKey: .outcomes)
        timeToIntent = try c.decode(DurationHistogram.self, forKey: .timeToIntent)
        let decodedDropOff = try c.decode([UInt64].self, forKey: .dropOff)
        guard decodedDropOff.count == TaskDefinition.maxSteps else {
            throw DecodingError.dataCorruptedError(forKey: .dropOff, in: c, debugDescription: "drop-off shape mismatch")
        }
        dropOff = decodedDropOff
        noStepReached = try c.decode(UInt64.self, forKey: .noStepReached)
        ai = try c.decode(AICounts.self, forKey: .ai)
        revisits = try c.decode(UInt64.self, forKey: .revisits)
    }

    private enum CodingKeys: String, CodingKey {
        case outcomes, timeToIntent, dropOff, noStepReached, ai, revisits
    }
}

/// A set of rows. Merging two tables merges matching rows.
public struct AggregateTable: Hashable, Sendable, Codable {
    public private(set) var rows: [AggregateKey: OutcomeAggregate] = [:]

    public init() {}

    public var isEmpty: Bool { rows.isEmpty }
    public var taskCount: UInt64 { rows.values.reduce(0) { $0.saturatingAdd($1.taskCount) } }
    public var sortedRows: [(key: AggregateKey, value: OutcomeAggregate)] { rows.sorted { $0.key < $1.key } }

    public mutating func add(_ task: FinishedTask) {
        let key = AggregateKey(kind: task.kind, arm: task.arm, exposure: task.exposure)
        rows[key, default: OutcomeAggregate()].add(task)
    }

    public mutating func add(_ aggregate: OutcomeAggregate, at key: AggregateKey) {
        rows[key, default: OutcomeAggregate()].merge(aggregate)
    }

    public mutating func merge(_ other: AggregateTable) {
        for (key, value) in other.rows { add(value, at: key) }
    }
}
