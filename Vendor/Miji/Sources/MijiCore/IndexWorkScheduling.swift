import Foundation

/// A slice yields by scheduling a continuation, never by sleeping on the index
/// queue. Injecting the monotonic clock and enqueue operation makes boundaries
/// deterministic without replacing the real serial queue in tests.
struct IndexWorkScheduling {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var enqueue: (DispatchQueue, TimeInterval, DispatchWorkItem) -> Void = { queue, delay, item in
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    var metadataSeconds: TimeInterval = 0.05
    var metadataItems = 300
    var contentSeconds: TimeInterval = 0.05
    var continuationDelay: TimeInterval = 0.2
}
