import XCTest
@testable import OutcomeTelemetry

final class TaskLedgerTests: XCTestCase {
    private let s = SampleSchema.self
    private func at(_ seconds: Double, session: UInt64 = 1) -> MonotonicInstant {
        MonotonicInstant(session: session, nanos: nanoseconds(seconds))
    }
    private func ledger(_ arm: ExperimentArm = .treatment, capacity: Int = 32) -> TaskLedger {
        TaskLedger(definitions: SampleSchema.definitions, arm: arm, capacity: capacity)
    }
    private func finished(_ result: LedgerResult, file: StaticString = #filePath, line: UInt = #line) -> FinishedTask? {
        guard case let .finished(task) = result else {
            XCTFail("expected .finished, got \(result)", file: file, line: line)
            return nil
        }
        return task
    }

    func testCompletionRecordsForegroundTimeToIntent() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        XCTAssertEqual(l.record(step: s.openCapture, for: id, now: at(1)), .applied)
        XCTAssertEqual(l.record(step: s.scanReceipt, for: id, now: at(4)), .applied)
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(9))))
        XCTAssertEqual(task.outcome, .completed)
        XCTAssertEqual(task.timeToIntentNanos, nanoseconds(9))
        XCTAssertEqual(task.furthestStep, 3)
        XCTAssertEqual(l.openCount, 0)
    }

    func testBackgroundTimeIsNotCountedAsTimeToIntent() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        XCTAssertTrue(l.didEnterBackground(now: at(3)).isEmpty)
        XCTAssertTrue(l.didEnterBackground(now: at(10)).isEmpty, "a duplicate notification is ignored")
        XCTAssertTrue(l.willEnterForeground(now: at(63)).isEmpty, "60 s away is within the 300 s limit")
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(65))))
        XCTAssertEqual(task.timeToIntentNanos, nanoseconds(5), "3 s before + 2 s after; the 60 s away is excluded")
    }

    func testLongBackgroundGapAbandonsAsLeftApp() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        _ = l.didEnterBackground(now: at(1))
        let ended = l.willEnterForeground(now: at(302))
        XCTAssertEqual(ended.map(\.outcome), [.abandoned(.leftApp)])
        XCTAssertEqual(l.record(step: s.submit, for: id, now: at(303)), .rejected(.unknownTask))
    }

    func testTaskBegunInBackgroundStartsAccruingOnlyWhenForegrounded() throws {
        var l = ledger()
        _ = l.didEnterBackground(now: at(0))
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(1)).id)
        _ = l.willEnterForeground(now: at(50))
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(52))))
        XCTAssertEqual(task.timeToIntentNanos, nanoseconds(2))
    }

    func testActiveBudgetTimesOutAndTheLateEventIsNotApplied() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(90.5))))
        XCTAssertEqual(task.outcome, .timedOut, "reaching the intent after the budget is not a completion")
        XCTAssertNil(task.timeToIntentNanos)
        XCTAssertNil(task.furthestStep, "the late step was not applied")
    }

    func testSweepEndsExpiredTasksOnly() throws {
        var l = ledger()
        let old = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        let young = try XCTUnwrap(l.begin(s.captureExpense, now: at(80)).id)
        let ended = l.sweep(now: at(95))
        XCTAssertEqual(ended.map(\.id), [old])
        XCTAssertEqual(l.openTaskIDs, [young])
    }

    func testRevisitsDoNotMoveProgressBackwards() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        XCTAssertEqual(l.record(step: s.categorize, for: id, now: at(1)), .applied)
        XCTAssertEqual(l.record(step: s.scanReceipt, for: id, now: at(2)), .revisit)
        XCTAssertEqual(l.record(step: s.categorize, for: id, now: at(3)), .revisit)
        let task = try XCTUnwrap(finished(l.abandon(id, reason: .userCancelled, now: at(4))))
        XCTAssertEqual(task.furthestStep, 2)
        XCTAssertEqual(task.revisits, 2)
    }

    func testSchemaViolationsAreRejectedAndCounted() throws {
        var l = ledger()
        let unknown = try XCTUnwrap(TelemetryName("not-a-step"))
        XCTAssertNil(l.begin(unknown, now: at(0)).id)
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        XCTAssertEqual(l.record(step: unknown, for: id, now: at(1)), .rejected(.unknownStep))
        XCTAssertEqual(l.record(ai: .shown, feature: unknown, for: id, now: at(1)), .rejected(.unknownAIFeature))
        XCTAssertEqual(l.record(step: s.submit, for: TaskID(999), now: at(1)), .rejected(.unknownTask))
        XCTAssertEqual(l.rejections[.unknownKind], 1)
        XCTAssertEqual(l.rejections[.unknownStep], 1)
        XCTAssertEqual(l.rejections[.unknownAIFeature], 1)
        XCTAssertEqual(l.rejections[.unknownTask], 1)
        XCTAssertEqual(l.openCount, 1, "nothing about the real task changed")
    }

    func testTerminalStatesAreFinal() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        XCTAssertNotNil(finished(l.abandon(id, reason: .failed, now: at(1))))
        XCTAssertEqual(l.record(step: s.submit, for: id, now: at(2)), .rejected(.unknownTask))
        XCTAssertEqual(l.abandon(id, reason: .failed, now: at(2)), .rejected(.unknownTask))
        XCTAssertEqual(l.record(ai: .accepted, feature: s.autoCategory, for: id, now: at(2)), .rejected(.unknownTask))
    }

    func testAIEventsFromAHoldoutInstallAreAnIntegrityAlarm() throws {
        var l = ledger(.holdout)
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        XCTAssertEqual(l.record(ai: .shown, feature: s.autoCategory, for: id, now: at(1)), .rejected(.aiEventInHoldout))
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(2))))
        XCTAssertEqual(task.exposure, .none)
        XCTAssertEqual(task.ai, AICounts())
        XCTAssertEqual(l.rejections[.aiEventInHoldout], 1)
    }

    func testExposureIsTheStrongestEvent() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        for event in [AIEvent.shown, .accepted, .shown, .rejected] {
            XCTAssertEqual(l.record(ai: event, feature: s.autoCategory, for: id, now: at(1)), .applied)
        }
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(2))))
        XCTAssertEqual(task.exposure, .accepted, "a later rejection does not undo an acceptance")
        XCTAssertEqual(task.ai.shown, 2)
        XCTAssertEqual(task.ai.rejected, 1)
    }

    func testCapacityEvictsTheOldestTask() throws {
        var l = ledger(capacity: 2)
        let first = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        let second = try XCTUnwrap(l.begin(s.captureExpense, now: at(1)).id)
        let third = l.begin(s.captureExpense, now: at(2))
        XCTAssertEqual(third.evicted?.id, first)
        XCTAssertEqual(third.evicted?.outcome, .abandoned(.evicted))
        XCTAssertEqual(l.openTaskIDs, [second, try XCTUnwrap(third.id)])
        XCTAssertEqual(TaskLedger(definitions: [], arm: .holdout, capacity: -3).capacity, 1, "capacity is clamped, never zero")
    }

    func testRebootMidTaskEndsAsInterruptedWithoutADuration() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(10, session: 1)).id)
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(1, session: 2))))
        XCTAssertEqual(task.outcome, .interrupted, "a reboot is not a completion we can time")
        XCTAssertNil(task.timeToIntentNanos)
    }

    func testBackgroundAcrossARebootIsInterruptedNotLeftApp() throws {
        var l = ledger()
        _ = try XCTUnwrap(l.begin(s.captureExpense, now: at(0, session: 1)).id)
        _ = l.didEnterBackground(now: at(1, session: 1))
        XCTAssertEqual(l.willEnterForeground(now: at(2, session: 9)).map(\.outcome), [.interrupted])
    }

    func testRestoreAfterRelaunchInterruptsEveryOpenTask() throws {
        var before = ledger()
        let a = try XCTUnwrap(before.begin(s.captureExpense, now: at(0)).id)
        _ = before.record(step: s.scanReceipt, for: a, now: at(1))
        _ = before.begin(s.captureExpense, now: at(2))
        let data = try JSONEncoder().encode(before.snapshot())
        let snapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: data)

        var after = ledger()
        let ended = after.restore(snapshot, now: at(0, session: 2))
        XCTAssertEqual(ended.count, 2)
        XCTAssertTrue(ended.allSatisfy { $0.outcome == .interrupted })
        XCTAssertEqual(ended.first?.furthestStep, 1, "progress survives the relaunch")
        let next = try XCTUnwrap(after.begin(s.captureExpense, now: at(1, session: 2)).id)
        XCTAssertGreaterThan(next, a, "ids are not reused after a restore")
    }

    func testRestoreAfterBeginNeverDropsACollidingTask() throws {
        var before = ledger()
        let old = try XCTUnwrap(before.begin(s.captureExpense, now: at(0)).id)
        _ = before.record(step: s.categorize, for: old, now: at(1))
        let snapshot = before.snapshot()

        var after = ledger()
        // State loaded asynchronously: the app already began a task, which
        // received the same id the snapshot's task has.
        let live = try XCTUnwrap(after.begin(s.captureExpense, now: at(0, session: 2)).id)
        XCTAssertEqual(live, old)
        let ended = after.restore(snapshot, now: at(1, session: 2))
        XCTAssertEqual(ended.count, 1, "the restored task is finished, not skipped")
        XCTAssertNotEqual(ended.first?.id, live)
        XCTAssertEqual(ended.first?.furthestStep, 2)
        XCTAssertEqual(after.openTaskIDs, [live], "the live task is untouched")
    }

    func testSameSessionRestoreAppliesTheBackgroundLimit() throws {
        var before = ledger()
        _ = try XCTUnwrap(before.begin(s.captureExpense, now: at(0)).id)
        _ = before.didEnterBackground(now: at(1))
        let snapshot = before.snapshot()
        var after = ledger() // foregrounded
        let ended = after.restore(snapshot, now: at(400))
        XCTAssertEqual(ended.map(\.outcome), [.abandoned(.leftApp)])
        var fresh = ledger()
        XCTAssertTrue(fresh.restore(snapshot, now: at(100)).isEmpty, "within the limit it resumes")
        XCTAssertEqual(fresh.openCount, 1)
    }

    func testAStepRecordedWhileStillInBackgroundRespectsTheBackgroundLimit() throws {
        var l = ledger()
        let id = try XCTUnwrap(l.begin(s.captureExpense, now: at(0)).id)
        _ = l.didEnterBackground(now: at(1))
        let task = try XCTUnwrap(finished(l.record(step: s.submit, for: id, now: at(400))))
        XCTAssertEqual(task.outcome, .abandoned(.leftApp), "399 s away exceeds the 300 s limit")
        let other = try XCTUnwrap(l.begin(s.captureExpense, now: at(401)).id)
        let quick = try XCTUnwrap(finished(l.record(step: s.submit, for: other, now: at(420))))
        XCTAssertEqual(quick.outcome, .completed, "a task begun in the background can finish within the limit")
        XCTAssertEqual(quick.timeToIntentNanos, 0, "no foreground time elapsed")
    }
}
