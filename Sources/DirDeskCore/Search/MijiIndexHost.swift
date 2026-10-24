import Foundation
import MijiCore

/// Sole owner of a target catalog's writer, incremental scanner and watcher.
/// Construction opens only the explicit target; there is no implicit import of Miji's source index.
public final class MijiIndexHost: @unchecked Sendable {
    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("DirDesk/Miji/index.sqlite")
    }
    public let engine:MijiSearchBackend
    public let readOnly:Bool
    private let database:SearchDatabase
    private var lease:DatabaseLease?
    private var service:IndexService?
    private let lock=NSLock()
    private var current=LightningIndexStatus(stage:.loadingSnapshot)
    private var stopped=false
    private var observer:((LightningIndexStatus)->Void)?
    private var catalogObserver:(()->Void)?
    // Status reaches observers at most once a second; the latest value always arrives.
    private let delivery=DispatchQueue(label:"wumi.miji.status",qos:.utility)
    private var deliveryScheduled=false
    private var lastDelivery:TimeInterval = -.infinity
    private var compactionScheduled=false
    public var onCatalogChange:(()->Void)? {
        get {lock.lock();defer{lock.unlock()};return catalogObserver}
        set {lock.lock();catalogObserver=newValue;lock.unlock()}
    }
    public var onStatus:((LightningIndexStatus)->Void)? {
        get {lock.lock();defer{lock.unlock()};return observer}
        set {lock.lock();observer=newValue;lock.unlock()}
    }
    public var status:LightningIndexStatus {lock.lock();defer{lock.unlock()};return current}

    public init(databaseURL:URL,readOnly:Bool=false,ignoredPaths:[String]=[],extractionWorker:URL?=nil) throws {
        self.readOnly=readOnly
        lease=try DatabaseLease(databaseURL:databaseURL)
        database=try SearchDatabase(url:databaseURL,readOnly:readOnly)
        let names=try NameSearchEngine(databaseURL:databaseURL,persistsCache:!readOnly)
        try names.load()
        engine=MijiSearchBackend(databaseURL:databaseURL,names:names,ignoredPaths:ignoredPaths,allowsTemporaryScopes:!readOnly)
        current=LightningIndexStatus(stage:.ready,indexedCount:names.indexedCount)
        if !readOnly {
            guard let extractionWorker,FileManager.default.isExecutableFile(atPath:extractionWorker.path) else {
                throw SearchDatabaseError(message:"缺少 miji-extract 内容提取 helper")
            }
            let runtime=IndexService(database:database,ignoredPaths:ignoredPaths+[databaseURL.deletingLastPathComponent().path],extractionWorker:extractionWorker)
            service=runtime
            runtime.onIndexChange={ [weak self] change in
                guard let self else {return}
                do {
                    try names.refresh(rootID:change.rootID,relativePaths:change.relativePaths,fullRescan:change.fullRescan)
                } catch {
                    do {try names.load()} catch {self.publish(error:error.localizedDescription)}
                }
                self.compactNamesIfNeeded()
                self.publish()
                self.catalogChanged()
            }
            runtime.onProgress={ [weak self] progress in
                self?.publish(updating:progress.busy,error:progress.phase.contains("问题") || progress.phase.contains("无法") ? progress.detail : nil)
            }
            runtime.onChange={ [weak self] in self?.publish();self?.catalogChanged() }
        }
        engine.onError={ [weak self] in self?.publish(error:$0) }
    }

    /// Called only after the host is installed. No scanner is started by init.
    public func start(watchedFolders:[String],ignoredFolders:[String],updateRoots:Bool=false,
                      preferences:IndexingPreferences=IndexingPreferences()) throws {
        engine.retainsOffline=preferences.retainOffline
        guard !readOnly else {return}
        let existing=try database.roots()
        let configured=LightningIndex.outermost(watchedFolders)
        if updateRoots {
            for var root in existing where !root.isExternal {
                root.enabled=configured.contains(root.path)
                try database.saveRoot(root)
            }
        }
        // A migrated catalog is authoritative. Wumi defaults never add or prune its roots.
        if existing.isEmpty || updateRoots {
            for path in configured where !existing.contains(where:{$0.path==path}) {
                try database.saveRoot(VolumeIdentity.root(for:URL(fileURLWithPath:path)))
            }
        }
        engine.retainsOffline=preferences.retainOffline
        service?.configure(preferences)
        if updateRoots {service?.requestScan()}
        service?.start()
    }
    public func roots() throws -> [IndexedRoot] {try database.roots()}
    public func configure(_ preferences:IndexingPreferences) {
        engine.retainsOffline=preferences.retainOffline
        guard !readOnly else {return};service?.configure(preferences)
    }
    public func setRootEnabled(id:String,enabled:Bool,completion:@escaping(Error?)->Void={_ in}) {
        guard !readOnly else {completion(SearchDatabaseError(message:"只读索引不能修改根设置"));return}
        service?.mutate({db in
            guard var root=try db.roots().first(where:{$0.id==id}) else {return}
            root.enabled=enabled;try db.saveRoot(root)
        },completion:completion)
    }

    public func rebuildIndex() {guard !readOnly else {return};engine.discardTemporaryIndexes();service?.requestScan()}

    /// Wait for the original Miji worker to stop (including its helper), then persist names.
    public func shutdown() {
        lock.lock();if stopped {lock.unlock();return};stopped=true;lock.unlock()
        service?.stopAndWait()
        if !readOnly {try? engine.names.saveCache()}
        service=nil;engine.discardTemporaryIndexes();lease=nil
    }
    deinit {shutdown()}
    private func catalogChanged() {
        lock.lock();let callback=stopped ? nil : catalogObserver;lock.unlock();callback?()
    }

    public static func backup(from source:URL,to target:URL,isCancelled:()->Bool={false}) throws {
        let lease=try DatabaseLease(databaseURL:target)
        try withExtendedLifetime(lease) {try SearchDatabase.backup(from:source,to:target,cancelled:isCancelled)}
    }

    /// Moves name rows that accumulated in memory back into a cache mapping. Runs off
    /// the index queue at utility QoS, because searches wait while it rewrites the cache.
    private func compactNamesIfNeeded() {
        guard engine.names.needsCompaction else {return}
        lock.lock()
        guard !stopped,!compactionScheduled else {lock.unlock();return}
        compactionScheduled=true;lock.unlock()
        delivery.async { [weak self] in
            guard let self else {return}
            do {try self.engine.names.compact()} catch {self.publish(error:error.localizedDescription)}
            self.lock.lock();self.compactionScheduled=false;self.lock.unlock()
        }
    }

    private func publish(updating:Bool?=nil,error:String?=nil) {
        let count=engine.names.indexedCount
        lock.lock()
        guard !stopped else {lock.unlock();return}
        current.indexedCount=count
        if let updating {current.isUpdating=updating}
        if let error {current.lastError=error}
        guard !deliveryScheduled else {lock.unlock();return}
        deliveryScheduled=true
        let wait=max(0,lastDelivery+1-ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        delivery.asyncAfter(deadline:.now()+wait) { [weak self] in
            guard let self else {return}
            self.lock.lock()
            self.deliveryScheduled=false
            self.lastDelivery=ProcessInfo.processInfo.systemUptime
            let value=self.current, callback=self.stopped ? nil : self.observer
            self.lock.unlock()
            callback?(value)
        }
    }
}
