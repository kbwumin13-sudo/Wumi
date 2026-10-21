import Combine
import DirDeskCore
import Foundation

struct FolderSizeState {
    let measurement: DirectorySizeMeasurement
    let finished: Bool
}

/// Visible browser cells and previews share one cancellable, metadata-only scan. No polling or disk cache.
@MainActor
final class FolderSizes {
    static let shared = FolderSizes()
    private struct Key: Hashable {
        let path: String
        let identity: FileIdentity
        let modified: Date?
    }
    private struct Cached {
        let state: FolderSizeState
        let date: Date
    }
    private struct Pending {
        let id: UUID
        let operation: FolderSizeOperation
        var state: FolderSizeState?
        var observers: [UUID: (FolderSizeState) -> Void]
    }
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.kbwumin13.dirdesk.folder-sizes"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var cache: [Key: Cached] = [:]
    private var pending: [Key: Pending] = [:]

    static func needsMeasurement(_ item: FileItem) -> Bool { item.isDirectory && !item.isSymbolicLink }

    func invalidate(in directory: URL?) {
        guard let directory else { return }
        let path = directory.path
        let prefix = path == "/" ? "/" : path + "/"
        func affected(_ key: Key) -> Bool {
            key.path == path || key.path.hasPrefix(prefix) || path.hasPrefix(key.path + "/")
        }
        cache = cache.filter { !affected($0.key) }
        // An unchanged directory mtime does not imply unchanged bytes in its existing descendants.
        for key in Array(pending.keys) where affected(key) {
            guard let old = pending[key] else { continue }
            old.operation.cancel()
            let id = UUID()
            let operation = FolderSizeOperation(url: URL(fileURLWithPath: key.path, isDirectory: true)) { [weak self] state in
                DispatchQueue.main.async { self?.publish(state, key: key, id: id) }
            }
            let state = FolderSizeState(measurement: .init(bytes: 0, isComplete: false), finished: false)
            pending[key] = Pending(id: id, operation: operation, state: state, observers: old.observers)
            Array(old.observers.values).forEach { $0(state) }
            queue.addOperation(operation)
        }
    }

    func observe(_ item: FileItem, receive: @escaping (FolderSizeState) -> Void) -> AnyCancellable {
        let key = Key(path: item.url.path, identity: item.id, modified: item.modificationDate)
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < 60 {
            receive(cached.state)
            return AnyCancellable {}
        }
        let observer = UUID()
        if var job = pending[key] {
            job.observers[observer] = receive
            pending[key] = job
            if let state = job.state { receive(state) }
        } else {
            let id = UUID()
            let operation = FolderSizeOperation(url: item.url) { [weak self] state in
                DispatchQueue.main.async { self?.publish(state, key: key, id: id) }
            }
            pending[key] = Pending(id: id, operation: operation, observers: [observer: receive])
            queue.addOperation(operation)
        }
        return AnyCancellable { [weak self] in
            Task { @MainActor in self?.removeObserver(observer, key: key) }
        }
    }

    func updates(for item: FileItem) -> AsyncStream<FolderSizeState> {
        AsyncStream { continuation in
            let observation = observe(item) { state in
                continuation.yield(state)
                if state.finished { continuation.finish() }
            }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    private func removeObserver(_ observer: UUID, key: Key) {
        guard var job = pending[key] else { return }
        job.observers.removeValue(forKey: observer)
        if job.observers.isEmpty {
            job.operation.cancel()
            pending.removeValue(forKey: key)
        } else { pending[key] = job }
    }

    private func publish(_ state: FolderSizeState, key: Key, id: UUID) {
        guard var job = pending[key], job.id == id else { return }
        if state.finished {
            pending.removeValue(forKey: key)
            cache[key] = Cached(state: state, date: Date())
            if cache.count > 512, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key {
                cache.removeValue(forKey: oldest)
            }
        } else {
            job.state = state
            pending[key] = job
        }
        Array(job.observers.values).forEach { $0(state) }
    }

    static func text(_ item: FileItem, state: FolderSizeState?, unit: FileSizeUnit) -> String {
        guard needsMeasurement(item) else {
            return item.size.map { FileSizeFormatter.string($0, unit: unit) } ?? L("Unknown Size")
        }
        guard let state else { return L("Calculating…") }
        let value = FileSizeFormatter.string(state.measurement.bytes, unit: unit)
        if state.measurement.isComplete { return value }
        if state.measurement.bytes > 0 { return "≥ " + value }
        return state.finished ? L("Size Unavailable") : L("Calculating…")
    }

    static func help(_ state: FolderSizeState?) -> String? {
        guard let state else { return L("Calculating…") }
        if !state.finished { return L("Calculating…") }
        return state.measurement.isComplete ? nil : L("Some items could not be read. The size shown is a minimum.")
    }
}

private final class FolderSizeOperation: Operation, @unchecked Sendable {
    let url: URL
    let receive: (FolderSizeState) -> Void

    init(url: URL, receive: @escaping (FolderSizeState) -> Void) {
        self.url = url
        self.receive = receive
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        let result = DirectorySizeCalculator.measure(url, isCancelled: { self.isCancelled }) { measurement in
            guard !self.isCancelled else { return }
            self.receive(FolderSizeState(measurement: measurement, finished: false))
        }
        guard !isCancelled else { return }
        receive(FolderSizeState(measurement: result, finished: true))
    }
}
