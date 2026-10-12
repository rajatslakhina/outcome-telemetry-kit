import Foundation
import XCTest
@testable import OutcomeTelemetry

/// A transport that suspends inside `send` until the test releases it, so a
/// test can run other recorder calls *during* the await (actor reentrancy).
actor PausingTransport: OutcomeTransport {
    private(set) var received: [UploadBatch] = []
    private var pending: CheckedContinuation<TransportResult, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ batch: UploadBatch) async -> TransportResult {
        received.append(batch)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { pending = $0 }
    }

    func waitUntilSending() async {
        if pending != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ result: TransportResult) {
        pending?.resume(returning: result)
        pending = nil
    }
}

final class RecorderTests: XCTestCase {
    private let s = SampleSchema.self

    /// An install id that lands in the requested arm under `cohorts`.
    private func install(in arm: ExperimentArm, _ cohorts: CohortAssigner) -> String {
        (0 ..< 10_000).lazy.map { "install-\($0)" }.first { cohorts.arm(forInstall: $0) == arm } ?? "none"
    }

    private func makeRecorder(
        transport: any OutcomeTransport,
        clock: ManualClock,
        arm: ExperimentArm = .treatment,
        gate: PrivacyGate = PrivacyGate(k: 1, maxCarries: 0),
        minTasks: Int = 1_000,
        capacity: Int = 8,
        maxAttempts: Int = 6,
        jitter: Double = 1
    ) -> OutcomeRecorder {
        let cohorts = CohortAssigner(treatmentPerMille: 500, salt: "test")
        let config = OutcomeConfiguration(
            definitions: SampleSchema.definitions, cohorts: cohorts, gate: gate,
            minTasksPerBatch: minTasks, maxBatchAgeSeconds: 600,
            journalCapacity: capacity, maxAttempts: maxAttempts,
            retry: RetryPolicy(baseSeconds: 2, capSeconds: 60)
        )
        let ids = SequentialIDs(prefix: "t")
        return OutcomeRecorder(configuration: config, installID: install(in: arm, cohorts), clock: clock,
                               transport: transport, makeBatchID: { ids.make() }, jitter: { jitter })
    }

    private func complete(_ n: Int, on recorder: OutcomeRecorder, clock: ManualClock) async {
        for _ in 0 ..< n {
            guard let id = await recorder.begin(s.captureExpense) else { return XCTFail("begin failed") }
            clock.advance(seconds: 3)
            await recorder.record(step: s.submit, for: id)
        }
    }

    func testEndToEndDeliveryCountsEachTaskOnce() async {
        let collector = InMemoryCollector()
        let clock = ManualClock()
        let recorder = makeRecorder(transport: collector, clock: clock)
        await complete(7, on: recorder, clock: clock)
        await recorder.seal()
        let result = await recorder.flush()
        XCTAssertEqual(result, .sent(batchID: "t-1", tasks: 7))
        let health = await recorder.health()
        XCTAssertTrue(health.isConserved)
        XCTAssertEqual(health.ackedTasks, 7)
        let serverTasks = await collector.taskCount
        XCTAssertEqual(serverTasks, 7)
    }

    func testLostAcksAreDedupedByTheServer() async {
        let collector = InMemoryCollector(mode: .lostAcks)
        let clock = ManualClock()
        let recorder = makeRecorder(transport: collector, clock: clock)
        await complete(4, on: recorder, clock: clock)
        await recorder.seal()
        for _ in 0 ..< 3 {
            _ = await recorder.flush()
            clock.advance(seconds: 120)
        }
        await collector.setMode(.healthy)
        _ = await recorder.flush()
        let duplicates = await collector.duplicateSends
        let serverTasks = await collector.taskCount
        let health = await recorder.health()
        XCTAssertEqual(duplicates, 3, "the same batch arrived 4 times")
        XCTAssertEqual(serverTasks, 4, "…and was counted once")
        XCTAssertEqual(health.ackedTasks, 4)
    }

