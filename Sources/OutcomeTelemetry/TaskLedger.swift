// TaskLedger — the per-install state machine for task instances.
//
// A value type with no I/O and no clock of its own: every transition takes
// `now` as an argument and returns what happened. That makes the trickiest
// rules (foreground-only time, background abandonment, clock discontinuities,
// capacity eviction) exhaustively testable without an actor or a sleep.
//
// State machine per task instance:
//
//     begin ──▶ open(foreground) ⇄ open(background)
//                  │  step(intent) ─────────────▶ completed
//                  │  abandon(reason) ──────────▶ abandoned(reason)
//                  │  active time > budget ─────▶ timedOut
//                  │  background gap > limit ───▶ abandoned(.leftApp)
//                  │  incomparable clock ───────▶ interrupted
//                  └  capacity full, oldest ────▶ abandoned(.evicted)
//
// Terminal states are final: the task is removed from `open`, so any later
// event for it is rejected as `.unknownTask` and counted, never applied.

/// Opaque identifier of one task instance. Never uploaded.
public struct TaskID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public var description: String { "task#\(value)" }
}

/// Counts of AI events in one task. Fixed shape, so it merges and encodes
/// without depending on what the app sent.
public struct AICounts: Hashable, Sendable, Codable {
    public var shown: UInt64 = 0
    public var accepted: UInt64 = 0
    public var edited: UInt64 = 0
    public var rejected: UInt64 = 0

    public init() {}

    mutating func add(_ event: AIEvent) {
        switch event {
        case .shown: shown = shown.saturatingAdd(1)
        case .accepted: accepted = accepted.saturatingAdd(1)
        case .edited: edited = edited.saturatingAdd(1)
        case .rejected: rejected = rejected.saturatingAdd(1)
        }
    }

    mutating func merge(_ other: AICounts) {
        shown = shown.saturatingAdd(other.shown)
        accepted = accepted.saturatingAdd(other.accepted)
        edited = edited.saturatingAdd(other.edited)
        rejected = rejected.saturatingAdd(other.rejected)
    }
}

/// A task instance that has reached a terminal state. Input to aggregation;
/// it never leaves the device in this form.
public struct FinishedTask: Hashable, Sendable {
    public let id: TaskID
    public let kind: TelemetryName
    public let arm: ExperimentArm
    public let outcome: TaskOutcome
    public let exposure: AIExposure
    /// Foreground nanoseconds from begin to intent. Non-nil only for
    /// `.completed` tasks whose readings were comparable.
    public let timeToIntentNanos: UInt64?
    /// Index of the furthest funnel step reached, or nil if none was.
    public let furthestStep: Int?
    public let ai: AICounts
    public let revisits: UInt64
}

/// Why an event was not applied. Counted; never thrown at the app.
public enum Rejection: String, Hashable, Sendable, Codable, CaseIterable {
    /// The task kind was never registered.
    case unknownKind
    /// The task already ended (or never existed).
    case unknownTask
    /// The step is not part of this task's funnel.
    case unknownStep
    /// The AI feature is not declared for this task kind.
    case unknownAIFeature
    /// An AI event arrived from a holdout install — the feature should be
    /// off. This is an experiment-integrity alarm, not a data point.
    case aiEventInHoldout
}

/// Result of applying one event.
public enum LedgerResult: Hashable, Sendable {
    /// Applied; the task is still open.
    case applied
    /// A step earlier than (or equal to) the furthest one; counted as a revisit.
    case revisit
    /// The task ended — because of this event, or because it had already
    /// timed out / been interrupted when the event arrived (the event itself
    /// is then not applied).
    case finished(FinishedTask)
    case rejected(Rejection)
}

/// Codable state, for persisting open tasks across a relaunch.
public struct LedgerSnapshot: Codable, Sendable, Hashable {
    fileprivate var open: [OpenTask]
    fileprivate var nextID: UInt64
}

private struct OpenTask: Codable, Sendable, Hashable {
    let id: TaskID
    let kind: TelemetryName
    let startedAt: MonotonicInstant
    /// Start of the current foreground stretch; nil while backgrounded.
    var resumedAt: MonotonicInstant?
    /// When the app went to the background; nil while foregrounded.
    var backgroundedAt: MonotonicInstant?
    /// Foreground time accumulated before `resumedAt`.
    var activeNanos: UInt64 = 0
    var furthestStep: Int?
    var revisits: UInt64 = 0
    var exposure: AIExposure = .none
    var ai = AICounts()

    func withID(_ id: TaskID) -> OpenTask {
        var copy = OpenTask(id: id, kind: kind, startedAt: startedAt, resumedAt: resumedAt, backgroundedAt: backgroundedAt)
        copy.activeNanos = activeNanos
        copy.furthestStep = furthestStep
        copy.revisits = revisits
        copy.exposure = exposure
        copy.ai = ai
        return copy
    }
}

public struct TaskLedger: Sendable {
    public let arm: ExperimentArm
    /// Maximum simultaneously open tasks. Beyond it the oldest is evicted, so
    /// a screen that calls `begin` in a loop cannot grow memory without bound.
    public let capacity: Int

