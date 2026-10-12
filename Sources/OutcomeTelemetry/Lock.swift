import Foundation

/// A minimal lock wrapper. `Synchronization.Mutex` would be preferable but
/// needs iOS 18 / macOS 15; this package supports iOS 17.
final class Lock: @unchecked Sendable {
    // @unchecked: NSLock is thread-safe; this type only forwards to it.
    private let base = NSLock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        base.lock()
        defer { base.unlock() }
        return try body()
    }
}
