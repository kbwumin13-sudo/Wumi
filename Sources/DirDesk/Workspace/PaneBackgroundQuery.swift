import CoreServices
import DirDeskCore
import Foundation

/// Also observable by the Spotlight stop queue, which has no Swift Task cancellation context.
final class PaneLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Pane-specific cancellable Spotlight execution. Reuses Core's query grammar and error contract.
/// The Core helper has no cancellation hook; stopping MDQuery here also stops abandoned virtual loads.
enum PaneBackgroundQuery {
    private static let stopQueue = DispatchQueue(label: "com.kbwumin13.dirdesk.pane.spotlight-stop")

    static func paths(matching expression: String, homeOnly: Bool, limit: Int, timeout: TimeInterval? = nil,
                      cancellation: PaneLoadCancellation) throws -> [String] {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let query = MDQueryCreate(kCFAllocatorDefault, expression as CFString, nil, nil) else {
            throw SpotlightQuery.QueryError.couldNotCreateQuery
        }
        MDQuerySetSearchScope(query, [homeOnly ? kMDQueryScopeHome as Any : kMDQueryScopeComputer as Any] as CFArray, 0)
        MDQuerySetMaxCount(query, limit)
        // Poll on a separate serial queue because MDQueryExecute is synchronous. Repeated stops cover cancellation
        // between installing the timer and entering MDQueryExecute. State below belongs solely to stopQueue.
        let timer = DispatchSource.makeTimerSource(queue: stopQueue)
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var timedOut = false
        timer.setEventHandler {
            if let deadline, Date() >= deadline { timedOut = true }
            if cancellation.isCancelled || timedOut { MDQueryStop(query) }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(25))
        timer.resume()
        let executed = MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        let didTimeOut = stopQueue.sync {
            timer.setEventHandler {}
            timer.cancel()
            return timedOut
        }
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        if didTimeOut { throw SpotlightQuery.QueryError.timedOut }
        guard executed else { throw SpotlightQuery.QueryError.couldNotExecuteQuery }
        let count = MDQueryGetResultCount(query)
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { result.append(path) }
        }
        return result
    }
}
