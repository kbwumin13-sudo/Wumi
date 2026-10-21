import Darwin
import Foundation
import UniformTypeIdentifiers

/// File Transit's rules on top of `FileTransitShelf` and `FileTransitRepository`: adding and importing under the
/// limits, restorable removal, cleanup of managed content once records are finally removed, and saving after
/// every change.
///
/// Not thread-safe: the app drives one instance from a serial queue (all file work stays off the main thread).
public final class FileTransitService {
    /// Something to tell the user once after loading.
    public enum LoadNotice: Equatable, Sendable {
        /// The saved data could not be read; the shelf started empty.
        case unreadableDataReplaced
        /// A newer schema version saved the data; the shelf is empty and read-only and the file stays untouched.
        case newerVersion(Int)
        /// Damaged records were left out.
        case invalidRecordsDropped(Int)
    }

    public let repository: FileTransitRepository
    public let limits: FileTransitLimits
    public var naming: FileTransitNaming
    public private(set) var shelf: FileTransitShelf
    public private(set) var isReadOnly = false
    public private(set) var loadNotice: LoadNotice?
    /// True when no document existed before this launch.
    public private(set) var startedWithoutDocument = false
    private let fileManager: FileManager
    private let clock: () -> Date

    public init(repository: FileTransitRepository, limits: FileTransitLimits = .standard, naming: FileTransitNaming = FileTransitNaming(),
                fileManager: FileManager = .default, clock: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.limits = limits
        self.naming = naming
        self.fileManager = fileManager
        self.clock = clock
        shelf = FileTransitShelf()
        switch repository.load() {
        case .missing:
            startedWithoutDocument = true
        case .loaded(let loaded, let invalid):
            shelf = loaded
            if invalid > 0 {
                loadNotice = .invalidRecordsDropped(invalid)
                try? repository.save(shelf, at: clock())
            }
        case .unreadable:
            loadNotice = .unreadableDataReplaced
            try? repository.save(shelf, at: clock())
        case .newerVersion(let version):
            isReadOnly = true
            loadNotice = .newerVersion(version)
        }
        if !isReadOnly { repository.clearIncoming() }
    }

    public var managedRootURL: URL { repository.managedRootURL }

    // MARK: Adding

    /// Adds sources as one stack (`stackID`, or a new stack). Sources that do not fit or cannot be read are
    /// reported in `failures`; content written for them is deleted again.
    @discardableResult
    public func add(_ sources: [FileTransitSource], stackID: UUID? = nil) -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else {
            sources.forEach(discard)
            change.failures.append(.readOnly)
            return change
        }
        let stack = stackID ?? UUID()
        let now = clock()
        var prepared: [FileTransitItem] = []
        var references = Set(shelf.items.compactMap(\.originalPath))
        var pendingManagedBytes: Int64 = 0
        var historyChanged = false