    func testRetryBacksOffAndARelaunchClearsTheBackoff() async {
        let collector = InMemoryCollector(mode: .offline)
        let clock = ManualClock(session: 1)
        let recorder = makeRecorder(transport: collector, clock: clock)
        await complete(2, on: recorder, clock: clock)
        await recorder.seal()
        let first = await recorder.flush()
        XCTAssertEqual(first, .willRetry(batchID: "t-1", attempt: 1, delayNanos: nanoseconds(2)))
        clock.advance(seconds: 1)
        let second = await recorder.flush()
        XCTAssertEqual(second, .backingOff(remainingNanos: nanoseconds(1)))
        clock.advance(seconds: 1)
        let third = await recorder.flush()
        XCTAssertEqual(third, .willRetry(batchID: "t-1", attempt: 2, delayNanos: nanoseconds(4)))
        clock.reboot(session: 2)
        await collector.setMode(.healthy)
        let fourth = await recorder.flush()
        XCTAssertEqual(fourth, .sent(batchID: "t-1", tasks: 2))
    }

    func testPermanentRejectionAndExhaustedRetriesDeadLetterWithAccounting() async {
        let collector = InMemoryCollector(mode: .rejecting)
        let clock = ManualClock()
        let recorder = makeRecorder(transport: collector, clock: clock, maxAttempts: 2)
        await complete(3, on: recorder, clock: clock)
        await recorder.seal()
        let rejected = await recorder.flush()
        XCTAssertEqual(rejected, .deadLettered(batchID: "t-1", tasks: 3))

        await collector.setMode(.offline)
        await complete(2, on: recorder, clock: clock)
        await recorder.seal()
        _ = await recorder.flush()
        clock.advance(seconds: 100)
        let exhausted = await recorder.flush()
        XCTAssertEqual(exhausted, .deadLettered(batchID: "t-2", tasks: 2))
        let health = await recorder.health()
        XCTAssertEqual(health.deadLetteredTasks, 5)
        XCTAssertTrue(health.isConserved)
    }

    func testFlushIsReentrancySafe() async {
        let transport = PausingTransport()
        let clock = ManualClock()
        let recorder = makeRecorder(transport: transport, clock: clock, capacity: 1)
        await complete(5, on: recorder, clock: clock)
        await recorder.seal()

        let inFlight = Task { await recorder.flush() }
        await transport.waitUntilSending()

        // While the first send is suspended, the actor keeps serving calls.
        let concurrent = await recorder.flush()
        XCTAssertEqual(concurrent, .alreadyFlushing)
        await complete(3, on: recorder, clock: clock)
        await recorder.seal()           // queue is full of a frozen batch → appended
        await complete(4, on: recorder, clock: clock)
        await recorder.seal()           // → coalesced into the unfrozen one
        var health = await recorder.health()
        XCTAssertEqual(health.pendingBatches, 2)
        XCTAssertEqual(health.frozenBatches, 1)
        XCTAssertEqual(health.coalescedSeals, 1)

        await transport.release(.accepted)
        let result = await inFlight.value
        XCTAssertEqual(result, .sent(batchID: "t-1", tasks: 5), "the in-flight batch did not change under its key")
        let received = await transport.received
        XCTAssertEqual(received.first?.taskCount, 5)

        health = await recorder.health()
        XCTAssertEqual(health.pendingBatches, 1, "settled by id: the right batch was removed")
        XCTAssertEqual(health.pendingTasks, 7)
        XCTAssertEqual(health.ackedTasks, 5)
        XCTAssertTrue(health.isConserved)
    }