    private let definitions: [TelemetryName: TaskDefinition]
    private var open: [TaskID: OpenTask] = [:]
    private var nextID: UInt64 = 1
    private var inBackground = false
    public private(set) var rejections: [Rejection: UInt64] = [:]

    public init(definitions: [TaskDefinition], arm: ExperimentArm, capacity: Int = 32) {
        var table: [TelemetryName: TaskDefinition] = [:]
        for definition in definitions { table[definition.kind] = definition }
        self.definitions = table
        self.arm = arm
        self.capacity = max(1, capacity)
    }

    public var openCount: Int { open.count }
    public var openTaskIDs: [TaskID] { open.keys.sorted() }

    // MARK: - Transitions

    /// Starts a task. If the ledger is full, the oldest open task is ended as
    /// `.abandoned(.evicted)` and returned alongside the new id.
    public mutating func begin(_ kind: TelemetryName, now: MonotonicInstant) -> (id: TaskID?, evicted: FinishedTask?) {
        guard definitions[kind] != nil else {
            reject(.unknownKind)
            return (nil, nil)
        }
        var evicted: FinishedTask?
        if open.count >= capacity, let oldest = open.keys.min() {
            evicted = finish(oldest, as: .abandoned(.evicted), now: now)
        }
        let id = TaskID(nextID)
        // Wrapping is unreachable in practice (2^64 tasks); &+ avoids a trap.
        nextID = nextID &+ 1
        open[id] = OpenTask(
            id: id, kind: kind, startedAt: now,
            resumedAt: inBackground ? nil : now,
            backgroundedAt: inBackground ? now : nil
        )
        return (id, evicted)
    }

    /// Records progress through the funnel. Reaching the intent completes it.
    public mutating func record(step: TelemetryName, for id: TaskID, now: MonotonicInstant) -> LedgerResult {
        guard let task = open[id], let definition = definitions[task.kind] else { return reject(.unknownTask) }
        if let ended = endIfExpired(task, definition, now: now) { return .finished(ended) }
        guard let index = definition.index(of: step) else { return reject(.unknownStep) }
        if index == definition.steps.count - 1 {
            open[id]?.furthestStep = index
            return finished(id, as: .completed, now: now)
        }
        if let furthest = task.furthestStep, index <= furthest {
            open[id]?.revisits = task.revisits.saturatingAdd(1)
            return .revisit
        }
        open[id]?.furthestStep = index
        return .applied
    }

    /// Records an AI interaction for a declared feature.
    public mutating func record(ai event: AIEvent, feature: TelemetryName, for id: TaskID, now: MonotonicInstant) -> LedgerResult {
        guard let task = open[id], let definition = definitions[task.kind] else { return reject(.unknownTask) }
        guard definition.aiFeatures.contains(feature) else { return reject(.unknownAIFeature) }
        guard arm == .treatment else { return reject(.aiEventInHoldout) }
        if let ended = endIfExpired(task, definition, now: now) { return .finished(ended) }
        open[id]?.ai.add(event)
        open[id]?.exposure = max(task.exposure, event.exposure)
        return .applied
    }

    /// Ends a task without reaching its intent.
    public mutating func abandon(_ id: TaskID, reason: AbandonReason, now: MonotonicInstant) -> LedgerResult {
        guard let task = open[id], let definition = definitions[task.kind] else { return reject(.unknownTask) }
        if let ended = endIfExpired(task, definition, now: now) { return .finished(ended) }
        return finished(id, as: .abandoned(reason), now: now)
    }

    /// The app moved to the background. Banks every open task's foreground time.
    public mutating func didEnterBackground(now: MonotonicInstant) -> [FinishedTask] {
        guard !inBackground else { return [] }
        inBackground = true
        var ended: [FinishedTask] = []
        for id in open.keys.sorted() {
            guard let task = open[id], let resumed = task.resumedAt else { continue }
            guard let stretch = now.nanos(since: resumed) else {
                if let done = finish(id, as: .interrupted, now: now) { ended.append(done) }
                continue
            }
            open[id]?.activeNanos = task.activeNanos.saturatingAdd(stretch)
            open[id]?.resumedAt = nil
            open[id]?.backgroundedAt = now
        }
        return ended
    }

    /// The app returned. Tasks away longer than their limit end as `.leftApp`.
    public mutating func willEnterForeground(now: MonotonicInstant) -> [FinishedTask] {
        guard inBackground else { return [] }
        inBackground = false
        var ended: [FinishedTask] = []
        for id in open.keys.sorted() {
            guard let task = open[id], let definition = definitions[task.kind] else { continue }
            guard let since = task.backgroundedAt, let gap = now.nanos(since: since) else {
                if let done = finish(id, as: .interrupted, now: now) { ended.append(done) }
                continue
            }
            if gap > definition.maxBackgroundNanos {
                if let done = finish(id, as: .abandoned(.leftApp), now: now) { ended.append(done) }
            } else {
                open[id]?.backgroundedAt = nil
                open[id]?.resumedAt = now
            }
        }
        return ended
    }

