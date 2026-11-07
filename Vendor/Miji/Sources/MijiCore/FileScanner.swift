import Foundation
import Darwin

public struct ScanOptions: Sendable, Codable, Equatable {
    public var includeHidden = true
    public var excludeDevelopmentCaches = false
    public init(includeHidden: Bool = true, excludeDevelopmentCaches: Bool = false) { self.includeHidden=includeHidden; self.excludeDevelopmentCaches=excludeDevelopmentCaches }
}
public struct ScanResult: Sendable {
    public var count: Int
    public var complete: Bool
    public var errors: [String]
    public var preservingPaths: [String] = []
}

public enum VolumeIdentity {
    public static func root(for url: URL) throws -> IndexedRoot {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .volumeURLKey, .volumeIsInternalKey, .volumeIsRemovableKey])
        guard values.isDirectory == true else { throw NSError(domain: "Miji", code: 1, userInfo: [NSLocalizedDescriptionKey:"请选择文件夹或磁盘。"] ) }
        let volumePath = (values.allValues[.volumeURLKey] as? URL)?.path ?? "/"
        let relative = url.path == volumePath ? "" : String(url.path.dropFirst(volumePath == "/" ? 1 : volumePath.count + 1))
        return IndexedRoot(path: url.path, volumeUUID: values.volumeUUIDString, volumeRelativePath: relative, isExternal: values.volumeIsInternal == false || values.volumeIsRemovable == true || url.path.hasPrefix("/Volumes/"))
    }
    public static func refreshed(_ root: IndexedRoot) -> IndexedRoot {
        var root = root
        let manager = FileManager.default
        var candidate = URL(fileURLWithPath: root.path).standardizedFileURL.resolvingSymlinksInPath()
        root.path = candidate.path
        if root.isExternal, let uuid = root.volumeUUID {
            let mounts = manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
            if let mount = mounts.first(where: { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid }) {
                candidate = root.volumeRelativePath.isEmpty ? mount : mount.appendingPathComponent(root.volumeRelativePath)
                root.path = candidate.path
            } else { root.isOnline = false; return root }
        }
        var directory: ObjCBool = false
        root.isOnline = manager.fileExists(atPath: candidate.path, isDirectory: &directory) && directory.boolValue
        if root.isOnline, let expected = root.volumeUUID, let actual = try? candidate.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString, expected != actual { root.isOnline = false }
        return root
    }
    public static func externalVolumes() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey,.volumeIsRemovableKey,.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? []).filter {
            let v = try? $0.resourceValues(forKeys: [.volumeIsInternalKey,.volumeIsRemovableKey,.volumeIsBrowsableKey])
            return $0.path.hasPrefix("/Volumes/") && v?.volumeIsBrowsable != false && (v?.volumeIsInternal == false || v?.volumeIsRemovable == true)
        }
    }
}

// The boot volume's logical tree includes Data firmlinks. Other roots retain
// their volume boundary; physical mount aliases are never followed from /.
struct ScanVolumePolicy {
    let root: IndexedRoot
    let dataVolumeUUID: String?
    init(root: IndexedRoot, dataVolumeUUID: String? = nil) {
        self.root = root
        self.dataVolumeUUID = dataVolumeUUID ?? (try? URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    }
    func skipsDirectory(path: String, volumeUUID: String?) -> Bool {
        if root.path == "/" {
            if path == "/.nofollow" || path.hasPrefix("/.nofollow/") || path == "/System/Volumes" || path.hasPrefix("/System/Volumes/") || path == "/Volumes" || path.hasPrefix("/Volumes/") { return true }
            if let volumeUUID, volumeUUID == dataVolumeUUID { return false }
        }
        if let expected = root.volumeUUID, let actual = volumeUUID { return expected != actual }
        return false
    }
}

/// The stack stores directories, not every file. A restart repeats only the
/// current directory; completed directories retain their committed generation.
struct FileScanCheckpoint: Codable {
    var rootPath: String
    var scope: String
    var options: ScanOptions
    var generation: Int64
    var directories: [String] = []
    var currentDirectory: String?
    var started = false
    var count = 0
    var errors: [String] = []
    var preservingPaths: Set<String> = []

