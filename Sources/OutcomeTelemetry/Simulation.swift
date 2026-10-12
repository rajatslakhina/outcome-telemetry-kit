// A deterministic fleet simulator — a test and demo fixture, not production
// code. It drives real `OutcomeRecorder`s (one per simulated install, each
// with its own clock) against a shared `InMemoryCollector`, so everything the
// demo shows went through the same ledger, gate, journal and transport an
// app would use.
//
// The behaviour model is built to reproduce the trap the report warns about.
// Each task has a hidden difficulty. Hard receipts make the AI suggestion
// less likely to be accepted *and* make the user more likely to give up,
// whatever the AI does. So "tasks that used the suggestion" look far better
// than the feature really is, and only the arm comparison recovers the true
// effect. The numbers are invented for the demo; the mechanism is the point.

/// SplitMix64: small, fast, seedable, identical on every platform.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
    public mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
}

/// The reference schema used by the tests, the simulator and the demo.
public enum SampleSchema {
    // Compile-time literals. `TelemetryName(validated:)` skips the failable
    // check (and asserts it in debug builds); a test also asserts every
    // literal here passes `TelemetryName.isValid`.
    public static let captureExpense = TelemetryName(validated: "capture-expense")
    public static let openCapture = TelemetryName(validated: "open-capture")
    public static let scanReceipt = TelemetryName(validated: "scan-receipt")
    public static let categorize = TelemetryName(validated: "categorize")
    public static let submit = TelemetryName(validated: "submit")
    public static let autoCategory = TelemetryName(validated: "auto-category")

    /// Capture an expense: open → scan → categorise → submit (intent).
    /// 90 s of foreground budget; 5 minutes away ends the task.
    public static var definitions: [TaskDefinition] {
        let definition = TaskDefinition(
            kind: captureExpense,
            steps: [openCapture, scanReceipt, categorize, submit],
            activeBudgetSeconds: 90,
            maxBackgroundSeconds: 300,
            aiFeatures: [autoCategory]
        )
        return definition.map { [$0] } ?? []
    }
}

/// Deterministic batch ids for simulations and tests ("<prefix>-1", "-2", …).
public final class SequentialIDs: @unchecked Sendable {
    // @unchecked: `next` is guarded by `lock`.
    private let lock = Lock()
    private let prefix: String
    private var next: UInt64 = 0

    public init(prefix: String) { self.prefix = prefix }

    public func make() -> String {
        lock.withLock {
            next = next &+ 1
            return "\(prefix)-\(next)"
        }
    }
}

/// The outcome of a fleet run.
public struct FleetResult: Sendable {
    public let installs: Int
    public let treatmentInstalls: Int
    public let finishedTasks: UInt64
    public let conservedInstalls: Int
    /// Per-install (completed, known-outcome) counts, as a server holding
    /// install-level data would see them. Used to estimate the design effect.
    public let perInstall: [InstallOutcome]
    /// `DesignEffect.estimate(perInstall)`.
    public let designEffect: Double
}

/// How one simulated person behaves. Installs differ — some people give up
/// more easily, some photograph harder receipts — which is what makes tasks
/// from one install correlated and the design effect greater than 1.
public struct UserProfile: Hashable, Sendable {
    public var giveUpScale: Double
    public var hardShare: Double

    public init(giveUpScale: Double = 1, hardShare: Double = 0.35) {
        self.giveUpScale = giveUpScale
        self.hardShare = hardShare
    }

    public static func random(_ rng: inout SplitMix64) -> UserProfile {
        UserProfile(giveUpScale: rng.uniform(0.4, 1.9), hardShare: rng.uniform(0.15, 0.55))
    }
}