    func testConservationHoldsUnderRandomEventsAndFaults() async {
        for seed in UInt64(1) ... 6 {
            var rng = SplitMix64(seed: seed)
            let collector = InMemoryCollector()
            let clock = ManualClock()
            let recorder = makeRecorder(transport: collector, clock: clock, gate: PrivacyGate(k: 3, maxCarries: 2),
                                        minTasks: 5, capacity: 2, maxAttempts: 1_000, jitter: rng.unit())
            var open: [TaskID] = []
            for _ in 0 ..< 400 {
                switch rng.next() % 12 {
                case 0, 1, 2:
                    if let id = await recorder.begin(s.captureExpense) { open.append(id) }
                case 3, 4:
                    if let id = open.randomElement(using: &rng) {
                        await recorder.record(step: [s.openCapture, s.scanReceipt, s.categorize, s.submit].randomElement(using: &rng) ?? s.submit, for: id)
                    }
                case 5:
                    if let id = open.randomElement(using: &rng) {
                        await recorder.record(ai: AIEvent.allCases.randomElement(using: &rng) ?? .shown, feature: s.autoCategory, for: id)
                    }
                case 6:
                    if let id = open.popLast() { await recorder.abandon(id, reason: .userCancelled) }
                case 7:
                    if rng.chance(0.5) { await recorder.didEnterBackground() } else { await recorder.willEnterForeground() }
                case 8:
                    await recorder.tick()
                case 9:
                    await collector.setMode(InMemoryCollector.Mode.allCases.filter { $0 != .rejecting }.randomElement(using: &rng) ?? .healthy)
                case 10:
                    _ = await recorder.flush()
                default:
                    clock.advance(seconds: rng.uniform(0, 40))
                }
                let health = await recorder.health()
                XCTAssertTrue(health.isConserved, "seed \(seed): \(health)")
                if !health.isConserved { return }
            }
            // Drain: everything finished must reach the server exactly once.
            await recorder.willEnterForeground()
            for id in open { await recorder.abandon(id, reason: .userCancelled) }
            await collector.setMode(.healthy)
            for _ in 0 ..< 6 { await recorder.seal() } // walks carried rows to publish-or-suppress
            await recorder.resetBackoff()
            for _ in 0 ..< 50 { _ = await recorder.flush() }
            let health = await recorder.health()
            let serverTasks = await collector.taskCount
            XCTAssertEqual(health.deadLetteredTasks, 0)
            XCTAssertEqual(health.pendingTasks + health.accumulatingTasks + health.carriedTasks, 0, "seed \(seed): drained")
            XCTAssertEqual(health.ackedTasks, health.finishedTasks, "seed \(seed)")
            XCTAssertEqual(serverTasks, health.finishedTasks, "seed \(seed): exactly once at the server")
        }
    }

    func testDeadLetteringAfterLostAcksIsBoundedNotHidden() async {
        // A batch whose ack was lost and which then runs out of attempts may
        // or may not be on the server. The guarantee is a bound, not equality.
        let collector = InMemoryCollector(mode: .lostAcks)
        let clock = ManualClock()
        let recorder = makeRecorder(transport: collector, clock: clock, maxAttempts: 2)
        await complete(6, on: recorder, clock: clock)
        await recorder.seal()
        _ = await recorder.flush()
        clock.advance(seconds: 100)
        _ = await recorder.flush()
        let health = await recorder.health()
        let server = await collector.taskCount
        XCTAssertEqual(health.deadLetteredTasks, 6)
        XCTAssertGreaterThanOrEqual(server, health.ackedTasks)
        XCTAssertLessThanOrEqual(server, health.ackedTasks + health.deadLetteredTasks)
    }

