import Darwin
import Foundation
import UniformTypeIdentifiers

/// The children of one directory as read from disk, in compact arrays.
struct LightningListing {
    enum Kind: UInt8 { case file, directory, symlink, other }

    var names: [UInt8] = []
    var nameStart: [Int] = []
    var nameCount: [Int] = []
    var kind: [Kind] = []
    var size: [Int64] = []
    var modified: [Double] = []
    var created: [Double] = []
    var hidden: [Bool] = []
    var device: [Int32] = []

    var count: Int { kind.count }

    mutating func removeAll() {
        names.removeAll(keepingCapacity: true)
        nameStart.removeAll(keepingCapacity: true)
        nameCount.removeAll(keepingCapacity: true)
        kind.removeAll(keepingCapacity: true)
        size.removeAll(keepingCapacity: true)
        modified.removeAll(keepingCapacity: true)
        created.removeAll(keepingCapacity: true)
        hidden.removeAll(keepingCapacity: true)
        device.removeAll(keepingCapacity: true)
    }

    mutating func append(name: UnsafeRawBufferPointer, kind entryKind: Kind, size entrySize: Int64, modified entryModified: Double,
                         created entryCreated: Double, flags: UInt32, device entryDevice: Int32) {
        nameStart.append(names.count)
        nameCount.append(name.count)
        names.append(contentsOf: name)
        kind.append(entryKind)
        size.append(entryKind == .directory ? 0 : max(entrySize, 0))
        modified.append(entryModified)
        created.append(entryCreated)
        hidden.append(name.first == 0x2E || flags & UInt32(UF_HIDDEN) != 0)
        device.append(entryDevice)
    }

    func name(_ index: Int) -> ArraySlice<UInt8> {
        names[nameStart[index]..<(nameStart[index] + nameCount[index])]
    }
}

/// Reads directories with `getattrlistbulk` (one call returns many entries with their attributes),
/// falling back to `readdir` + `fstatat` where a file system rejects it.
enum LightningDirectoryReader {
    // sys/attr.h
    private static let commonName: UInt32 = 0x0000_0001
    private static let commonDevice: UInt32 = 0x0000_0002
    private static let commonObjectType: UInt32 = 0x0000_0008
    private static let commonCreationTime: UInt32 = 0x0000_0200
    private static let commonModificationTime: UInt32 = 0x0000_0400
    private static let commonFlags: UInt32 = 0x0004_0000
    private static let commonError: UInt32 = 0x2000_0000
    private static let commonReturnedAttributes: UInt32 = 0x8000_0000
    private static let fileDataLength: UInt32 = 0x0000_0200
    private static let attributeSetSize = 20

    static let bufferSize = 256 * 1024