    func matches(root: IndexedRoot, scope: String, options: ScanOptions) -> Bool {
        rootPath == root.path && self.scope == scope && self.options == options && generation > 0
        && IndexRelativePath.validated(scope)
        && (directories + [currentDirectory].compactMap {$0} + Array(preservingPaths)).allSatisfy {
            IndexRelativePath.validated($0) && IndexRelativePath.contains(scope,$0)
        }
    }
}

public final class FileScanner {
    private let database: SearchDatabase
    private let ignoredPaths: [String]
    public init(database: SearchDatabase, ignoredPaths: [String] = []) {
        self.database=database; self.ignoredPaths=ignoredPaths
    }
    public func scan(root: IndexedRoot, options: ScanOptions = ScanOptions(), cancelled: () -> Bool = {false}, progress: (Int) -> Void = {_ in}) throws -> ScanResult {
        try scan(root:root,relativePath:"",options:options,cancelled:cancelled,progress:progress)
    }
    public func scan(root: IndexedRoot, relativePath: String, options: ScanOptions = ScanOptions(), cancelled: () -> Bool = {false}, progress: (Int) -> Void = {_ in}) throws -> ScanResult {
        try session(root:root,relativePath:relativePath,options:options).advance(cancelled:cancelled,progress:progress)
    }
    func session(root: IndexedRoot, relativePath: String, options: ScanOptions) throws -> FileScanSession {
        guard IndexRelativePath.validated(relativePath) else {throw CocoaError(.fileReadInvalidFileName)}
        return FileScanSession(database:database,ignoredPaths:ignoredPaths,root:VolumeIdentity.refreshed(root),scope:IndexRelativePath.packageScope(relativePath),options:options)
    }
}

/// One traversal. The live directory enumerator survives typing, pause and sleep
/// within a process; an interrupted scan restarts from its scope after a relaunch,
/// because pruning relies on the IDs this session saw.
final class FileScanSession {
    private let database: SearchDatabase
    private let pathFilter: IndexPathFilter
    private var root: IndexedRoot
    private let base: URL
    private let volumePolicy: ScanVolumePolicy
    private var enumerator: FileManager.DirectoryEnumerator?
    private var queuedDirectories: Set<String>
    private var batch: [FileRecord] = []
    private let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey,.isPackageKey,.volumeUUIDStringKey,.creationDateKey]
    private let excluded: Set<String> = ["node_modules",".git",".svn",".build",".venv","venv","__pycache__","DerivedData","Pods","Carthage",".Trash",".Trashes",".Spotlight-V100",".fseventsd"]
    private let userLibrary=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
    private let seen:FileIDSet
    // A concurrent scope owns reconciliation of these rows. Its newly inserted
    // IDs may be outside the whole scan's already enumerated directories.
    private var reconciledScopes = Set<String>()
    private(set) var checkpoint: FileScanCheckpoint
    private(set) var finished = false
    private(set) var writes = ScanWriteStatistics()
    private(set) var pruned = 0
    let startedAt = ProcessInfo.processInfo.systemUptime