    /// Ends every task that has exceeded its active budget or whose clock
    /// readings became incomparable. Call periodically and before a flush.
    public mutating func sweep(now: MonotonicInstant) -> [FinishedTask] {
        var ended: [FinishedTask] = []
        for id in open.keys.sorted() {
            guard let task = open[id], let definition = definitions[task.kind] else { continue }
            if let done = endIfExpired(task, definition, now: now) { ended.append(done) }
        }
        return ended
    }

    // MARK: - Persistence

    public func snapshot() -> LedgerSnapshot {
        LedgerSnapshot(open: open.values.sorted { $0.id < $1.id }, nextID: nextID)
    }

    /// Restores open tasks from a previous process. Tasks whose readings are
    /// not comparable with `now` (any relaunch with `SystemTelemetryClock`)
    /// end as `.interrupted`: the SDK cannot know whether the user finished.
    ///
    /// Safe to call after `begin` has already been used in this process (state
    /// often loads asynchronously): a restored task whose id collides with a
    /// live one is given a fresh id rather than being skipped, so no task is
    /// ever silently lost.
    public mutating func restore(_ snapshot: LedgerSnapshot, now: MonotonicInstant) -> [FinishedTask] {
        nextID = max(nextID, snapshot.nextID)
        var ended: [FinishedTask] = []
        for original in snapshot.open {
            var task = original
            if open[task.id] != nil {
                task = task.withID(TaskID(nextID))
                nextID = nextID &+ 1
            }
            open[task.id] = task
            if task.startedAt.session != now.session || now.nanos(since: task.startedAt) == nil {
                if let done = finish(task.id, as: .interrupted, now: now) { ended.append(done) }
                continue
            }
            // Same session (an in-process hand-over): align the task with the
            // ledger's current foreground/background state.
            if inBackground, let resumed = task.resumedAt {
                let stretch = now.nanos(since: resumed) ?? 0
                open[task.id]?.activeNanos = task.activeNanos.saturatingAdd(stretch)
                open[task.id]?.resumedAt = nil
                open[task.id]?.backgroundedAt = now
            } else if !inBackground, task.resumedAt == nil {
                if let definition = definitions[task.kind], let since = task.backgroundedAt,
                   let gap = now.nanos(since: since), gap > definition.maxBackgroundNanos {
                    if let done = finish(task.id, as: .abandoned(.leftApp), now: now) { ended.append(done) }
                    continue
                }
                open[task.id]?.backgroundedAt = nil
                open[task.id]?.resumedAt = now
            }
        }
        // Anything over capacity after a restore is evicted oldest-first.
        while open.count > capacity, let oldest = open.keys.min() {
            if let done = finish(oldest, as: .abandoned(.evicted), now: now) { ended.append(done) }
        }
        return ended
    }

    // MARK: - Internals

    /// Foreground nanoseconds for `task` at `now`, or nil if not measurable.
    private func activeNanos(_ task: OpenTask, now: MonotonicInstant) -> UInt64? {
        guard now.nanos(since: task.startedAt) != nil else { return nil }
        guard let resumed = task.resumedAt else { return task.activeNanos }
        guard let stretch = now.nanos(since: resumed) else { return nil }
        return task.activeNanos.saturatingAdd(stretch)
    }

    private mutating func endIfExpired(_ task: OpenTask, _ definition: TaskDefinition, now: MonotonicInstant) -> FinishedTask? {
        guard let active = activeNanos(task, now: now) else { return finish(task.id, as: .interrupted, now: now) }
        if active > definition.activeBudgetNanos { return finish(task.id, as: .timedOut, now: now) }
        // An event arriving while the app is still in the background (e.g. a
        // background upload completing) must respect the background limit too.
        if let since = task.backgroundedAt {
            guard let gap = now.nanos(since: since) else { return finish(task.id, as: .interrupted, now: now) }
            if gap > definition.maxBackgroundNanos { return finish(task.id, as: .abandoned(.leftApp), now: now) }
        }
        return nil
    }

    private mutating func finished(_ id: TaskID, as outcome: TaskOutcome, now: MonotonicInstant) -> LedgerResult {
        guard let done = finish(id, as: outcome, now: now) else { return reject(.unknownTask) }
        return .finished(done)
    }

    private mutating func finish(_ id: TaskID, as outcome: TaskOutcome, now: MonotonicInstant) -> FinishedTask? {
        guard let task = open.removeValue(forKey: id) else { return nil }
        var finalOutcome = outcome
        var timeToIntent: UInt64?
        if case .completed = outcome {
            if let active = activeNanos(task, now: now) {
                timeToIntent = active
            } else {
                finalOutcome = .interrupted
            }
        }
        return FinishedTask(
            id: task.id, kind: task.kind, arm: arm, outcome: finalOutcome,
            exposure: task.exposure, timeToIntentNanos: timeToIntent,
            furthestStep: task.furthestStep, ai: task.ai, revisits: task.revisits
        )
    }

    @discardableResult
    private mutating func reject(_ reason: Rejection) -> LedgerResult {
        rejections[reason, default: 0] = rejections[reason, default: 0].saturatingAdd(1)
        return .rejected(reason)
    }
}