    /// Appends the children of `path` to `listing`. Returns 0 or an errno value.
    static func read(_ path: String, into listing: inout LightningListing, buffer: UnsafeMutableRawPointer) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = commonReturnedAttributes | commonError | commonName | commonDevice | commonObjectType
            | commonCreationTime | commonModificationTime | commonFlags
        request.fileattr = fileDataLength
        var readAny = false
        while true {
            let count = withUnsafeMutablePointer(to: &request) {
                getattrlistbulk(descriptor, $0, buffer, bufferSize, 0)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if !readAny { return readWithStat(path, into: &listing) }
                return code
            }
            if count == 0 { return 0 }
            readAny = true
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                guard length > 0 else { return EIO }
                parse(entry, into: &listing)
                entry += length
            }
        }
    }

    private static func parse(_ entry: UnsafeRawPointer, into listing: inout LightningListing) {
        let common = entry.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let file = entry.loadUnaligned(fromByteOffset: 4 + 12, as: UInt32.self)
        var field = entry + 4 + attributeSetSize
        if common & commonError != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += 4
            if error != 0 { return }
        }
        guard common & commonName != 0 else { return }
        let nameOffset = Int(field.loadUnaligned(as: Int32.self))
        let nameLength = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let name = UnsafeRawBufferPointer(start: field + nameOffset, count: max(nameLength - 1, 0))
        field += 8
        var device: Int32 = 0
        if common & commonDevice != 0 {
            device = field.loadUnaligned(as: Int32.self)
            field += 4
        }
        var type: UInt32 = 0
        if common & commonObjectType != 0 {
            type = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var created = Double.nan
        if common & commonCreationTime != 0 {
            created = time(field)
            field += MemoryLayout<timespec>.size
        }
        var modified = Double.nan
        if common & commonModificationTime != 0 {
            modified = time(field)
            field += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if common & commonFlags != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var size: Int64 = 0
        if file & fileDataLength != 0 {
            size = field.loadUnaligned(as: Int64.self)
        }
        guard !name.isEmpty else { return }
        let kind: LightningListing.Kind
        switch type {
        case 1: kind = .file // VREG
        case 2: kind = .directory // VDIR
        case 5: kind = .symlink // VLNK
        default: kind = .other
        }
        listing.append(name: name, kind: kind, size: size, modified: modified, created: created, flags: flags, device: device)
    }

    private static func time(_ pointer: UnsafeRawPointer) -> Double {
        let seconds = pointer.loadUnaligned(as: Int.self)
        let nanoseconds = pointer.loadUnaligned(fromByteOffset: MemoryLayout<Int>.size, as: Int.self)
        return Double(seconds) + Double(nanoseconds) / 1_000_000_000
    }

    private static func readWithStat(_ path: String, into listing: inout LightningListing) -> Int32 {
        guard let directory = opendir(path) else { return errno }
        defer { closedir(directory) }
        let descriptor = dirfd(directory)
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            var nameBuffer = entry.pointee.d_name
            withUnsafeBytes(of: &nameBuffer) { raw in
                let name = UnsafeRawBufferPointer(rebasing: raw[0..<length])
                if (length == 1 && name[0] == 0x2E) || (length == 2 && name[0] == 0x2E && name[1] == 0x2E) { return }
                var info = stat()
                guard fstatat(descriptor, raw.baseAddress!.assumingMemoryBound(to: CChar.self), &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                let kind: LightningListing.Kind
                switch info.st_mode & S_IFMT {
                case S_IFREG: kind = .file
                case S_IFDIR: kind = .directory
                case S_IFLNK: kind = .symlink
                default: kind = .other
                }
                listing.append(name: name, kind: kind, size: Int64(info.st_size),
                               modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                               created: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9,
                               flags: info.st_flags, device: info.st_dev)
            }
        }
        return 0
    }
}

/// What the crawler skips. Paths are canonical (`realpath`) absolute paths.
struct LightningCrawlRules {
    var excludedPaths: Set<String>
    var excludedNames: Set<[UInt8]>
    /// Folders that are indexed themselves but not descended into (node_modules, .git).
    var contentsExcludedNames: Set<[UInt8]>
    var includesHiddenFiles: Bool
    var descendsIntoPackages: Bool
    /// Parent path → names excluded inside it, derived from `excludedPaths`.
    let excludedChildren: [String: Set<[UInt8]>]
    /// Lengths of all excluded names, a cheap pre-check before hashing a name.
    let excludedNameLengths: Set<Int>
    /// Devices of the sealed system volume and its data volume. Firmlinks (/Users, /Applications, /private …)
    /// join them into one tree, so a crawl from "/" passes between them; it never enters other volumes.
    /// (Recent macOS reports one device number for both, older releases two.)
    let systemDevices: Set<Int32>
    /// Where the data volume is mounted; its contents already appear through the firmlinks, so the crawl
    /// never descends into it.
    static let dataVolumePath = "/System/Volumes/Data"

    init(excludedPaths: Set<String>, excludedNames: Set<String>, contentsExcludedNames: Set<String>,
         includesHiddenFiles: Bool, descendsIntoPackages: Bool) {
        var system = stat(), data = stat()
        let hasDataVolume = stat("/", &system) == 0 && stat(Self.dataVolumePath, &data) == 0
        systemDevices = hasDataVolume ? [system.st_dev, data.st_dev] : []
        var excludedPaths = excludedPaths
        if hasDataVolume { excludedPaths.insert(Self.dataVolumePath) }
        self.excludedPaths = excludedPaths
        self.excludedNames = Set(excludedNames.map { Array($0.utf8) })
        self.contentsExcludedNames = Set(contentsExcludedNames.map { Array($0.utf8) })
        self.includesHiddenFiles = includesHiddenFiles
        self.descendsIntoPackages = descendsIntoPackages
        var children: [String: Set<[UInt8]>] = [:]
        for path in excludedPaths where path != "/" {
            let parent = (path as NSString).deletingLastPathComponent
            children[parent, default: []].insert(Array((path as NSString).lastPathComponent.utf8))
        }
        excludedChildren = children
        excludedNameLengths = Set(self.excludedNames.map(\.count) + children.values.flatMap { $0.map(\.count) })
    }