    func testStateSurvivesAProcessKill() async throws {
        // Lost acks: the server applies the pre-kill attempt but the client
        // never hears back, so the batch the client holds is one the server
        // already has. Restoring it under any other id would double-count.
        let server = InMemoryCollector(mode: .lostAcks)
        let clock = ManualClock(session: 1)
        let config = OutcomeConfiguration(
            definitions: SampleSchema.definitions, cohorts: CohortAssigner(treatmentPerMille: 1_000, salt: "x"),
            gate: PrivacyGate(k: 3, maxCarries: 3), minTasksPerBatch: 1_000, journalCapacity: 4, maxAttempts: 6
        )
        let first = OutcomeRecorder(configuration: config, installID: "a", clock: clock, transport: server,
                                    makeBatchID: SequentialIDs(prefix: "p1").make, jitter: { 1 })
        await complete(4, on: first, clock: clock)
        await first.seal()                         // 4 tasks queued
        _ = await first.flush()                    // applied server-side, ack lost: frozen
        await complete(2, on: first, clock: clock)
        await first.seal()                         // 2 < k: carried
        await complete(1, on: first, clock: clock) // accumulating
        await server.setMode(.offline)
        _ = await first.begin(s.captureExpense)    // open
        let before = await first.health()
        XCTAssertEqual(before.finishedTasks, 7)
        XCTAssertEqual(before.frozenBatches, 1)
        XCTAssertEqual(before.carriedTasks, 2)

        let data = try JSONEncoder().encode(await first.persistentState())
        let state = try JSONDecoder().decode(OutcomeRecorder.PersistentState.self, from: data)

        // The process dies. A new one starts with a new clock session.
        clock.reboot(session: 2)
        await server.setMode(.healthy)
        // The new release also changed the retry policy; it must apply.
        var upgraded = config
        upgraded.maxAttempts = 2
        upgraded.journalCapacity = 9
        let second = OutcomeRecorder(configuration: upgraded, installID: "a", clock: clock, transport: server,
                                     makeBatchID: SequentialIDs(prefix: "p2").make, jitter: { 1 }, restoring: state)
        let restored = await second.persistentState()
        XCTAssertEqual(restored.journal.pending.first?.id, "p1-1", "same idempotency key after the kill")
        XCTAssertEqual(restored.journal.pending.first?.attempts, 1)
        XCTAssertEqual(restored.journal.maxAttempts, 2, "policy comes from the running release, not from disk")
        XCTAssertEqual(restored.journal.capacity, 9)
        var after = await second.health()
        XCTAssertEqual(after.finishedTasks, 8, "the open task ended as interrupted, and counts")
        XCTAssertEqual(after.frozenBatches, 1, "a batch the server may hold keeps its id and content")
        XCTAssertTrue(after.isConserved)

        for _ in 0 ..< 5 { await second.seal() }
        for _ in 0 ..< 10 { _ = await second.flush() }
        after = await second.health()
        let serverTasks = await server.taskCount
        XCTAssertEqual(after.ackedTasks, 8)
        XCTAssertEqual(serverTasks, 8, "nothing lost or double-counted across the kill")
        let duplicates = await server.duplicateSends
        XCTAssertEqual(duplicates, 1, "the frozen batch was resent under its original id and deduped")
        let received = await server.table
        let reduced = await server.outcomeOnly
        let interrupted = received.rows.values.reduce(UInt64(0)) { $0 + $1.outcomes.interrupted }
            + reduced.values.reduce(UInt64(0)) { $0 + $1.interrupted }
        XCTAssertEqual(interrupted, 1, "the task open at the kill arrives as interrupted")
    }

    func testConservationCheckDetectsAMissingTask() {
        var health = PipelineHealth(arm: .treatment, openTasks: 0, finishedTasks: 10, accumulatingTasks: 2, carriedTasks: 1,
                                    pendingTasks: 3, pendingBatches: 1, frozenBatches: 0, ackedTasks: 4, ackedBatches: 1,
                                    deadLetteredTasks: 0, coalescedSeals: 0, outcomeOnlyTasks: 0, rejections: [:], lastFlush: nil)
        XCTAssertTrue(health.isConserved)
        health.ackedTasks = 3
        XCTAssertFalse(health.isConserved, "one task lost between stages must be visible")
    }

    func testSealIsDueByCountOrAge() async {
        let collector = InMemoryCollector()
        let clock = ManualClock()
        let recorder = makeRecorder(transport: collector, clock: clock, minTasks: 3)
        await complete(2, on: recorder, clock: clock)
        await recorder.tick()
        var health = await recorder.health()
        XCTAssertEqual(health.accumulatingTasks, 2, "2 < 3 and young: not sealed")
        clock.advance(seconds: 601)
        await recorder.tick()
        health = await recorder.health()
        XCTAssertEqual(health.pendingTasks, 2, "sealed by age")
        await complete(3, on: recorder, clock: clock)
        await recorder.tick()
        health = await recorder.health()
        XCTAssertEqual(health.pendingTasks, 5, "sealed by count")
    }

    func testBackgroundingSealsAndHoldoutInstallsRejectAI() async {
        let collector = InMemoryCollector()
        let clock = ManualClock()
        let recorder = makeRecorder(transport: collector, clock: clock, arm: .holdout)
        XCTAssertFalse(recorder.aiEnabled)
        guard let id = await recorder.begin(s.captureExpense) else { return XCTFail() }
        let ai = await recorder.record(ai: .shown, feature: s.autoCategory, for: id)
        XCTAssertEqual(ai, .rejected(.aiEventInHoldout))
        await recorder.record(step: s.submit, for: id)
        await recorder.didEnterBackground()
        let health = await recorder.health()
        XCTAssertEqual(health.pendingTasks, 1)
        XCTAssertEqual(health.rejections[.aiEventInHoldout], 1)
    }
}

