// Cohorts: how the SDK answers "does the AI feature actually help?" without
// fooling itself.
//
// There are two ways to split tasks by AI, and only one of them is causal.
//
// * **Exposure** — did this task *use* the AI suggestion? Users who accept a
//   suggestion are not a random sample: they are the ones for whom the
//   suggestion was good, on the tasks where it was easy. Comparing "accepted"
//   tasks with "no AI" tasks measures that selection, not the feature.
// * **Arm** — was this *install* randomly assigned to have the feature on
//   (treatment) or off (holdout)? Comparing arms is an intention-to-treat
//   estimate: it includes the users who ignored or rejected the suggestion,
//   which is exactly what a roadmap decision needs.
//
// The SDK records both. `OutcomeReport` leads with the arm comparison and
// shows the exposure split beside it, labelled as descriptive only.

/// What the AI feature did during one task. Ordered by strength: a task's
/// exposure is the strongest event recorded for it.
public enum AIExposure: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// No suggestion was shown.
    case none = 0
    /// At least one suggestion was shown; none was used.
    case shownOnly = 1
    /// A suggestion was used after the user edited it.
    case edited = 2
    /// A suggestion was used as offered.
    case accepted = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One AI interaction inside a task.
public enum AIEvent: String, Hashable, Sendable, Codable, CaseIterable {
    case shown, accepted, edited, rejected

    var exposure: AIExposure {
        switch self {
        case .shown, .rejected: return .shownOnly
        case .edited: return .edited
        case .accepted: return .accepted
        }
    }
}

/// The randomised experiment arm of an install.
public enum ExperimentArm: String, Hashable, Sendable, Codable, CaseIterable {
    /// AI features enabled.
    case treatment
    /// AI features disabled — the counterfactual.
    case holdout
}

/// Deterministic, stable arm assignment.
///
/// Uses 64-bit FNV-1a, **not** `Hasher`: `Hasher` is randomly seeded per
/// process, so an install would switch arms on every launch and the
/// experiment would silently measure noise. FNV-1a over UTF-8 bytes gives the
/// same answer in every process, on every platform, forever — which is what
/// the published test vectors in the tests pin down.
public struct CohortAssigner: Hashable, Sendable {
    /// Per-mille of installs in the treatment arm (0...1000).
    public let treatmentPerMille: Int
    /// Experiment salt. Changing it re-randomises every install, so it is
    /// part of the experiment's identity.
    public let salt: String

    public init(treatmentPerMille: Int, salt: String) {
        self.treatmentPerMille = min(max(treatmentPerMille, 0), 1000)
        self.salt = salt
    }

    public func arm(forInstall installID: String) -> ExperimentArm {
        bucket(forInstall: installID) < treatmentPerMille ? .treatment : .holdout
    }

    /// The install's bucket in 0..<1000.
    public func bucket(forInstall installID: String) -> Int {
        // `% 1000` on a UInt64 is always < 1000, so the Int conversion is safe
        // on 32-bit platforms too.
        Int(Self.fnv1a64(salt + "|" + installID) % 1000)
    }

    /// 64-bit FNV-1a over the UTF-8 bytes of `text`.
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // wrapping multiply is the algorithm
        }
        return hash
    }
}
