// The schema: what a "task" is, and what can be said about one.
//
// Every name the SDK will ever upload is declared here, up front, by the app.
// Kinds, steps and AI feature names are identifiers checked against a strict
// grammar, so free text (a search query, an email address, a file name) can
// never ride along inside a label. That is the first privacy control, and it
// is a type-level one: there is no API that accepts an arbitrary string and
// puts it on the wire.

/// A validated identifier: 1–48 characters of `a-z`, `0-9`, `-` and `_`,
/// starting with a letter. Used for task kinds, steps and AI feature names.
public struct TelemetryName: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public static let maxLength = 48

    /// Returns nil for anything that is not a well-formed identifier.
    public init?(_ raw: String) {
        guard Self.isValid(raw) else { return nil }
        rawValue = raw
    }

    /// For compile-time literals known to satisfy the grammar. Checked by an
    /// assertion in debug builds and by a unit test over every call site.
    init(validated raw: String) {
        assert(Self.isValid(raw), "invalid telemetry name literal: \(raw)")
        rawValue = raw
    }

    public static func isValid(_ raw: String) -> Bool {
        let scalars = raw.unicodeScalars
        guard let first = scalars.first, scalars.count <= maxLength else { return false }
        guard ("a"..."z").contains(first) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let name = TelemetryName(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid telemetry name"))
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why a task ended without reaching its intent.
public enum AbandonReason: String, Hashable, Sendable, Codable, CaseIterable {
    /// The app reported the user backed out (cancel button, swipe-dismiss).
    case userCancelled
    /// The app was in the background longer than the definition allows.
    case leftApp
    /// The app reported a failure that ended the task.
    case failed
    /// The tracker was full and this was the oldest open task.
    case evicted
}

/// How a task ended. Exactly one per task instance, never changed afterwards.
public enum TaskOutcome: Hashable, Sendable, Codable {
    /// The intent step was reached.
    case completed
    case abandoned(AbandonReason)
    /// Active (foreground) time exceeded the definition's budget.
    case timedOut
    /// The tracker could not measure the task: its start and end readings
    /// came from different clock sessions (relaunch, reboot) or time went
    /// backwards. Counted, never timed.
    case interrupted
}

/// The app's declaration of one kind of task a user comes to do.
///
/// `steps` is an ordered funnel. The **last** step is the intent: the moment
/// the user got what they came for. Reaching it completes the task; nothing
/// else does. Recording an earlier step after a later one is a revisit, not a
/// regression of progress.
public struct TaskDefinition: Hashable, Sendable {
    /// The most steps a definition may have. Bounds the per-row drop-off
    /// array, so an aggregate's size never depends on app input.
    public static let maxSteps = 12

    public let kind: TelemetryName
    public let steps: [TelemetryName]
    /// Foreground-time budget. Exceeding it ends the task as `.timedOut`.
    public let activeBudgetNanos: UInt64
    /// A background gap longer than this ends the task as `.abandoned(.leftApp)`.
    public let maxBackgroundNanos: UInt64
    /// AI features that may be offered during this task. Events for features
    /// not listed here are rejected as schema violations.
    public let aiFeatures: Set<TelemetryName>

    /// Fails (returns nil) on an empty or over-long funnel, duplicate steps,
    /// or a zero budget — a definition that could never complete or could
    /// never time out is a bug in the app, caught at startup.
    public init?(
        kind: TelemetryName,
        steps: [TelemetryName],
        activeBudgetSeconds: Double,
        maxBackgroundSeconds: Double,
        aiFeatures: Set<TelemetryName> = []
    ) {
        guard !steps.isEmpty, steps.count <= Self.maxSteps, Set(steps).count == steps.count else { return nil }
        let budget = nanoseconds(activeBudgetSeconds)
        let background = nanoseconds(maxBackgroundSeconds)
        guard budget > 0, background > 0 else { return nil }
        self.kind = kind
        self.steps = steps
        self.activeBudgetNanos = budget
        self.maxBackgroundNanos = background
        self.aiFeatures = aiFeatures
    }

    /// The step that completes the task. Safe: `steps` is non-empty by construction.
    public var intent: TelemetryName {
        // `init?` rejects an empty `steps`, so `last` is always present; the
        // fallback exists only to avoid a force-unwrap.
        steps.last ?? kind
    }

    /// Position of `step` in the funnel, or nil if it is not part of it.
    public func index(of step: TelemetryName) -> Int? {
        steps.firstIndex(of: step)
    }
}