        for source in sources {
            guard shelf.items.count + prepared.count < limits.maximumItemCount else {
                discard(source)
                change.failures.append(.shelfFull)
                continue
            }
            do {
                if case .file(let url) = source {
                    let item = try reference(url, stackID: stack, at: now)
                    guard let path = item.originalPath, references.insert(path).inserted else {
                        change.skippedDuplicates += 1
                        continue
                    }
                    prepared.append(item)
                } else {
                    let item = try importContent(source, stackID: stack, at: now, pending: &pendingManagedBytes, historyChanged: &historyChanged)
                    prepared.append(item)
                }
            } catch let error as FileTransitError {
                discard(source)
                change.failures.append(error)
            } catch {
                discard(source)
                change.failures.append(.importFailed)
            }
        }
        guard !prepared.isEmpty || historyChanged else { return change }
        shelf.insert(prepared)
        change.added = prepared.map(\.id)
        persist(&change)
        return change
    }

    /// Adds records carried over from an older store (only into an empty shelf).
    @discardableResult
    public func adoptLegacyRecords(_ items: [FileTransitItem]) -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly, shelf.items.isEmpty, !items.isEmpty else { return change }
        let accepted = Array(items.filter(FileTransitRepository.isValid).prefix(limits.maximumItemCount))
        shelf.insert(accepted)
        change.added = accepted.map(\.id)
        persist(&change)
        return change
    }

    private func reference(_ url: URL, stackID: UUID, at date: Date) throws -> FileTransitItem {
        guard url.isFileURL else { throw FileTransitError.unsupportedItem }
        let standardized = url.standardizedFileURL
        var info = stat()
        guard lstat(standardized.path, &info) == 0 else { throw FileTransitError.unsupportedItem }
        let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let name = standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
        return FileTransitItem(kind: isFolder ? .directory : .file, stackID: stackID, addedAt: date, name: name,
                               originalPath: standardized.path, contentType: values?.contentType?.identifier)
    }

    private func importContent(_ source: FileTransitSource, stackID: UUID, at date: Date,
                               pending: inout Int64, historyChanged: inout Bool) throws -> FileTransitItem {
        let id = UUID()
        switch source {
        case .file:
            throw FileTransitError.unsupportedItem
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileTransitError.unsupportedItem }
            let data = Data(text.utf8)
            try reserve(Int64(data.count), pending: &pending, historyChanged: &historyChanged)
            let name = FileTransitRepository.textFileName(for: text, fallback: naming.text)
            let path = try write(id: id, name: name, data: data)
            return FileTransitItem(id: id, kind: .text, stackID: stackID, addedAt: date, name: name, managedPath: path,
                                   managedByteCount: Int64(data.count), contentType: UTType.utf8PlainText.identifier)
        case .image(let raw, let typeIdentifier, let proposedName):
            if Int64(raw.count) > limits.maximumImportBytes { throw FileTransitError.importLimitExceeded }
            guard let image = FileTransitRepository.storableImage(raw, typeIdentifier: typeIdentifier) else { throw FileTransitError.unsupportedItem }
            try reserve(Int64(image.data.count), pending: &pending, historyChanged: &historyChanged)
            let stem = proposedName.map { ($0 as NSString).deletingPathExtension } ?? ""
            let name = FileTransitRepository.safeFileName(stem, fallback: naming.image, pathExtension: image.type.preferredFilenameExtension ?? "png")
            let path = try write(id: id, name: name, data: image.data)
            return FileTransitItem(id: id, kind: .image, stackID: stackID, addedAt: date, name: name, managedPath: path,
                                   managedByteCount: Int64(image.data.count), contentType: image.type.identifier)
        case .link(let url, let title):
            guard !url.isFileURL, let scheme = url.scheme, !scheme.isEmpty else { throw FileTransitError.unsupportedItem }
            let data = try FileTransitRepository.weblocData(for: url)
            try reserve(Int64(data.count), pending: &pending, historyChanged: &historyChanged)
            var host = url.host ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let proposed = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? host
            let name = FileTransitRepository.safeFileName(proposed, fallback: naming.link, pathExtension: "webloc")
            let path = try write(id: id, name: name, data: data)
            return FileTransitItem(id: id, kind: .link, stackID: stackID, addedAt: date, name: name, managedPath: path,
                                   managedByteCount: Int64(data.count), linkURL: url, contentType: "com.apple.web-internet-location")
        case .receivedFile(let url):
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw FileTransitError.importFailed }
            let size = repository.byteCount(of: url, limit: limits.maximumImportBytes)
            try reserve(size, pending: &pending, historyChanged: &historyChanged)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
            let type = values?.contentType
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            let kind: FileTransitItemKind = isFolder ? .directory : (type?.conforms(to: .image) == true ? .image : .file)
            let name = FileTransitRepository.safeFileName(url.lastPathComponent, fallback: naming.file)
            let path: String
            do {
                path = try repository.adoptManaged(id: id, fileName: name, from: url)
            } catch {
                throw FileTransitError.importFailed
            }
            repository.removeIncomingFolderIfEmpty(containing: url)
            return FileTransitItem(id: id, kind: kind, stackID: stackID, addedAt: date, name: name, managedPath: path,
                                   managedByteCount: size, contentType: type?.identifier)
        }
    }

    private func write(id: UUID, name: String, data: Data) throws -> String {
        do {
            return try repository.writeManaged(id: id, fileName: name, data: data)
        } catch {
            throw FileTransitError.importFailed
        }
    }

    /// Checks one import against the per-import limit and the storage limit. Content of removed records is
    /// dropped from the restore history, oldest first, when it is all that stands in the way.
    private func reserve(_ bytes: Int64, pending: inout Int64, historyChanged: inout Bool) throws {
        guard bytes <= limits.maximumImportBytes else { throw FileTransitError.importLimitExceeded }
        let needed = pending + bytes
        guard shelf.liveManagedBytes + needed <= limits.maximumManagedBytes else { throw FileTransitError.managedStorageFull }
        if shelf.liveManagedBytes + shelf.retainedManagedBytes + needed > limits.maximumManagedBytes {
            let purged = shelf.purgeRemovedContent(keepingAtMost: limits.maximumManagedBytes - needed)
            repository.deleteManagedContent(of: purged)
            historyChanged = historyChanged || !purged.isEmpty
        }
        pending = needed
    }

    /// Received files that were not adopted are deleted from the incoming folder.
    private func discard(_ source: FileTransitSource) {
        guard case .receivedFile(let url) = source, repository.isIncoming(url) else { return }
        try? fileManager.removeItem(at: url)
        repository.removeIncomingFolderIfEmpty(containing: url)
    }

    // MARK: Removing and restoring

    /// Removes records; they stay restorable until they drop out of the restore history.
    @discardableResult
    public func remove(_ ids: Set<UUID>) -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else { return failed(.readOnly) }
        let existing = ids.filter { shelf.item(withID: $0) != nil }
        guard !existing.isEmpty else { return failed(.itemMissing) }
        removeRecords(existing, into: &change)
        return change
    }

    @discardableResult
    public func removeStack(_ stackID: UUID) -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else { return failed(.readOnly) }
        let ids = Set(shelf.items(inStack: stackID).map(\.id))
        guard !ids.isEmpty else { return failed(.stackMissing) }
        removeRecords(ids, into: &change)
        return change
    }

    /// Removes every record that is not locked.
    @discardableResult
    public func clearUnlocked() -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else { return failed(.readOnly) }
        let ids = Set(shelf.items.filter { !$0.isLocked }.map(\.id))
        if !ids.isEmpty { removeRecords(ids, into: &change) }
        return change
    }

    /// After a move drag or "Export & Clear": removes the transferred records that are not locked.
    @discardableResult
    public func completeTransfer(of ids: Set<UUID>) -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else { return failed(.readOnly) }
        let unlocked = Set(shelf.items.filter { ids.contains($0.id) && !$0.isLocked }.map(\.id))
        if !unlocked.isEmpty { removeRecords(unlocked, into: &change) }
        return change
    }

    @discardableResult
    public func restoreRecentlyRemoved() -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else { return failed(.readOnly) }
        do {
            change.restored = try shelf.restoreLatest(limits: limits).map(\.id)
        } catch let error as FileTransitError {
            return failed(error)
        } catch {
            return failed(.nothingToRestore)
        }
        persist(&change)
        return change
    }

    private func removeRecords(_ ids: Set<UUID>, into change: inout FileTransitChange) {
        let result = shelf.remove(ids, at: clock(), limits: limits)
        repository.deleteManagedContent(of: result.purged)
        change.removed = result.removed.map(\.id)
        persist(&change)
    }

    // MARK: Locks and stacks

    @discardableResult
    public func setLocked(_ ids: Set<UUID>, locked: Bool) -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else { return failed(.readOnly) }
        guard shelf.setLocked(ids, to: locked) > 0 else { return failed(.itemMissing) }
        persist(&change)
        return change
    }

    @discardableResult
    public func toggleLock(_ id: UUID) -> FileTransitChange {
        guard let item = shelf.item(withID: id) else { return failed(isReadOnly ? .readOnly : .itemMissing) }
        return setLocked([id], locked: !item.isLocked)
    }

    /// "Separate items": every record of the stack becomes its own stack.
    @discardableResult
    public func separate(_ stackID: UUID) -> FileTransitChange {
        var change = FileTransitChange()
        guard !isReadOnly else { return failed(.readOnly) }
        guard shelf.separate(stackID) else { return failed(.stackMissing) }
        persist(&change)
        return change
    }

    // MARK: Helpers

    private func failed(_ error: FileTransitError) -> FileTransitChange {
        var change = FileTransitChange()
        change.failures = [error]
        return change
    }

    private func persist(_ change: inout FileTransitChange) {
        do {
            try repository.save(shelf, at: clock())
        } catch {
            change.saveFailed = true
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
