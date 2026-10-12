// OutcomeRecorder — the one actor the app talks to.
//
// It owns the four stages and is the only place they meet:
//
//   app events ─▶ TaskLedger ─▶ AggregateTable ─▶ PrivacyGate ─▶ OutcomeJournal ─▶ OutcomeTransport
//                (state machine)  (accumulating)   (seal: k-gate)   (queue, retry)     (app-supplied)
//
// Everything except `flush()` is synchronous inside the actor, so ordering
// is simple: events are applied in the order the actor receives them.
// `flush()` is the single suspension point, and it is written for actor
// reentrancy: while it awaits the transport, other calls run and may append
// or coalesce batches. So it (a) refuses to start a second flush, (b) sends a
// batch that was frozen before the await and so cannot change under it, and
// (c) settles that batch by id afterwards, never by index.
//
// Conservation law (checked in tests over randomised event and fault
// sequences, and shown live in the demo):
//
//   finishedTasks == accumulating + carried + pending + acked + deadLettered

import Foundation

public struct OutcomeConfiguration: Sendable {
    public var definitions: [TaskDefinition]
    public var cohorts: CohortAssigner
    public var gate: PrivacyGate
    /// Seal a batch once this many tasks have finished…
    public var minTasksPerBatch: Int
    /// …or once the oldest unsealed task finished this long ago.
    public var maxBatchAgeNanos: UInt64
    public var journalCapacity: Int
    public var maxAttempts: Int
    public var retry: RetryPolicy
    public var ledgerCapacity: Int

    public init(
        definitions: [TaskDefinition],
        cohorts: CohortAssigner,
        gate: PrivacyGate = PrivacyGate(k: 5, maxCarries: 3),
        minTasksPerBatch: Int = 20,
        maxBatchAgeSeconds: Double = 600,
        journalCapacity: Int = 8,
        maxAttempts: Int = 6,
        retry: RetryPolicy = RetryPolicy(baseSeconds: 2, capSeconds: 300),
        ledgerCapacity: Int = 32
    ) {
        self.definitions = definitions
        self.cohorts = cohorts
        self.gate = gate
        self.minTasksPerBatch = max(1, minTasksPerBatch)
        self.maxBatchAgeNanos = max(1, nanoseconds(maxBatchAgeSeconds))
        self.journalCapacity = journalCapacity
        self.maxAttempts = maxAttempts
        self.retry = retry
        self.ledgerCapacity = ledgerCapacity
    }
}

/// A point-in-time view of the pipeline, for dashboards and tests.
public struct PipelineHealth: Hashable, Sendable {
    public var arm: ExperimentArm
    public var openTasks: Int
    public var finishedTasks: UInt64
    public var accumulatingTasks: UInt64
    public var carriedTasks: UInt64
    public var pendingTasks: UInt64
    public var pendingBatches: Int
    public var frozenBatches: Int
    public var ackedTasks: UInt64
    public var ackedBatches: UInt64
    public var deadLetteredTasks: UInt64
    public var coalescedSeals: UInt64
    /// Tasks the privacy gate reduced to outcome counts (still in the totals).
    public var outcomeOnlyTasks: UInt64
    public var rejections: [Rejection: UInt64]
    public var lastFlush: FlushResult?

    /// Every finished task is in exactly one place.
    public var accountedTasks: UInt64 {
        accumulatingTasks.saturatingAdd(carriedTasks).saturatingAdd(pendingTasks)
            .saturatingAdd(ackedTasks).saturatingAdd(deadLetteredTasks)
    }

    public var isConserved: Bool { accountedTasks == finishedTasks }
}

public enum FlushResult: Hashable, Sendable {
    case nothingToSend
    case alreadyFlushing
    case backingOff(remainingNanos: UInt64)
    case sent(batchID: String, tasks: UInt64)
    case willRetry(batchID: String, attempt: Int, delayNanos: UInt64)
    case deadLettered(batchID: String, tasks: UInt64)
    /// The write-ahead save failed, so nothing was sent (see `writeAhead`).
    case writeAheadFailed(batchID: String)
}