/// A durable store stand-in: the last state saved, as the next launch reads it.
actor StateStore {
    private(set) var saved: Data?
    private(set) var saves = 0
    var failNext = false

    func save(_ state: OutcomeRecorder.PersistentState) -> Bool {
        if failNext { failNext = false; return false }
        saved = try? JSONEncoder().encode(state)
        saves += 1
        return saved != nil
    }

    func setFailNext() { failNext = true }

    func load() -> OutcomeRecorder.PersistentState? {
        saved.flatMap { try? JSONDecoder().decode(OutcomeRecorder.PersistentState.self, from: $0) }
    }
}

final class CrashConsistencyTests: XCTestCase {
    private let s = SampleSchema.self
    private let config = OutcomeConfiguration(
        definitions: SampleSchema.definitions, cohorts: CohortAssigner(treatmentPerMille: 1_000, salt: "x"),
        gate: PrivacyGate(k: 1, maxCarries: 0), minTasksPerBatch: 3
    )

    /// complete 3 → save → tick seals → flush (server accepts) → crash →
    /// restore the last save → seal + flush. Returns (finished, server count).
    private func crashAfterAcceptedSend(writeAhead: Bool) async throws -> (UInt64, UInt64) {
        let server = InMemoryCollector()
        let store = StateStore()
        let clock = ManualClock(session: 1)
        let hook: (@Sendable (OutcomeRecorder.PersistentState) async -> Bool)? = writeAhead ? { @Sendable state in await store.save(state) } : nil
        let first = OutcomeRecorder(configuration: config, installID: "a", clock: clock, transport: server,
                                    writeAhead: hook)
        for _ in 0 ..< 3 {
            let began = await first.begin(s.captureExpense)
            let id = try XCTUnwrap(began)
            clock.advance(seconds: 2)
            await first.record(step: s.submit, for: id)
        }
        _ = await store.save(await first.persistentState())   // the app's own save
        let sealed = await first.tick()
        XCTAssertTrue(sealed)
        let sent = await first.flush()
        guard case .sent = sent else { XCTFail("expected a send, got \(sent)"); return (0, 0) }
        // Crash: nothing after this point is saved.
        clock.reboot(session: 2)
        let loaded = await store.load()
        let state = try XCTUnwrap(loaded)
        let second = OutcomeRecorder(configuration: config, installID: "a", clock: clock, transport: server, restoring: state)
        await second.seal()
        for _ in 0 ..< 4 { _ = await second.flush() }
        let finished = await second.health().finishedTasks
        return (finished, await server.taskCount)
    }

    func testWriteAheadMakesACrashAfterSendExactlyOnce() async throws {
        let (finished, server) = try await crashAfterAcceptedSend(writeAhead: true)
        XCTAssertEqual(finished, 3)
        XCTAssertEqual(server, 3, "the restored batch kept its id and was deduped")
    }

    func testWithoutWriteAheadTheSameCrashDoubleCounts() async throws {
        // Documents the hazard the hook exists for; if this ever stops
        // double-counting, the README's explanation is wrong.
        let (finished, server) = try await crashAfterAcceptedSend(writeAhead: false)
        XCTAssertEqual(finished, 3)
        XCTAssertEqual(server, 6)
    }

    func testAFailedWriteAheadSendsNothing() async throws {
        let server = InMemoryCollector()
        let store = StateStore()
        let clock = ManualClock()
        let recorder = OutcomeRecorder(configuration: config, installID: "a", clock: clock, transport: server,
                                       makeBatchID: SequentialIDs(prefix: "w").make, writeAhead: { await store.save($0) })
        let began = await recorder.begin(s.captureExpense)
        let id = try XCTUnwrap(began)
        await recorder.record(step: s.submit, for: id)
        await recorder.seal()
        await store.setFailNext()
        let failed = await recorder.flush()
        XCTAssertEqual(failed, .writeAheadFailed(batchID: "w-1"))
        let applied = await server.appliedBatches
        XCTAssertEqual(applied, 0)
        let retried = await recorder.flush()
        XCTAssertEqual(retried, .sent(batchID: "w-1", tasks: 1))
        let saves = await store.saves
        XCTAssertEqual(saves, 1)
    }
}
