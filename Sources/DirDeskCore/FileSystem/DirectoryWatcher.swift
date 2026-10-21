import CoreServices
import Foundation

/// Watches a set of directories through one FSEvents stream and reports which watched
/// directories changed directly (an entry inside them was created, removed, renamed or modified).
public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (Set<String>) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.kbwumin13.dirdesk.directory-watcher")
    private let handler: Handler
    private var watched: Set<String> = []
    private let latency: CFTimeInterval

    public init(latency: CFTimeInterval = 0.15, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit { stopStream() }

    /// Replaces the watched directory set. Paths are standardized absolute paths.
    public func watch(_ paths: Set<String>) {
        queue.async { [weak self] in
            guard let self, paths != self.watched else { return }
            self.watched = paths
            self.stopStream()
            if !paths.isEmpty { self.startStream() }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.watched = []
            self?.stopStream()
        }
    }

    private func startStream() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var changed: [(String, FSEventStreamEventFlags)] = []
            for index in 0..<count {
                if let path = array[index] as? String {
                    changed.append((path, eventFlags[index]))
                }
            }
            watcher.dispatch(changed)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, Array(watched) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func dispatch(_ events: [(String, FSEventStreamEventFlags)]) {
        var hits: Set<String> = []
        for (rawPath, flags) in events {
            let path = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            let parent = (path as NSString).deletingLastPathComponent
            if watched.contains(parent) { hits.insert(parent) }
            if watched.contains(path) {
                // Events on a watched directory itself (rescans, root changes, attribute changes).
                hits.insert(path)
            }
            if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                for watchedPath in watched where watchedPath.hasPrefix(path) || path.hasPrefix(watchedPath) {
                    hits.insert(watchedPath)
                }
            }
        }
        if !hits.isEmpty { handler(hits) }
    }
}