public actor OutcomeRecorder {
    public nonisolated let arm: ExperimentArm
    private let configuration: OutcomeConfiguration
    private let clock: any TelemetryClock
    private let transport: any OutcomeTransport
    private let makeBatchID: @Sendable () -> String
    private let jitter: @Sendable () -> Double
    private let writeAhead: (@Sendable (PersistentState) async -> Bool)?

    private var ledger: TaskLedger
    private var accumulating = AggregateTable()
    private var accumulatingSince: MonotonicInstant?
    private var carried: [AggregateKey: PrivacyGate.Carried] = [:]
    private var journal: OutcomeJournal
    private var finishedTasks: UInt64 = 0
    private var outcomeOnlyTasks: UInt64 = 0
    private var isFlushing = false
    private var notBefore: MonotonicInstant?
    private var lastFlush: FlushResult?

    public init(
        configuration: OutcomeConfiguration,
        installID: String,
        clock: any TelemetryClock,
        transport: any OutcomeTransport,
        makeBatchID: @escaping @Sendable () -> String = { UUID().uuidString },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) },
        writeAhead: (@Sendable (PersistentState) async -> Bool)? = nil,
        restoring state: PersistentState? = nil
    ) {
        self.writeAhead = writeAhead
        let arm = configuration.cohorts.arm(forInstall: installID)
        self.arm = arm
        self.configuration = configuration
        self.clock = clock
        self.transport = transport
        self.makeBatchID = makeBatchID
        self.jitter = jitter
        var ledger = TaskLedger(definitions: configuration.definitions, arm: arm, capacity: configuration.ledgerCapacity)
        var journal = OutcomeJournal(capacity: configuration.journalCapacity, maxAttempts: configuration.maxAttempts)
        var accumulating = AggregateTable()
        var finished: UInt64 = 0
        if let state {
            // Everything that was in flight in the previous process comes back
            // exactly as it was: frozen batches stay frozen (their attempt
            // counts are part of the journal), carried rows keep their carry
            // count, and open tasks end as `.interrupted` because their clock
            // readings belong to the dead process.
            journal = OutcomeJournal(adopting: state.journal, capacity: configuration.journalCapacity,
                                     maxAttempts: configuration.maxAttempts)
            accumulating = state.accumulating
            finished = state.finishedTasks
            self.carried = state.carried
            self.outcomeOnlyTasks = state.outcomeOnlyTasks
            for task in ledger.restore(state.ledger, now: clock.now()) {
                finished = finished.saturatingAdd(1)
                accumulating.add(task)
            }
        }
        self.ledger = ledger
        self.journal = journal
        self.accumulating = accumulating
        self.finishedTasks = finished
        self.accumulatingSince = accumulating.isEmpty ? nil : clock.now()
    }

    /// Everything needed to survive a process kill: open tasks, the
    /// accumulating table, carried rows and the journal (with attempt counts).
    /// Pass it to `init(..., restoring:)` on the next launch.
    ///
    /// Supply `writeAhead` to make delivery crash-consistent: the recorder
    /// saves this state before every send, so a batch's id is durable before
    /// the server can see it. Without it, a crash between a send and the
    /// app's next save can make the server count those tasks twice. Also
    /// save on backgrounding; tasks finished after the last save are lost.
    /// Not persisted: rejection counters, the last flush result, the backoff.
    public struct PersistentState: Codable, Sendable, Hashable {
        public var ledger: LedgerSnapshot
        public var accumulating: AggregateTable
        public var carried: [AggregateKey: PrivacyGate.Carried]
        public var journal: OutcomeJournal
        public var finishedTasks: UInt64
        public var outcomeOnlyTasks: UInt64
    }

    public func persistentState() -> PersistentState {
        PersistentState(
            ledger: ledger.snapshot(), accumulating: accumulating, carried: carried,
            journal: journal, finishedTasks: finishedTasks, outcomeOnlyTasks: outcomeOnlyTasks
        )
    }

    /// Whether AI features should be offered on this install. The app must
    /// gate its AI UI on this; AI events from a holdout install are rejected.
    public nonisolated var aiEnabled: Bool { arm == .treatment }

    // MARK: - Events

    @discardableResult
    public func begin(_ kind: TelemetryName) -> TaskID? {
        let result = ledger.begin(kind, now: clock.now())
        if let evicted = result.evicted { absorb(evicted) }
        return result.id
    }

    @discardableResult
    public func record(step: TelemetryName, for id: TaskID) -> LedgerResult {
        settle(ledger.record(step: step, for: id, now: clock.now()))
    }

    @discardableResult
    public func record(ai event: AIEvent, feature: TelemetryName, for id: TaskID) -> LedgerResult {
        settle(ledger.record(ai: event, feature: feature, for: id, now: clock.now()))
    }

    @discardableResult
    public func abandon(_ id: TaskID, reason: AbandonReason) -> LedgerResult {
        settle(ledger.abandon(id, reason: reason, now: clock.now()))
    }

    public func didEnterBackground() {
        ledger.didEnterBackground(now: clock.now()).forEach(absorb)
        // Going to the background is the last reliable moment to seal.
        seal()
    }

    public func willEnterForeground() {
        ledger.willEnterForeground(now: clock.now()).forEach(absorb)
    }

    /// Ends expired tasks and seals a batch if one is due. Returns whether it sealed.
    @discardableResult
    public func tick() -> Bool {
        ledger.sweep(now: clock.now()).forEach(absorb)
        guard isSealDue() else { return false }
        seal()
        return true
    }

    // MARK: - Sealing & upload

    /// Applies the privacy gate to everything accumulated and queues it.
    public func seal() {
        let output = configuration.gate.apply(fresh: accumulating, carriedIn: carried)
        accumulating = AggregateTable()
        accumulatingSince = nil
        carried = output.carried
        outcomeOnlyTasks = outcomeOnlyTasks.saturatingAdd(output.outcomeOnlyTasks)
        let batch = UploadBatch(id: makeBatchID(), table: output.published, outcomeOnly: output.outcomeOnly)
        journal.append(batch)
    }

    /// Sends the oldest pending batch once. Call repeatedly to drain.
    @discardableResult
    public func flush() async -> FlushResult {
        let result = await flushOnce()
        lastFlush = result
        return result
    }

    private func flushOnce() async -> FlushResult {
        guard !isFlushing else { return .alreadyFlushing }
        let now = clock.now()
        if let gate = notBefore {
            // Same session and not yet reached ⇒ still backing off. A reading
            // from another session (relaunch) clears the backoff.
            if gate.session == now.session, now.nanos < gate.nanos {
                return .backingOff(remainingNanos: gate.nanos - now.nanos)
            }
            notBefore = nil
        }
        guard let batch = journal.beginAttempt() else { return .nothingToSend }
        isFlushing = true
        defer { isFlushing = false }

        // Write-ahead: a batch's idempotency key must be durable *before* its
        // first send. Otherwise a crash after the server accepted it but
        // before the app persisted would restore an older snapshot, re-seal
        // the same tasks under a new random id, and the server would count
        // them twice. The save runs while `isFlushing` is held, so no other
        // flush can overtake it; other calls may still run (reentrancy), which
        // is harmless because the batch being sent is already frozen.
        if let writeAhead, await writeAhead(persistentState()) == false {
            return .writeAheadFailed(batchID: batch.id)
        }

        let result = await transport.send(batch) // ← suspension point; see header

        switch result {
        case .accepted:
            journal.acknowledge(id: batch.id)
            return .sent(batchID: batch.id, tasks: batch.taskCount)
        case .permanent:
            journal.fail(id: batch.id, permanent: true)
            return .deadLettered(batchID: batch.id, tasks: batch.taskCount)
        case .retryable:
            if journal.fail(id: batch.id, permanent: false) {
                return .deadLettered(batchID: batch.id, tasks: batch.taskCount)
            }
            let delay = configuration.retry.delay(afterAttempt: batch.attempts, unit: jitter())
            let current = clock.now()
            notBefore = MonotonicInstant(session: current.session, nanos: current.nanos.saturatingAdd(delay))
            return .willRetry(batchID: batch.id, attempt: batch.attempts, delayNanos: delay)
        }
    }

    // MARK: - Observability

    public func health() -> PipelineHealth {
        PipelineHealth(
            arm: arm,
            openTasks: ledger.openCount,
            finishedTasks: finishedTasks,
            accumulatingTasks: accumulating.taskCount,
            carriedTasks: carried.values.reduce(0) { $0.saturatingAdd($1.aggregate.taskCount) },
            pendingTasks: journal.pendingTasks,
            pendingBatches: journal.pending.count,
            frozenBatches: journal.pending.filter(\.isFrozen).count,
            ackedTasks: journal.ackedTasks,
            ackedBatches: journal.ackedBatches,
            deadLetteredTasks: journal.deadLetteredTasks,
            coalescedSeals: journal.coalescedSeals,
            outcomeOnlyTasks: outcomeOnlyTasks,
            rejections: ledger.rejections,
            lastFlush: lastFlush
        )
    }

    /// Clears the retry backoff (e.g. on a reachability change).
    public func resetBackoff() { notBefore = nil }

    // MARK: - Internals

    private func settle(_ result: LedgerResult) -> LedgerResult {
        if case let .finished(task) = result { absorb(task) }
        return result
    }

    private func absorb(_ task: FinishedTask) {
        finishedTasks = finishedTasks.saturatingAdd(1)
        if accumulating.isEmpty { accumulatingSince = clock.now() }
        accumulating.add(task)
    }

    private func isSealDue() -> Bool {
        guard !accumulating.isEmpty else { return false }
        if accumulating.taskCount >= UInt64.clamping(configuration.minTasksPerBatch) { return true }
        guard let since = accumulatingSince else { return true }
        // Incomparable clock ⇒ we cannot prove the batch is young: seal.
        guard let age = clock.now().nanos(since: since) else { return true }
        return age >= configuration.maxBatchAgeNanos
    }
}
