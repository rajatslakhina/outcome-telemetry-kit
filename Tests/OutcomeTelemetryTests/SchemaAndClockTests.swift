import Foundation
import XCTest
@testable import OutcomeTelemetry

final class SchemaAndClockTests: XCTestCase {
    func testNameGrammar() {
        XCTAssertNotNil(TelemetryName("capture-expense"))
        XCTAssertNotNil(TelemetryName("a"))
        XCTAssertNotNil(TelemetryName("step_2"))
        XCTAssertNil(TelemetryName(""))
        XCTAssertNil(TelemetryName("2fa"), "must start with a letter")
        XCTAssertNil(TelemetryName("Capture"), "uppercase rejected")
        XCTAssertNil(TelemetryName("user@example.com"), "free text cannot ride in a label")
        XCTAssertNil(TelemetryName("café"))
        XCTAssertNil(TelemetryName("a b"))
        XCTAssertNotNil(TelemetryName(String(repeating: "a", count: TelemetryName.maxLength)))
        XCTAssertNil(TelemetryName(String(repeating: "a", count: TelemetryName.maxLength + 1)))
    }

    func testEverySchemaLiteralSatisfiesTheGrammar() {
        let literals = [SampleSchema.captureExpense, SampleSchema.openCapture, SampleSchema.scanReceipt,
                        SampleSchema.categorize, SampleSchema.submit, SampleSchema.autoCategory]
        for name in literals { XCTAssertTrue(TelemetryName.isValid(name.rawValue), name.rawValue) }
        XCTAssertEqual(SampleSchema.definitions.count, 1)
    }

    func testDecodingRejectsInvalidNames() throws {
        let good = try JSONDecoder().decode([TelemetryName].self, from: Data(#"["ok-name"]"#.utf8))
        XCTAssertEqual(good.first?.rawValue, "ok-name")
        XCTAssertThrowsError(try JSONDecoder().decode([TelemetryName].self, from: Data(#"["Not OK"]"#.utf8)))
    }

    func testDefinitionValidation() throws {
        let k = try XCTUnwrap(TelemetryName("k"))
        let a = try XCTUnwrap(TelemetryName("a"))
        let b = try XCTUnwrap(TelemetryName("b"))
        XCTAssertNil(TaskDefinition(kind: k, steps: [], activeBudgetSeconds: 10, maxBackgroundSeconds: 10))
        XCTAssertNil(TaskDefinition(kind: k, steps: [a, a], activeBudgetSeconds: 10, maxBackgroundSeconds: 10))
        XCTAssertNil(TaskDefinition(kind: k, steps: [a], activeBudgetSeconds: 0, maxBackgroundSeconds: 10))
        XCTAssertNil(TaskDefinition(kind: k, steps: [a], activeBudgetSeconds: .nan, maxBackgroundSeconds: 10))
        XCTAssertNil(TaskDefinition(kind: k, steps: [a], activeBudgetSeconds: -5, maxBackgroundSeconds: 10))
        XCTAssertNil(TaskDefinition(kind: k, steps: [a], activeBudgetSeconds: 5, maxBackgroundSeconds: 0))
        let tooMany = (0 ... TaskDefinition.maxSteps).compactMap { TelemetryName("s\($0)") }
        XCTAssertNil(TaskDefinition(kind: k, steps: tooMany, activeBudgetSeconds: 5, maxBackgroundSeconds: 5))
        let ok = try XCTUnwrap(TaskDefinition(kind: k, steps: [a, b], activeBudgetSeconds: .infinity, maxBackgroundSeconds: 5))
        XCTAssertEqual(ok.intent, b)
        XCTAssertEqual(ok.activeBudgetNanos, .max, "infinite budget saturates instead of trapping")
    }

    func testMonotonicInstantsFromDifferentSessionsAreIncomparable() {
        let a = MonotonicInstant(session: 1, nanos: 100)
        XCTAssertEqual(MonotonicInstant(session: 1, nanos: 250).nanos(since: a), 150)
        XCTAssertNil(MonotonicInstant(session: 2, nanos: 250).nanos(since: a), "after a reboot")
        XCTAssertNil(MonotonicInstant(session: 1, nanos: 50).nanos(since: a), "time went backwards")
    }

    func testManualClockSaturatesAndReboots() {
        let clock = ManualClock(session: 7, nanos: .max - 5)
        clock.advance(nanos: 100)
        XCTAssertEqual(clock.now().nanos, .max)
        clock.advance(seconds: -.infinity)
        XCTAssertEqual(clock.now().nanos, .max)
        clock.reboot(session: 8)
        XCTAssertEqual(clock.now(), MonotonicInstant(session: 8, nanos: 0))
    }

    func testSystemClockAdvancesMonotonically() throws {
        let clock = SystemTelemetryClock(session: 42)
        let first = clock.now()
        Thread.sleep(forTimeInterval: 0.02)
        let second = clock.now()
        XCTAssertEqual(first.session, 42)
        let elapsed = try XCTUnwrap(second.nanos(since: first))
        XCTAssertGreaterThanOrEqual(elapsed, 10_000_000, "a clock that never advances must fail this")
        XCTAssertNil(MonotonicInstant(session: 43, nanos: second.nanos).nanos(since: first))
    }

    func testTrapFreeConversions() {
        XCTAssertEqual(UInt64.clamping(-1.0), 0)
        XCTAssertEqual(UInt64.clamping(1e30), .max)
        XCTAssertEqual(UInt64.clamping(Double.nan), 0)
        XCTAssertEqual(UInt64.clamping(-7), 0)
        XCTAssertEqual(UInt64.max.saturatingAdd(1), .max)
        XCTAssertEqual(UInt64(3).saturatingSub(5), 0)
        XCTAssertEqual(UInt64.max.saturatingMul(2), .max)
        XCTAssertEqual(Int.max.saturatingAddingInt(1), .max)
        XCTAssertEqual(Int.min.saturatingAddingInt(-1), .min)
        XCTAssertEqual(nanoseconds(1.5), 1_500_000_000)
    }
}