public enum FleetSimulator {
    /// Simulates `installs` installs, each doing `tasksPerInstall` expense
    /// captures, then sealing and draining to `collector`.
    public static func run(
        installs: Int,
        tasksPerInstall: Int,
        seed: UInt64,
        cohorts: CohortAssigner,
        gate: PrivacyGate,
        collector: InMemoryCollector
    ) async -> FleetResult {
        var rng = SplitMix64(seed: seed)
        var treatmentInstalls = 0
        var finished: UInt64 = 0
        var conserved = 0
        var perInstall: [InstallOutcome] = []
        let configuration = OutcomeConfiguration(
            definitions: SampleSchema.definitions, cohorts: cohorts, gate: gate,
            minTasksPerBatch: 1_000, maxBatchAgeSeconds: 86_400
        )
        for install in 0 ..< max(0, installs) {
            let clock = ManualClock(session: rng.next() | 1)
            let ids = SequentialIDs(prefix: "batch-\(seed)-\(install)")
            let recorder = OutcomeRecorder(
                configuration: configuration,
                installID: "install-\(seed)-\(install)",
                clock: clock,
                transport: collector,
                makeBatchID: { ids.make() },
                jitter: { 0.5 }
            )
            if recorder.aiEnabled { treatmentInstalls += 1 }
            let profile = UserProfile.random(&rng)
            var outcome = InstallOutcome(arm: recorder.arm, completed: 0, known: 0)
            for _ in 0 ..< max(0, tasksPerInstall) {
                let result = await simulateTask(recorder: recorder, clock: clock, aiEnabled: recorder.aiEnabled, profile: profile, rng: &rng)
                outcome.record(result)
            }
            perInstall.append(outcome)
            await recorder.seal()
            for _ in 0 ..< 8 {
                if case .nothingToSend = await recorder.flush() { break }
                clock.advance(seconds: 600)
            }
            let health = await recorder.health()
            finished = finished.saturatingAdd(health.finishedTasks)
            if health.isConserved { conserved += 1 }
        }
        return FleetResult(
            installs: max(0, installs), treatmentInstalls: treatmentInstalls, finishedTasks: finished,
            conservedInstalls: conserved, perInstall: perInstall, designEffect: DesignEffect.estimate(perInstall)
        )
    }

    /// One expense capture with the behaviour model described above. Returns
    /// how the task ended, as the ledger decided it.
    @discardableResult
    public static func simulateTask(
        recorder: OutcomeRecorder,
        clock: ManualClock,
        aiEnabled: Bool,
        profile: UserProfile = UserProfile(),
        rng: inout SplitMix64
    ) async -> TaskOutcome? {
        let s = SampleSchema.self
        guard let id = await recorder.begin(s.captureExpense) else { return nil }
        let hard = rng.chance(profile.hardShare)
        await recorder.record(step: s.openCapture, for: id)
        clock.advance(seconds: rng.uniform(0.5, 1.5))
        if rng.chance(0.04) {
            return outcome(of: await recorder.abandon(id, reason: .userCancelled))
        }
        clock.advance(seconds: rng.uniform(2, 4))
        await recorder.record(step: s.scanReceipt, for: id)

        // Occasionally the user leaves mid-task: a short trip or a long one.
        if rng.chance(0.08) {
            await recorder.didEnterBackground()
            let longTrip = rng.chance(0.5)
            clock.advance(seconds: longTrip ? rng.uniform(400, 900) : rng.uniform(10, 60))
            await recorder.willEnterForeground()
            // Longer than the definition's 300 s limit: the ledger has already
            // ended the task as `.abandoned(.leftApp)`, and the user is gone.
            if longTrip { return .abandoned(.leftApp) }
        }

        var categorizeSeconds = hard ? rng.uniform(9, 20) : rng.uniform(5, 11)
        var giveUp = (hard ? 0.30 : 0.10) * profile.giveUpScale
        if aiEnabled {
            await recorder.record(ai: .shown, feature: s.autoCategory, for: id)
            let accept = hard ? 0.25 : 0.70
            let edit = hard ? 0.20 : 0.15
            let roll = rng.unit()
            if roll < accept {
                await recorder.record(ai: .accepted, feature: s.autoCategory, for: id)
                categorizeSeconds = rng.uniform(0.8, 2)
                giveUp *= 0.45
            } else if roll < accept + edit {
                await recorder.record(ai: .edited, feature: s.autoCategory, for: id)
                categorizeSeconds = rng.uniform(3, 6)
                giveUp *= 0.7
            } else {
                await recorder.record(ai: .rejected, feature: s.autoCategory, for: id)
                categorizeSeconds += 1.5 // reading a wrong suggestion costs time
                giveUp *= 1.05
            }
        }
        clock.advance(seconds: categorizeSeconds)
        await recorder.record(step: s.categorize, for: id)
        if rng.chance(min(giveUp, 0.95)) {
            return outcome(of: await recorder.abandon(id, reason: rng.chance(0.8) ? .userCancelled : .failed))
        }
        clock.advance(seconds: rng.uniform(0.8, 2.5))
        let result = await recorder.record(step: s.submit, for: id)
        await recorder.tick()
        return outcome(of: result)
    }

    private static func outcome(of result: LedgerResult) -> TaskOutcome? {
        if case let .finished(task) = result { return task.outcome }
        return nil
    }
}
