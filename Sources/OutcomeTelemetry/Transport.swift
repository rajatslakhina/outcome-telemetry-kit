// Transport boundary. The SDK knows nothing about HTTP; an app plugs in its
// own networking (URLSession, a vendor SDK, a test double) behind this.

/// What happened to one send.
public enum TransportResult: Hashable, Sendable {
    /// The server stored the batch, or already had it (dedupe hit).
    case accepted
    /// Try again later: offline, timeout, 5xx, 429.
    case retryable
    /// The server will never accept this batch (4xx schema rejection).
    case permanent
}

public protocol OutcomeTransport: Sendable {
    func send(_ batch: UploadBatch) async -> TransportResult
}

/// An in-memory stand-in for the collection server, used by the tests and
/// the demo. It dedupes on batch id — the server half of exactly-once
/// accounting — and can inject the failure modes the client must survive.
public actor InMemoryCollector: OutcomeTransport {
    public enum Mode: String, Hashable, Sendable, CaseIterable {
        /// Accept everything.
        case healthy
        /// Every send fails before reaching the server.
        case offline
        /// The server applies the batch, then the response is lost: the
        /// client sees `.retryable` and will resend the same batch.
        case lostAcks
        /// Every send is rejected permanently.
        case rejecting
    }

    public private(set) var mode: Mode
    public private(set) var table = AggregateTable()
    /// Outcome counts of rows the clients' privacy gates reduced.
    public private(set) var outcomeOnly: [AggregateKey: OutcomeCounts] = [:]
    public private(set) var appliedBatches: UInt64 = 0
    public private(set) var duplicateSends: UInt64 = 0
    public private(set) var failedSends: UInt64 = 0
    private var seen: Set<String> = []

    public init(mode: Mode = .healthy) { self.mode = mode }

    public func setMode(_ mode: Mode) { self.mode = mode }

    /// Every task the server has counted, exactly once per batch id.
    public var taskCount: UInt64 {
        outcomeOnly.values.reduce(table.taskCount) { $0.saturatingAdd($1.total) }
    }

    public func send(_ batch: UploadBatch) async -> TransportResult {
        switch mode {
        case .offline:
            failedSends = failedSends.saturatingAdd(1)
            return .retryable
        case .rejecting:
            failedSends = failedSends.saturatingAdd(1)
            return .permanent
        case .healthy, .lostAcks:
            if seen.contains(batch.id) {
                duplicateSends = duplicateSends.saturatingAdd(1)
            } else {
                seen.insert(batch.id)
                table.merge(batch.table)
                for (key, counts) in batch.outcomeOnly { outcomeOnly[key, default: OutcomeCounts()].merge(counts) }
                appliedBatches = appliedBatches.saturatingAdd(1)
            }
            if mode == .lostAcks {
                failedSends = failedSends.saturatingAdd(1)
                return .retryable
            }
            return .accepted
        }
    }
}
