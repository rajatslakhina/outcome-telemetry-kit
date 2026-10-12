// Time is the hardest part of a "time-to-intent" metric.
//
// Wall-clock time (`Date`) jumps: the user changes the time zone, NTP corrects
// the clock, the device was set to 2019 by a parent. A duration computed from
// two `Date`s can be negative or off by hours. So durations here are measured
// only on a monotonic clock, and a monotonic reading is tagged with the boot
// session it came from: after a reboot the counter restarts at zero, and two
// readings from different boot sessions cannot be subtracted at all.
//
// The rule the whole SDK follows: if two instants are not comparable, the
// duration is *unknown* (nil), never "zero" and never a guess. Tasks whose
// durations are unknown finish as `.interrupted` and are excluded from the
// time-to-intent histograms instead of polluting them.

/// A reading from a monotonic clock, scoped to one boot session.
public struct MonotonicInstant: Hashable, Sendable, Codable {
    /// Identifies the boot session (or, conservatively, the process) the
    /// reading came from. Readings from different sessions are incomparable.
    public let session: UInt64
    /// Nanoseconds since an arbitrary origin within `session`.
    public let nanos: UInt64

    public init(session: UInt64, nanos: UInt64) {
        self.session = session
        self.nanos = nanos
    }

    /// Nanoseconds from `earlier` to `self`, or nil when the two readings are
    /// not comparable (different sessions, or time went backwards).
    public func nanos(since earlier: MonotonicInstant) -> UInt64? {
        guard session == earlier.session, nanos >= earlier.nanos else { return nil }
        return nanos - earlier.nanos
    }
}

/// The clock the SDK reads. Injected so tests and the demo control time.
public protocol TelemetryClock: Sendable {
    func now() -> MonotonicInstant
}

/// Production clock: `ContinuousClock` (keeps counting while the device
/// sleeps, so background gaps are measured, not hidden) tagged with a session
/// id chosen once per process.
///
/// A process id is a *stricter* session than a boot id: tasks restored after
/// a relaunch are always treated as incomparable, even on the same boot. That
/// is deliberate — the SDK would rather report a task as interrupted than
/// subtract instants whose relationship it cannot prove.
public struct SystemTelemetryClock: TelemetryClock {
    private let session: UInt64
    private let origin: ContinuousClock.Instant

    public init(session: UInt64 = UInt64.random(in: 1 ... .max)) {
        self.session = session
        self.origin = ContinuousClock.now
    }

    public func now() -> MonotonicInstant {
        let elapsed = origin.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        let wholeNanos = UInt64(clamping: seconds).saturatingMul(1_000_000_000)
        let fraction = UInt64(clamping: attoseconds / 1_000_000_000)
        return MonotonicInstant(session: session, nanos: wholeNanos.saturatingAdd(fraction))
    }
}

/// A clock moved by hand. Used by tests and by the demo's simulated users.
/// Thread-safe so it can be shared with the recorder actor.
public final class ManualClock: TelemetryClock, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    private let lock = Lock()
    private var current: MonotonicInstant

    public init(session: UInt64 = 1, nanos: UInt64 = 0) {
        current = MonotonicInstant(session: session, nanos: nanos)
    }

    public func now() -> MonotonicInstant { lock.withLock { current } }

    /// Moves time forward. Saturates rather than wrapping.
    public func advance(nanos delta: UInt64) {
        lock.withLock {
            current = MonotonicInstant(session: current.session, nanos: current.nanos.saturatingAdd(delta))
        }
    }

    public func advance(seconds: Double) {
        advance(nanos: UInt64.clamping(seconds * 1_000_000_000))
    }

    /// Simulates a reboot or relaunch: a new session whose counter restarts.
    public func reboot(session: UInt64) {
        lock.withLock { current = MonotonicInstant(session: session, nanos: 0) }
    }
}

/// Seconds → nanoseconds helper used by configuration types.
public func nanoseconds(_ seconds: Double) -> UInt64 {
    UInt64.clamping(seconds * 1_000_000_000)
}