    /// Whether a folder on `device` continues the tree of a parent on `parentDevice`.
    func sameTree(_ device: Int32, as parentDevice: Int32) -> Bool {
        device == parentDevice || (systemDevices.contains(device) && systemDevices.contains(parentDevice))
    }

    /// True when an event below `path` cannot change the index (an excluded or never-descended area).
    func ignoresChanges(at path: String, root: String) -> Bool {
        if excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        let relative = root == "/" ? String(path.dropFirst()) : String(path.dropFirst(root.count + 1))
        let components = relative.split(separator: "/")
        for (index, component) in components.enumerated() {
            let bytes = Array(component.utf8)
            if excludedNames.contains(bytes) { return true }
            if !includesHiddenFiles, component.hasPrefix(".") { return true }
            let isLast = index == components.count - 1
            if !isLast {
                if contentsExcludedNames.contains(bytes) { return true }
                if !descendsIntoPackages, LightningPackages.isPackage(name: bytes) { return true }
            }
        }
        return false
    }
}

/// Package (bundle) detection by extension: a fixed list, then the registered UTType.
enum LightningPackages {
    private static let known: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "qlgenerator", "mdimporter", "prefpane",
        "saver", "component", "vst", "vst3", "aaxplugin", "dsym", "xcarchive", "xcodeproj", "xcworkspace",
        "playground", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx",
        "band", "rtfd", "pages", "numbers", "key", "workflow", "action", "scptd", "lpdf", "pkg", "mpkg",
        "docarchive", "xcassets", "momd", "storyboardc", "nib", "wdgt", "photolibrary", "aplibrary", "theater",
    ]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func isPackage<Bytes: BidirectionalCollection>(name: Bytes) -> Bool where Bytes.Element == UInt8 {
        guard let dot = name.lastIndex(of: 0x2E), dot != name.startIndex else { return false }
        let ext = String(decoding: name[name.index(after: dot)...], as: UTF8.self).lowercased()
        guard !ext.isEmpty, ext.count <= 24 else { return false }
        if known.contains(ext) { return true }
        lock.lock()
        if let cached = cache[ext] { lock.unlock(); return cached }
        lock.unlock()
        let result = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        lock.lock()
        cache[ext] = result
        lock.unlock()
        return result
    }
}

enum LightningCrawlOutcome: Equatable {
    case completed
    case limited(LightningIndexLimit)
    case cancelled
}

struct LightningCrawlLimits {
    var maximumEntries: Int
    var deadline: ContinuousClock.Instant?
    var maximumMemoryBytes: Int
}

/// Walks directory trees in parallel and appends every entry to a storage. Parents are always
/// appended before their children.
final class LightningCrawler: @unchecked Sendable {
    struct Job {
        var index: Int32
        var path: String
        var device: Int32
    }

    private let rules: LightningCrawlRules
    private let limits: LightningCrawlLimits
    private let threadCount: Int
    private let condition = NSCondition()
    private var storage: LightningStorage
    private var stack: [Job]
    private var active = 0
    private var outcome: LightningCrawlOutcome?
    private var visitedDirectories = 0
    private(set) var unreadableDirectories = 0

    init(storage: LightningStorage, jobs: [Job], rules: LightningCrawlRules, limits: LightningCrawlLimits, threadCount: Int) {
        self.storage = storage
        self.stack = jobs.reversed()
        self.rules = rules
        self.limits = limits
        self.threadCount = max(1, threadCount)
    }

    /// Runs the crawl on `threadCount` threads and returns the filled storage.
    func run(isCancelled: () -> Bool, progress: (Int) -> Void) -> (LightningStorage, LightningCrawlOutcome) {
        DispatchQueue.concurrentPerform(iterations: threadCount) { _ in
            work(isCancelled: isCancelled, progress: progress)
        }
        condition.lock()
        defer { condition.unlock() }
        let result = storage
        storage = LightningStorage()
        return (result, outcome ?? .completed)
    }

