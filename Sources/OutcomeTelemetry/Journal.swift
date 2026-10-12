// OutcomeJournal — the offline-first upload queue.
//
// Delivery is at-least-once: a batch is retried until the server says it was
// accepted, and the server dedupes on the batch id. Two rules make that safe:
//
// 1. **A batch is frozen from its first attempt.** The attempt counter is
//    burned *before* the send. A request that timed out may still have been
//    applied server-side, so once a batch has been attempted its content and
//    its id can never change again — otherwise a retry would carry different
//    numbers under the same idempotency key, and the server would keep the
//    first copy and silently lose the difference.
//
// 2. **Back-pressure coalesces, it never drops.** When the queue is full, a
//    newly sealed batch is merged into the newest *never-attempted* batch.
//    That is only possible because aggregates are a commutative monoid
//    (see Aggregate.swift): merged batches carry exactly the same totals.
//    The queue is therefore bounded at `capacity + 1` batches no matter how
//    long the device is offline, and nothing is lost to the bound.
//
// Batch ids are random per batch, not per install, so two batches from the
// same device cannot be linked to each other by their ids.

/// The unit of upload.
public struct UploadBatch: Hashable, Sendable, Codable, Identifiable {
    /// Idempotency key. Random per batch.
    public let id: String
    /// Detail rows, each with ≥ k tasks (see `PrivacyGate`).
    public private(set) var table: AggregateTable
    /// Outcome counts of rows the privacy gate reduced, keyed (kind, arm, nil).
    public private(set) var outcomeOnly: [AggregateKey: OutcomeCounts]
    /// Sends attempted so far. Non-zero ⇒ frozen.
    public internal(set) var attempts: Int
    /// How many seals were coalesced into this batch (1 = none).
    public private(set) var seals: Int

    public init(id: String, table: AggregateTable, outcomeOnly: [AggregateKey: OutcomeCounts] = [:]) {
        self.id = id
        self.table = table
        self.outcomeOnly = outcomeOnly
        self.attempts = 0
        self.seals = 1
    }

    public var outcomeOnlyTasks: UInt64 { outcomeOnly.values.reduce(0) { $0.saturatingAdd($1.total) } }

    /// Every task this batch accounts for.
    public var taskCount: UInt64 { table.taskCount.saturatingAdd(outcomeOnlyTasks) }
    public var isFrozen: Bool { attempts > 0 }

    /// Merges `other` into this batch. Reports `false` instead of mutating a
    /// frozen batch.
    @discardableResult
    mutating func coalesce(_ other: UploadBatch) -> Bool {
        guard !isFrozen else { return false }
        table.merge(other.table)
        for (key, counts) in other.outcomeOnly { outcomeOnly[key, default: OutcomeCounts()].merge(counts) }
        seals = seals.saturatingAddingInt(other.seals)
        return true
    }
}

extension Int {
    func saturatingAddingInt(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

public struct OutcomeJournal: Sendable, Codable, Hashable {
    /// Batches allowed in the queue before new seals are coalesced.
    public let capacity: Int
    /// Attempts before a batch is dead-lettered.
    public let maxAttempts: Int

    public private(set) var pending: [UploadBatch] = []
    public private(set) var ackedTasks: UInt64 = 0
    public private(set) var ackedBatches: UInt64 = 0
    public private(set) var deadLetteredTasks: UInt64 = 0
    public private(set) var coalescedSeals: UInt64 = 0

    public init(capacity: Int, maxAttempts: Int) {
        self.capacity = max(1, capacity)
        self.maxAttempts = max(1, maxAttempts)
    }

    /// The persisted queue and counters under the *current* policy. A later
    /// release that changes capacity or attempts must take effect on upgraded
    /// installs, so the policy is never restored from disk — only the data.
    public init(adopting persisted: OutcomeJournal, capacity: Int, maxAttempts: Int) {
        self.init(capacity: capacity, maxAttempts: maxAttempts)
        pending = persisted.pending
        ackedTasks = persisted.ackedTasks
        ackedBatches = persisted.ackedBatches
        deadLetteredTasks = persisted.deadLetteredTasks
        coalescedSeals = persisted.coalescedSeals
    }

    public var pendingTasks: UInt64 { pending.reduce(0) { $0.saturatingAdd($1.taskCount) } }

    /// Adds a sealed batch, coalescing under back-pressure.
    public mutating func append(_ batch: UploadBatch) {
        guard batch.taskCount > 0 else { return }
        if pending.count >= capacity, let target = pending.lastIndex(where: { !$0.isFrozen }) {
            if pending[target].coalesce(batch) {
                coalescedSeals = coalescedSeals.saturatingAdd(1)
                return
            }
        }
        pending.append(batch)
    }

    /// Burns an attempt on the oldest batch and returns its frozen copy.
    public mutating func beginAttempt() -> UploadBatch? {
        guard !pending.isEmpty else { return nil }
        pending[0].attempts = pending[0].attempts.saturatingAddingInt(1)
        return pending[0]
    }

    /// The server accepted (or had already accepted) the batch.
    public mutating func acknowledge(id: String) {
        // Looked up by id, never by index: other batches may have been
        // appended or coalesced while the send was suspended.
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let batch = pending.remove(at: index)
        ackedTasks = ackedTasks.saturatingAdd(batch.taskCount)
        ackedBatches = ackedBatches.saturatingAdd(1)
    }

    /// The send failed. Returns true if the batch was dead-lettered.
    @discardableResult
    public mutating func fail(id: String, permanent: Bool) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        guard permanent || pending[index].attempts >= maxAttempts else { return false }
        let batch = pending.remove(at: index)
        deadLetteredTasks = deadLetteredTasks.saturatingAdd(batch.taskCount)
        return true
    }
}

/// Exponential backoff with full jitter. Pure: the caller supplies the
/// random unit value, so tests can pin it.
public struct RetryPolicy: Hashable, Sendable {
    public let baseNanos: UInt64
    public let capNanos: UInt64

    public init(baseSeconds: Double, capSeconds: Double) {
        baseNanos = max(1, nanoseconds(baseSeconds))
        capNanos = max(baseNanos, nanoseconds(capSeconds))
    }

    /// Delay before attempt `attempt + 1`, given `attempt` failures so far.
    /// `unit` is a uniform random value in [0, 1]; out-of-range or NaN values
    /// are clamped, so the result is always within `0...capNanos`.
    public func delay(afterAttempt attempt: Int, unit: Double) -> UInt64 {
        // `attempt - 1` would trap for Int.min; compare first, then subtract.
        let exponent = attempt <= 1 ? 0 : min(attempt - 1, 62)
        let ceiling = min(baseNanos.saturatingMul(UInt64(1) << UInt64(exponent)), capNanos)
        let u = unit.isNaN ? 0 : min(max(unit, 0), 1)
        return min(UInt64.clamping(Double(ceiling) * u), ceiling)
    }
}
