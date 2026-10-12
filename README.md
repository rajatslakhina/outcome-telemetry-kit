# OutcomeTelemetry

**Stop measuring minutes in app. Measure finished tasks, time-to-intent, and whether your AI feature actually helps.**

A Swift package for iOS that records what a user came to do as a typed task, follows it to a definite outcome (completed, abandoned, timed out, interrupted), aggregates on device behind a minimum-count privacy gate, and uploads offline-first: delivery is at-least-once and deduplicated by batch id, ids are written ahead of every send so a crash cannot double-count, and every finished task is accounted for up to the last persisted snapshot. Its report answers the question most AI-feature dashboards get wrong: *did turning the feature on make people finish more tasks?* It compares randomised arms, not "users who clicked the AI button" against everyone else.

[![CI](https://github.com/rajatslakhina/outcome-telemetry-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/outcome-telemetry-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange) ![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20Linux-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-green)

Demo app: (added after the companion repo is pushed — see below)

---

## Why this matters

"Time in app" is a proxy, and roadmaps end up optimising it. The number a product actually lives on is closer to *how many people got what they came for, and how fast*. Turning that sentence into telemetry raises a set of system-design problems that an analytics SDK usually hides:

- **What is a task, and when does it end?** If you can't say when a task ends, you can't compute a completion rate. Every task here ends in exactly one terminal state, including the awkward ones (the user left the app, the process was killed).
- **How long did it take?** Wall-clock time jumps with time zones, NTP corrections and reboots. Background time is not task time. A wrong duration is worse than no duration.
- **Did the AI feature help?** Tasks where the user accepted the suggestion look great, but users accept suggestions mostly on easy inputs. Comparing "used AI" with "didn't" measures that selection, not the feature.
- **What leaves the device?** The answer should be "counts and bucketed durations for groups of at least *k* tasks", not an event stream.
- **What happens offline for a week, or when iOS kills the process?** The queue has to stay bounded without dropping data, retries must not double-count, and nothing pending may vanish with the process.

This package is my answer to each of those, as code with tests rather than as a slide.

## Architecture

```
 app events ─▶ TaskLedger ─▶ AggregateTable ─▶ PrivacyGate ─▶ OutcomeJournal ─▶ OutcomeTransport
              state machine   on-device rows    k-threshold      bounded queue     your networking
              per task        (a monoid)        coarsen/carry    freeze + retry    (protocol)
                    └──────────── OutcomeRecorder (one actor, one suspension point) ───────────┘
                                                                         │
                                                  server side ─▶ OutcomeReport (arms, CI, funnel)
```

| Type | Responsibility |
|---|---|
| `TaskDefinition`, `TelemetryName` | The schema. Funnel steps, intent step, active-time budget, background limit, allowed AI features. Every label is a validated identifier, so free text can't get into the payload. |
| `TaskLedger` | A pure value-type state machine. Foreground-only timing, revisits, schema rejections, capacity eviction, and persistence across relaunches. |
| `MonotonicInstant`, `TelemetryClock` | Monotonic readings tagged with a session. Readings from different sessions can't be subtracted, so the duration is reported as unknown. |
| `CohortAssigner` | Stable 50/50 (or any per-mille) arm assignment with FNV-1a. It deliberately doesn't use `Hasher`. |
| `OutcomeAggregate`, `AggregateTable` | Counts, a fixed log-bucket histogram and funnel drop-off. Merging forms a commutative monoid. |
| `PrivacyGate` | No uploaded *detail* row describes fewer than *k* tasks. Small rows lose their exposure dimension first, then get carried to the next batch, and finally get reduced to outcome counts per arm. Completion counts per arm are never dropped. |
| `OutcomeJournal`, `RetryPolicy` | Offline-first queue. A batch is frozen once it has been attempted. Back-pressure coalesces batches instead of dropping them. Exponential backoff uses full jitter. |
| `OutcomeRecorder` | The actor the app calls. It composes the stages, exposes `PipelineHealth` with a conservation check, and carries in-flight work across process kills through `PersistentState` and a write-ahead hook. |
| `OutcomeReport`, `DesignEffect` | Completion rate with a stated denominator, Wilson intervals, a Newcombe difference interval widened by a design effect for per-install randomisation, and an insufficient-data guard. |
| `OutcomeTelemetryUI` | SwiftUI views (`OutcomeDashboard`, `PipelineHealthView`, `FunnelView`) that take plain values. |

```swift
import OutcomeTelemetry

let recorder = OutcomeRecorder(
    configuration: OutcomeConfiguration(
        definitions: SampleSchema.definitions,               // your TaskDefinitions
        cohorts: CohortAssigner(treatmentPerMille: 500, salt: "ai-autocategory-2026q4")
    ),
    installID: installID,                                    // stable per install
    clock: SystemTelemetryClock(),
    transport: myTransport                                   // conforms to OutcomeTransport
)

if let task = await recorder.begin(SampleSchema.captureExpense) {
    await recorder.record(step: SampleSchema.scanReceipt, for: task)
    if recorder.aiEnabled {                                  // holdout installs never see the feature
        await recorder.record(ai: .shown, feature: SampleSchema.autoCategory, for: task)
        await recorder.record(ai: .accepted, feature: SampleSchema.autoCategory, for: task)
    }
    await recorder.record(step: SampleSchema.submit, for: task)   // the intent step: completes the task
}
await recorder.tick()                                        // sweeps timeouts, seals when due (returns whether it sealed)
_ = await recorder.flush()                                   // one send; call again to drain
```

## Design decisions and trade-offs

**1. The intent step is the only way to complete a task.** A definition's last step is the intent. Reaching it completes the task, and nothing else does: there is no `complete()` call to forget or call twice. *Rejected:* an explicit `complete()` API. It lets "completed" drift away from what the user actually achieved.

**2. Durations are foreground-only and come from a session-tagged monotonic clock.** Background time is banked separately. A gap longer than the definition allows ends the task as `.abandoned(.leftApp)`. If two readings come from different sessions (relaunch or reboot), the task ends as `.interrupted`, with no duration, and it is left out of the completion-rate denominator. *Rejected:* `Date` arithmetic, which can go negative. *Also rejected:* guessing durations across a relaunch, which quietly biases against whichever arm relaunches more. An AI arm that loads a model is a likely candidate.

**3. The headline is intention-to-treat by randomised arm, and the exposure split is labelled confounded.** In the bundled simulation, turning the AI feature on raises completion from 72.0% to 77.6%: **+5.6 pts, 95% CI +1.7 to +9.5**. Comparing "used the suggestion as offered" (93.0%) with the holdout gives **+21.1 pts**, nearly four times the real effect, because hard receipts both get fewer accepted suggestions and get abandoned more often. A test asserts that the confounded gap is more than twice the arm effect. *Rejected:* exposure-based dashboards ("users who used AI completed 93%!"), the most common way AI features get over-credited.

**3b. The interval is priced for per-install randomisation.** Arms are assigned per install, and each install contributes many tasks. Tasks from one person are correlated (some people give up more easily), so treating them as independent makes the interval too narrow. `DesignEffect.estimate` computes the intra-install correlation within each arm (so the treatment effect is not mistaken for clustering) and the report widens the interval by `deff = 1 + (m̄ − 1)·ICC`. In the simulation, installs differ and deff is 1.51. A test shows the same 7.5-point gap moving from "treatment better" to "inconclusive" once a design effect of 3 is applied. *Trade-off:* the estimate needs install-level outcomes, which a backend has to hold; the client never sends them in identifiable form.

(Numbers: 240 simulated installs × 12 tasks, seed 2026, salt `ai-autocategory-2026q4`, gate k = 3 with no carries. `testReadmeHeadlineNumbers` pins every figure in this paragraph.)

**4. Arm assignment uses FNV-1a, not `Hasher`.** `Hasher` is seeded randomly per process, so installs would change arm on every launch. The tests pin FNV-1a's published vectors and five golden buckets that were computed outside this codebase. *Rejected:* server-assigned arms. They need a network round trip before the first task can be attributed.

**5. Aggregate on device, then gate detail by *k*, but never the primary metric.** Rows hold counts and fixed-bucket histograms, with no task ids, timestamps or sequences. A detail row of 1 is still a raw event, so the gate applies a fixed ladder: publish a row if it has at least *k* tasks; otherwise merge it into an exposure-less row; carry that row to the next seal; after `maxCarries`, reduce it to **outcome counts per (kind, arm)**, with no durations, funnel or AI detail.

The first version reduced such rows to one bare integer. That biased the headline: AI-on tasks are spread over four exposure rows, so they fall below *k* far more often, and the tasks that fall below skew toward unfinished ones. On five simulated fleets it inflated the measured effect by 0.8 to 2.7 points (`testDroppingTheArmOfReducedRowsWouldInflateTheEffect` pins the range). The fix keeps each arm's outcome counts. A test now asserts the gated arm comparison *equals* the ungated one on five seeds, and another feeds in the old arm-less design and asserts the check rejects it.

*What this gate is not:* every batch comes from one install, so this is minimum-count coarsening per install, **not k-anonymity across users**. A published row of 5 tasks is still one person's summary. Anonymity across users needs a server-side control, either a cross-install minimum before any slice is shown or differential privacy. *Trade-off:* reduced rows keep their outcomes but lose their durations, so time-to-intent quantiles slightly over-represent heavier users. The report shows how many tasks were reduced.

**6. Aggregates form a commutative monoid, so back-pressure coalesces and never drops.** When the queue is full, a newly sealed batch merges into the newest never-attempted batch. The queue is bounded at `capacity + 1` batches, however long the device stays offline, and loses nothing. A property test checks the monoid laws, and a deliberately broken "last writer wins" merge shows that the same check catches a real bug.

**7. A batch is frozen from its first attempt.** The attempt counter is burned *before* the send. A timed-out request may already have been applied server-side, so once a batch has been attempted, its contents and id never change. The server dedupes on the batch id. Batch ids are random per batch, so they can't link one install's batches together. *Rejected:* coalescing into in-flight batches. That would put different numbers under an idempotency key the server has already stored.

**8. One actor, one suspension point, settle by id.** `flush()` is the only `await` inside the recorder. It refuses to start a second flush, sends a copy frozen before the await, and settles that batch by id afterwards, because other calls may append or coalesce while it is suspended. A test suspends the transport mid-send and runs seals and a second flush against the actor during the suspension.

**9. Accounting is a law, and the law is checked.** `PipelineHealth.isConserved` checks that `finished == accumulating + carried + pending + acked + deadLettered`. A randomised test checks it after every operation, across six seeds of 400 mixed events and network faults, then drains and asserts the server counted every task exactly once. When a batch is dead-lettered after a lost ack, the guarantee becomes a bound (`acked ≤ server ≤ acked + deadLettered`), and a test pins that bound too.

**10. State survives a process kill, and ids are written ahead of every send.** `persistentState()` returns what is in flight: open tasks, the accumulating table, carried rows, and the journal with its attempt counts. Pass it to `init(..., restoring:)` on the next launch. Open tasks from the dead process end as `.interrupted`. Frozen batches stay frozen under the same id, while the retry and capacity policy comes from the running release, not from disk.

The order of save and send matters. An independent review found the first version could double-count: a batch sealed, sent and accepted, then a crash before the app's next save, restores an older snapshot whose tasks are re-sealed under a new random id that the server cannot dedupe. The fix is a `writeAhead` hook. If supplied, the recorder awaits a save of its state after freezing a batch and before sending it, and sends nothing if the save fails. Two tests cover this. One reproduces the crash sequence and shows the server counting each task once with the hook, and twice without it. The other kills a recorder whose frozen batch the server already applied (ack lost), restores it in a new clock session, and checks that the batch is resent under its original id and deduped. *Trade-off:* one disk write per send. Tasks finished after the last save are still lost on a crash, so the app should also save on backgrounding. Rejection counters and the backoff are not persisted. (At the `TaskLedger` level, a restored task whose id collides with one begun before the state loaded gets a fresh id instead of being dropped.)

**11. Experiment-integrity alarms rather than silent data.** An AI event from a holdout install is rejected and counted (`.aiEventInHoldout`): it means the feature leaked into the control group. Unknown steps, unknown features and events for already-finished tasks are rejected and counted as well. None of them throws at the app.

## Failure modes covered by tests

| Scenario | What the tests assert |
|---|---|
| Reboot / relaunch mid-task | `.interrupted`, no duration, excluded from the denominator; restored ids are not reused; colliding ids are remapped, not dropped |
| Process killed with work in flight | `PersistentState` restores it; with `writeAhead`, the server receives each task exactly once (without it, the test shows a double count) |
| Background for 60 s, then return | those 60 s are not in time-to-intent |
| Background beyond the limit | `.abandoned(.leftApp)`, also when the step arrives while still in the background; later events rejected |
| Intent reached after the active budget | `.timedOut`, not completed; the late step is not applied |
| Tracker full | the oldest task is evicted as `.abandoned(.evicted)` (an unknown outcome) |
| A week offline, 50 seals into a 3-batch queue | 3 batches, every task still pending |
| Ack lost after the server applied a batch | the server counts it once; `duplicateSends` records the resends |
| Permanent rejection / retries exhausted | dead-lettered, with the task count carried into health |
| Second `flush()` while one is in flight | `.alreadyFlushing`; the in-flight batch is unchanged |
| `Int.min` attempts, NaN jitter, infinite budgets, NaN or infinite design effects | no trap; values clamp |

## Verification

- **Linux (local, Swift 6.1.2):** clean `swift build --build-tests -Xswiftc -warnings-as-errors` with 0 warnings; `swift test` passes **74 tests, 0 failures**.
- **CI:** the [Actions tab](https://github.com/rajatslakhina/outcome-telemetry-kit/actions) runs two jobs on every push to `main`, every pull request and on manual dispatch.
  - **Linux:** in the `swift:6.1` container, a clean warnings-as-errors build plus `swift test`. This compiles the core module; the SwiftUI module builds to nothing there.
  - **`macos-15`:** the same build and tests (which compile `OutcomeTelemetryUI` for macOS), then `xcodebuild` of the `OutcomeTelemetry-Package` scheme for `generic/platform=iOS Simulator` with warnings as errors (the iOS build of both modules).
- **Simulator:** not run on the author's Mac. Access to Xcode and Simulator was granted, but Xcode had unrelated projects open and Simulator had devices booted, so nothing was clicked. The demo app was instead installed, launched and screenshotted on a GitHub-hosted macOS Simulator; the [demo repo](https://github.com/rajatslakhina/outcome-telemetry-kit-demo-app) says exactly what ran.

## Limits

- The `InMemoryCollector` is a stand-in for a server; its dedupe set grows without bound. A real backend needs persistent dedupe of batch ids with a retention window longer than the client's retry horizon.
- The design effect needs install-level outcomes. The demo computes it from the simulator's per-install counts; a real backend has to hold (or sample) per-install aggregates to estimate it.
- There is no file store in the package. `OutcomeRecorder.PersistentState` is `Codable`; the app writes it in the `writeAhead` hook and on backgrounding.
- The simulation's behaviour model is invented. Its numbers show the mechanism and are not a benchmark.
- Histogram quantiles are reported as bucket bounds (`≤ 8 s`), never interpolated.

## Installation

```swift
.package(url: "https://github.com/rajatslakhina/outcome-telemetry-kit.git", from: "1.0.0")
```

Products: `OutcomeTelemetry` (core, also builds on Linux) and `OutcomeTelemetryUI` (SwiftUI views).

## License

MIT. See [LICENSE](LICENSE).