    private func work(isCancelled: () -> Bool, progress: (Int) -> Void) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: LightningDirectoryReader.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var listing = LightningListing()
        var batch = Batch()
        while true {
            condition.lock()
            while stack.isEmpty, active > 0, outcome == nil { condition.wait() }
            if outcome != nil || stack.isEmpty {
                condition.broadcast()
                condition.unlock()
                return
            }
            let job = stack.removeLast()
            active += 1
            condition.unlock()

            listing.removeAll()
            let error = LightningDirectoryReader.read(job.path, into: &listing, buffer: buffer)
            // Package detection may consult UTType, whose temporaries need a pool on these long-lived threads.
            autoreleasepool { prepare(listing, under: job, into: &batch) }

            condition.lock()
            active -= 1
            if error != 0, error != ENOENT, error != ENOTDIR { unreadableDirectories += 1 }
            if outcome == nil { commit(batch, from: listing, under: job) }
            visitedDirectories += 1
            if outcome == nil, visitedDirectories % 32 == 0 {
                if isCancelled() {
                    outcome = .cancelled
                } else if let deadline = limits.deadline, ContinuousClock.now > deadline {
                    outcome = .limited(.elapsedTime)
                } else if storage.estimatedMemoryBytes > limits.maximumMemoryBytes {
                    outcome = .limited(.memory)
                }
                progress(storage.count)
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Children of one listing that passed the rules, with names already folded.
    private struct Batch {
        struct Entry {
            var listingIndex: Int
            var flags: UInt8
            var ascii: Bool
            /// Range in `folded`, or nil when the folded name equals the raw name.
            var folded: Range<Int>?
            var childPath: String?
        }

        var entries: [Entry] = []
        var folded: [UInt8] = []

        mutating func removeAll() {
            entries.removeAll(keepingCapacity: true)
            folded.removeAll(keepingCapacity: true)
        }
    }

    /// Applies the rules and folds names without holding the lock.
    private func prepare(_ listing: LightningListing, under job: Job, into batch: inout Batch) {
        batch.removeAll()
        let excludedHere = rules.excludedChildren[job.path]
        let prefix = job.path == "/" ? "/" : job.path + "/"
        listing.names.withUnsafeBufferPointer { names in
            for index in 0..<listing.count {
                let name = UnsafeBufferPointer(rebasing: names[listing.nameStart[index]..<(listing.nameStart[index] + listing.nameCount[index])])
                if rules.excludedNameLengths.contains(name.count) {
                    let bytes = Array(name)
                    if rules.excludedNames.contains(bytes) || excludedHere?.contains(bytes) == true { continue }
                }
                let hidden = listing.hidden[index]
                if hidden, !rules.includesHiddenFiles { continue }
                var flags: UInt8 = hidden ? LightningEntryFlag.hidden : 0
                var childPath: String?
                switch listing.kind[index] {
                case .directory:
                    flags |= LightningEntryFlag.directory
                    let package = LightningPackages.isPackage(name: name)
                    if package { flags |= LightningEntryFlag.package }
                    if (!package || rules.descendsIntoPackages), rules.sameTree(listing.device[index], as: job.device),
                       !rules.contentsExcludedNames.contains(Array(name)) {
                        let path = prefix + String(decoding: name, as: UTF8.self)
                        if !rules.excludedPaths.contains(path) { childPath = path }
                    }
                case .symlink:
                    flags |= LightningEntryFlag.symlink
                case .file, .other:
                    break
                }
                let (folded, ascii) = LightningStorage.fold(name)
                var range: Range<Int>?
                if let folded {
                    range = batch.folded.count..<(batch.folded.count + folded.count)
                    batch.folded.append(contentsOf: folded)
                }
                batch.entries.append(Batch.Entry(listingIndex: index, flags: flags, ascii: ascii, folded: range, childPath: childPath))
            }
        }
    }

    /// Appends a prepared batch below `job` (lock held).
    private func commit(_ batch: Batch, from listing: LightningListing, under job: Job) {
        listing.names.withUnsafeBufferPointer { names in
            batch.folded.withUnsafeBufferPointer { folded in
                for item in batch.entries {
                    if storage.count >= limits.maximumEntries {
                        outcome = .limited(.entries)
                        return
                    }
                    let index = item.listingIndex
                    let name = UnsafeBufferPointer(rebasing: names[listing.nameStart[index]..<(listing.nameStart[index] + listing.nameCount[index])])
                    let entry = storage.append(name: name, folded: item.folded.map { UnsafeBufferPointer(rebasing: folded[$0]) },
                                               ascii: item.ascii, parent: job.index, flags: item.flags, size: listing.size[index],
                                               modified: listing.modified[index], created: listing.created[index])
                    if let childPath = item.childPath {
                        stack.append(Job(index: entry, path: childPath, device: listing.device[index]))
                    }
                }
            }
        }
    }
}
