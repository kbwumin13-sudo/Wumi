import Foundation
import CoreServices

struct IndexPathFilter {
    private let ignoredPaths: [String]
    private let sidecarPaths: [String]
    init(ignoredPaths: [String]) {
        self.ignoredPaths = ignoredPaths.map(Self.canonicalPath)
        self.sidecarPaths = ignoredPaths.filter { path in
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath:path,isDirectory:&directory) || !directory.boolValue
        }.map(Self.canonicalPath)
    }
    static func canonicalPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        var path=URL(fileURLWithPath:path).standardizedFileURL.path
        if path == data { path="/" }
        else if path.hasPrefix(data + "/") { path=String(path.dropFirst(data.count)) }
        var candidate=URL(fileURLWithPath:path),missing:[String]=[]
        // resolvingSymlinksInPath leaves /private/var aliases unresolved when
        // the final file has already been removed. Resolve a surviving ancestor
        // and append the missing components so removals map to the same root.
        while candidate.path != "/" && !FileManager.default.fileExists(atPath:candidate.path) {
            missing.append(candidate.lastPathComponent)
            candidate=candidate.deletingLastPathComponent()
        }
        candidate=candidate.resolvingSymlinksInPath()
        for component in missing.reversed() { candidate=candidate.appendingPathComponent(component) }
        return candidate.standardizedFileURL.path
    }
    func ignores(_ path: String) -> Bool { ignores(canonical: Self.canonicalPath(path)) }
    /// For paths already in canonical form (a scan below a canonical root), skipping
    /// the per-path symlink resolution that event paths need.
    func ignores(canonical path: String) -> Bool {
        ignoredPaths.contains { ignored in
            path == ignored || path.hasPrefix(ignored == "/" ? "/" : ignored + "/")
        } || sidecarPaths.contains { ignored in
            ["-wal", "-shm", "-journal"].contains { path == ignored + $0 }
        }
    }
}

/// IDs are host FSEvents IDs. Recovery flags must survive filtering: a dropped
/// event can name the stream root even when that path is otherwise ignored.
public struct FileChangeEvent: Sendable {
    public var path: String
    public var flags: UInt32
    public var id: UInt64
    public init(path: String, flags: UInt32 = 0, id: UInt64 = 0) {
        self.path=path; self.flags=flags; self.id=id
    }
    public var requiresFullScan: Bool {
        flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0
    }
    var historyDone: Bool { flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }
    var mustScanSubDirs: Bool { flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
    var idsWrapped: Bool { flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 }
    /// For diagnostics only.
    var recoveryDescription: String {
        var parts: [String] = []
        if flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0 { parts.append("用户态丢事件") }
        if flags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 { parts.append("内核丢事件") }
        if idsWrapped { parts.append("事件编号回绕") }
        if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { parts.append("监视根变化") }
        if mustScanSubDirs && parts.isEmpty { parts.append("事件合并到根目录") }
        return parts.joined(separator:"、")
    }
}

public final class FileWatcher {
    static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }
    static var droppedEventFlag: UInt32 { UInt32(kFSEventStreamEventFlagUserDropped) }
    private final class Context { let changed: ([FileChangeEvent]) -> Void; init(_ changed: @escaping ([FileChangeEvent]) -> Void) { self.changed = changed } }
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "local.miji.filesystem", qos: .utility)
    // Events are filtered and recorded here, off the stream's queue: a callback that
    // waits makes fseventsd drop events and forces a whole-root rescan.
    private let processing = DispatchQueue(label: "local.miji.filesystem.events", qos: .utility)
    public private(set) var isWatching = false
    public convenience init(paths: [String], ignoredPaths: [String] = [], changed: @escaping ([String]) -> Void) {
        self.init(paths:paths,ignoredPaths:ignoredPaths,since:UInt64(kFSEventStreamEventIdSinceNow),events:{ changed($0.map(\.path)) })
    }
    public init(paths: [String], ignoredPaths: [String] = [], since: UInt64, events: @escaping ([FileChangeEvent]) -> Void) {
        guard !paths.isEmpty else { return }
        let filter = IndexPathFilter(ignoredPaths: ignoredPaths)
        let processing = processing
        let box = Context { changes in
            processing.async {
                let relevant = changes.filter { $0.requiresFullScan || $0.historyDone || !filter.ignores($0.path) }
                if !relevant.isEmpty { events(relevant) }
            }
        }
        var context = FSEventStreamContext(version: 0,info: Unmanaged.passUnretained(box).toOpaque(),retain: { pointer in
            guard let pointer else { return nil }; _ = Unmanaged<Context>.fromOpaque(pointer).retain(); return pointer
        },release: { pointer in if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() } },copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _,context,count,paths,flags,ids in
            guard let context else { return }
            let changedPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let changes=(0..<min(count,changedPaths.count)).map { FileChangeEvent(path:changedPaths[$0],flags:flags[$0],id:ids[$0]) }
            Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().changed(changes)
        }, &context, paths as CFArray, since, 1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
        if let stream { FSEventStreamSetDispatchQueue(stream,queue); isWatching=FSEventStreamStart(stream) }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
