import Foundation
import XCTest
@testable import OutcomeTelemetry

final class JournalTests: XCTestCase {
    private func batch(_ id: String, tasks: Int, seed: UInt64 = 1) -> UploadBatch {
        var rng = SplitMix64(seed: seed)
        return UploadBatch(id: id, table: Fixtures.table(&rng, tasks: tasks))
    }

    func testBackPressureCoalescesInsteadOfDropping() {
        var journal = OutcomeJournal(capacity: 3, maxAttempts: 5)
        var total: UInt64 = 0
        for i in 0 ..< 50 {
            let b = batch("b\(i)", tasks: 1 + i % 4, seed: UInt64(i))
            total += b.taskCount
            journal.append(b)
            XCTAssertLessThanOrEqual(journal.pending.count, journal.capacity + 1)
        }
        XCTAssertEqual(journal.pending.count, 3)
        XCTAssertEqual(journal.pendingTasks, total, "a week offline loses nothing to the bound")
        XCTAssertEqual(journal.coalescedSeals, 47)
    }

    func testAnAttemptedBatchIsFrozenForever() throws {
        var journal = OutcomeJournal(capacity: 1, maxAttempts: 5)
        journal.append(batch("first", tasks: 3))
        let inFlight = try XCTUnwrap(journal.beginAttempt())
        XCTAssertTrue(inFlight.isFrozen)
        // Queue is full and its only batch is frozen: the new batch must be
        // appended, not merged into the one the server may already have.
        journal.append(batch("second", tasks: 2, seed: 2))
        XCTAssertEqual(journal.pending.map(\.id), ["first", "second"])
        XCTAssertEqual(journal.pending.first, inFlight, "content under the idempotency key is unchanged")
        // A third coalesces into "second", the newest unfrozen batch.
        journal.append(batch("third", tasks: 4, seed: 3))
        XCTAssertEqual(journal.pending.map(\.id), ["first", "second"])
        XCTAssertEqual(journal.pending.last?.seals, 2)
        XCTAssertEqual(journal.pending.count, journal.capacity + 1, "the documented bound is tight")
    }

    func testCoalesceRefusesAFrozenBatch() {
        var frozen = batch("f", tasks: 2)
        frozen.attempts = 1
        let before = frozen
        XCTAssertFalse(frozen.coalesce(batch("x", tasks: 3, seed: 9)))
        XCTAssertEqual(frozen, before)
    }

    func testAcknowledgeAndFailFindTheBatchByID() throws {
        var journal = OutcomeJournal(capacity: 4, maxAttempts: 2)
        journal.append(batch("a", tasks: 2))
        journal.append(batch("b", tasks: 3, seed: 2))
        let a = try XCTUnwrap(journal.beginAttempt())
        journal.acknowledge(id: "does-not-exist")
        XCTAssertEqual(journal.pending.count, 2)
        journal.acknowledge(id: a.id)
        XCTAssertEqual(journal.pending.map(\.id), ["b"])
        XCTAssertEqual(journal.ackedTasks, a.taskCount)

        _ = journal.beginAttempt()
        XCTAssertFalse(journal.fail(id: "b", permanent: false), "1 of 2 attempts used")
        _ = journal.beginAttempt()
        XCTAssertTrue(journal.fail(id: "b", permanent: false), "attempt budget exhausted")
        XCTAssertTrue(journal.pending.isEmpty)
        XCTAssertGreaterThan(journal.deadLetteredTasks, 0)
    }

    func testEmptyBatchesAreNotQueued() {
        var journal = OutcomeJournal(capacity: 2, maxAttempts: 2)
        journal.append(UploadBatch(id: "e", table: AggregateTable()))
        XCTAssertTrue(journal.pending.isEmpty)
        XCTAssertNil(journal.beginAttempt())
    }

    func testRetryDelayIsBoundedForAnyInput() {
        let policy = RetryPolicy(baseSeconds: 2, capSeconds: 60)
        XCTAssertEqual(policy.delay(afterAttempt: 1, unit: 1), nanoseconds(2))
        XCTAssertEqual(policy.delay(afterAttempt: 3, unit: 1), nanoseconds(8))
        XCTAssertEqual(policy.delay(afterAttempt: 100, unit: 1), nanoseconds(60))
        XCTAssertEqual(policy.delay(afterAttempt: Int.max, unit: 1), nanoseconds(60))
        XCTAssertEqual(policy.delay(afterAttempt: Int.min, unit: 1), nanoseconds(2))
        XCTAssertEqual(policy.delay(afterAttempt: 3, unit: .nan), 0)
        XCTAssertEqual(policy.delay(afterAttempt: 3, unit: 9), nanoseconds(8))
        XCTAssertEqual(policy.delay(afterAttempt: 3, unit: 0.5), nanoseconds(4))
        let weird = RetryPolicy(baseSeconds: .nan, capSeconds: -1)
        XCTAssertLessThanOrEqual(weird.delay(afterAttempt: 10, unit: 1), weird.capNanos)
    }
}