    init(database: SearchDatabase, ignoredPaths: [String], root: IndexedRoot, scope: String, options: ScanOptions) {
        self.database=database; self.pathFilter=IndexPathFilter(ignoredPaths:ignoredPaths)
        self.root=root; self.base=URL(fileURLWithPath:root.path); self.volumePolicy=ScanVolumePolicy(root:root)
        self.checkpoint=FileScanCheckpoint(rootPath:root.path,scope:scope,options:options,generation:Int64(Date().timeIntervalSince1970*1_000_000))
        // A whole root sees most rows; a subtree scan stays small.
        self.seen=FileIDSet(largestID:scope.isEmpty ? ((try? database.largestFileID()) ?? 0) : 0)
        queuedDirectories=Set(self.checkpoint.directories)
    }
    func matches(root: IndexedRoot, scope: String, options: ScanOptions) -> Bool {
        checkpoint.matches(root:root,scope:IndexRelativePath.packageScope(scope),options:options)
    }
    func preserveReconciledScope(_ scope: String) {
        guard !scope.isEmpty, IndexRelativePath.validated(scope) else { return }
        reconciledScopes.insert(scope)
    }
    private func relative(_ url: URL) -> String? {
        let path=url.standardizedFileURL.path, prefix=root.path == "/" ? "/" : root.path+"/"
        if path == root.path {return ""}
        guard path.hasPrefix(prefix) else {return nil}
        let value=String(path.dropFirst(prefix.count))
        return IndexRelativePath.validated(value) ? value : nil
    }
    private func recordFailure(_ url: URL, _ error: Error) {
        checkpoint.preservingPaths.insert(relative(url) ?? checkpoint.scope)
        if checkpoint.errors.count < 8 {checkpoint.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")}
    }
    private func excludedPath(_ url: URL, relative: String) -> Bool {
        // Enumerated URLs extend the canonical root and never cross a symlink.
        if pathFilter.ignores(canonical:url.path) {return true}
        let parts=relative.split(separator:"/").map(String.init)
        if !checkpoint.options.includeHidden && parts.contains(where:{$0.hasPrefix(".")}) {return true}
        return checkpoint.options.excludeDevelopmentCaches && (parts.contains(where:excluded.contains) || url.path == userLibrary || url.path.hasPrefix(userLibrary+"/"))
    }
    /// Return whether to queue the directory, without traversing packages,
    /// symlinks or physical aliases of the logical boot-volume tree.
    private func visit(_ url: URL) throws -> Bool {
        // Foundation exposes virtual aliases such as /.nofollow/ with no
        // valid relative path. Ignore them as the original traversal did;
        // treating one as a read failure would preserve/requeue the whole root.
        guard let relative=relative(url),!relative.isEmpty else {return false}
        if excludedPath(url,relative:relative) {return false}
        let v=try url.resourceValues(forKeys:keys)
        if v.isSymbolicLink == true {return false}
        if v.isDirectory == true,volumePolicy.skipsDirectory(path:url.path,volumeUUID:v.volumeUUIDString) {return false}
        let kind=FileKind.classify(extension:url.pathExtension,isDirectory:v.isDirectory == true)
        let content=kind == .image || kind == .document || kind == .code
        let available=v.isUbiquitousItem != true || v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded
        let signature=try FileSignature.read(canonical:url)
        batch.append(FileRecord(rootID:root.id,relativePath:relative,name:url.lastPathComponent,fileExtension:url.pathExtension.lowercased(),kind:kind,size:signature.size,modified:signature.modified,inode:signature.inode,contentState:content ? (available ? "pending" : "deferred") : "skipped",contentError:available ? nil : "文件尚未下载到本机",created:v.creationDate?.timeIntervalSince1970,isDirectory:v.isDirectory,isPackage:v.isPackage))
        checkpoint.count += 1
        return v.isDirectory == true && v.isPackage != true
    }
    private func queue(_ url: URL) {
        guard let path=relative(url),queuedDirectories.insert(path).inserted else {return}
        checkpoint.directories.append(path)
    }
    private func flush(_ progress: (Int)->Void) throws {
        if !batch.isEmpty {
            writes += try database.upsertScannedFiles(batch,generation:checkpoint.generation,seen:seen)
            batch.removeAll(keepingCapacity:true)
        }
        progress(checkpoint.count)
    }
    func advance(cancelled: ()->Bool, shouldYield: ()->Bool = { false }, maximumItems: Int = .max, progress: (Int)->Void) throws -> ScanResult {
        let initialCount=checkpoint.count
        root=VolumeIdentity.refreshed(root)
        try database.saveRoot(root)
        guard root.enabled,root.isOnline,root.path == checkpoint.rootPath else {
            return ScanResult(count:checkpoint.count,complete:false,errors:["索引位置未连接或已停用"])
        }
        if !checkpoint.started && !cancelled() {
            let target=checkpoint.scope.isEmpty ? base : base.appendingPathComponent(checkpoint.scope)
            var info=stat()
            if lstat(target.path,&info) == 0 {
                if checkpoint.scope.isEmpty {checkpoint.directories=[""];queuedDirectories.insert("")}
                else {autoreleasepool {do {if try visit(target) {queue(target)}} catch {recordFailure(target,error)}}}
            } else if errno != ENOENT && errno != ENOTDIR {recordFailure(target,NSError(domain:NSPOSIXErrorDomain,code:Int(errno)))}
            checkpoint.started=true
        }
        while !cancelled() && !shouldYield() && checkpoint.count-initialCount < maximumItems {
            if checkpoint.currentDirectory == nil {
                checkpoint.currentDirectory=checkpoint.directories.popLast()
                if let path=checkpoint.currentDirectory {queuedDirectories.remove(path)}
            }
            guard let directory=checkpoint.currentDirectory else {break}
            try autoreleasepool {
                if enumerator == nil {
                    let url=directory.isEmpty ? base : base.appendingPathComponent(directory)
                    // Do not follow a directory that became a symlink while we
                    // were suspended. A missing directory is reconciled at end.
                    var info=stat()
                    if lstat(url.path,&info) != 0 {
                        if errno != ENOENT && errno != ENOTDIR {recordFailure(url,NSError(domain:NSPOSIXErrorDomain,code:Int(errno)))}
                        checkpoint.currentDirectory=nil;return
                    }
                    guard (info.st_mode & S_IFMT) == S_IFDIR else {checkpoint.currentDirectory=nil;return}
                    var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants,.skipsPackageDescendants]
                    if !checkpoint.options.includeHidden {options.insert(.skipsHiddenFiles)}
                    enumerator=FileManager.default.enumerator(at:url,includingPropertiesForKeys:Array(keys),options:options,errorHandler:{[weak self] url,error in self?.recordFailure(url,error);return true})
                    if enumerator == nil {recordFailure(url,CocoaError(.fileReadNoPermission));checkpoint.currentDirectory=nil;return}
                }
                guard let url=enumerator?.nextObject() as? URL else {enumerator=nil;checkpoint.currentDirectory=nil;return}
                do {if try visit(url) {queue(url)}} catch {recordFailure(url,error)}
                if batch.count >= 300 {try flush(progress)}
            }
        }
        try autoreleasepool {try flush(progress)}
        root=VolumeIdentity.refreshed(root)
        let reachedEnd=checkpoint.started && checkpoint.currentDirectory == nil && checkpoint.directories.isEmpty && !cancelled() && root.isOnline
        if reachedEnd {
            if checkpoint.scope.isEmpty {
                pruned=try database.finishScan(rootID:root.id,seen:seen,preservingPaths:Array(checkpoint.preservingPaths.union(reconciledScopes)))
                if checkpoint.errors.isEmpty {root.lastScan=Date()}
            } else {
                pruned=try database.finishIncrementalScan(rootID:root.id,relativePath:checkpoint.scope,seen:seen,preservingPaths:Array(checkpoint.preservingPaths.union(reconciledScopes)))
            }
            finished=true
        }
        root.lastError=checkpoint.errors.isEmpty ? nil : checkpoint.errors.joined(separator:"\n")
        try database.saveRoot(root)
        return ScanResult(count:checkpoint.count,complete:finished && checkpoint.errors.isEmpty,errors:checkpoint.errors,preservingPaths:Array(checkpoint.preservingPaths))
    }
}
