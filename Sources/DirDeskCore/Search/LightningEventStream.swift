import CoreServices
import Foundation

/// A file-system change, bit-compatible with FSEvents so stream callbacks pass flags through unchanged.
/// Tests and callers that already know what changed can build events directly.
public struct LightningFileEvent: Equatable, Sendable {
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let mustScanSubdirectories = Flags(rawValue: 0x0000_0001)
        public static let userDropped = Flags(rawValue: 0x0000_0002)
        public static let kernelDropped = Flags(rawValue: 0x0000_0004)
        public static let eventIDsWrapped = Flags(rawValue: 0x0000_0008)
        public static let historyDone = Flags(rawValue: 0x0000_0010)
        public static let rootChanged = Flags(rawValue: 0x0000_0020)
        public static let mount = Flags(rawValue: 0x0000_0040)
        public static let unmount = Flags(rawValue: 0x0000_0080)
        public static let itemCreated = Flags(rawValue: 0x0000_0100)
        public static let itemRemoved = Flags(rawValue: 0x0000_0200)
        public static let itemInodeMetadataModified = Flags(rawValue: 0x0000_0400)
        public static let itemRenamed = Flags(rawValue: 0x0000_0800)
        public static let itemModified = Flags(rawValue: 0x0000_1000)
        public static let itemFinderInfoModified = Flags(rawValue: 0x0000_2000)
        public static let itemOwnerChanged = Flags(rawValue: 0x0000_4000)
        public static let itemXattrModified = Flags(rawValue: 0x0000_8000)
        public static let itemIsFile = Flags(rawValue: 0x0001_0000)
        public static let itemIsDirectory = Flags(rawValue: 0x0002_0000)
        public static let itemIsSymlink = Flags(rawValue: 0x0004_0000)

        /// FSEvents lost events below the path; it must be rescanned.
        static let recovery: Flags = [.mustScanSubdirectories, .userDropped, .kernelDropped, .eventIDsWrapped, .rootChanged]
        static let structural: Flags = [.itemCreated, .itemRemoved, .itemRenamed]
    }

    public var path: String
    public var flags: Flags
    public var eventID: UInt64

    public init(path: String, flags: Flags, eventID: UInt64 = 0) {
        self.path = path
        self.flags = flags
        self.eventID = eventID
    }
}

/// One FSEvents stream over the watched roots, optionally resumed from a stored event id.
final class LightningEventStream: @unchecked Sendable {
    private final class Context {
        let handler: ([LightningFileEvent]) -> Void

        init(_ handler: @escaping ([LightningFileEvent]) -> Void) {
            self.handler = handler
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.kbwumin13.dirdesk.lightning-events", qos: .utility)

    static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Paths must be canonical. `since` nil starts with new events only. At most eight exclusions are honored.
    init?(paths: [String], exclusions: [String], since: UInt64?, latency: TimeInterval,
          handler: @escaping ([LightningFileEvent]) -> Void) {
        guard !paths.isEmpty else { return nil }
        let box = Context(handler)
        // Retain/release context pattern adapted from the user's MIT project "mac 搜索" (Sources/MijiCore/FileWatcher.swift).
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Context>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() }
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [LightningFileEvent] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                guard let path = array[index] as? String else { continue }
                events.append(LightningFileEvent(path: path, flags: .init(rawValue: flags[index]), eventID: ids[index]))
            }
            Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().handler(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        let start = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray, start, latency, flags) else {
            return nil
        }
        if !exclusions.isEmpty {
            FSEventStreamSetExclusionPaths(stream, Array(exclusions.prefix(8)) as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        self.stream = stream
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard let stream else { return false }
        return FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The FSEvents database id of the volume holding `path`; event ids only stay valid while it matches.
    static func volumeUUID(for path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return "" }
        return (CFUUIDCreateString(nil, uuid) as String?) ?? ""
    }
}
