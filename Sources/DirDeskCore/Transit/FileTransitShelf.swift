import Foundation

/// The shelf's records and its restore history, without any file system access.
public struct FileTransitShelf: Codable, Equatable, Sendable {
    /// A removed record and the position it had.
    public struct RemovedEntry: Codable, Equatable, Sendable {
        public var item: FileTransitItem
        public var index: Int

        public init(item: FileTransitItem, index: Int) {
            self.item = item
            self.index = index
        }
    }

    /// Records removed by one action; "Restore Recently Removed" puts back the newest batch.
    public struct RemovedBatch: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var removedAt: Date
        public var entries: [RemovedEntry]

        public init(id: UUID = UUID(), removedAt: Date, entries: [RemovedEntry]) {
            self.id = id
            self.removedAt = removedAt
            self.entries = entries
        }
    }

    public private(set) var items: [FileTransitItem]
    /// Restorable removals, oldest first.
    public private(set) var removedBatches: [RemovedBatch]

    public init(items: [FileTransitItem] = [], removedBatches: [RemovedBatch] = []) {
        self.items = items
        self.removedBatches = removedBatches
    }

    /// Records grouped by stack, in the order each stack first appears.
    public var stacks: [FileTransitStack] {
        var order: [UUID] = []
        var groups: [UUID: [FileTransitItem]] = [:]
        for item in items {
            if groups[item.stackID] == nil { order.append(item.stackID) }
            groups[item.stackID, default: []].append(item)
        }
        return order.map { FileTransitStack(id: $0, items: groups[$0] ?? []) }
    }

    public var canRestore: Bool { !removedBatches.isEmpty }

    /// Managed bytes of the records on the shelf.
    public var liveManagedBytes: Int64 { items.reduce(0) { $0 + $1.managedByteCount } }

    /// Managed bytes still on disk for removed records that can be restored.
    public var retainedManagedBytes: Int64 {
        removedBatches.reduce(0) { total, batch in batch.entries.reduce(total) { $0 + $1.item.managedByteCount } }
    }

    public func item(withID id: UUID) -> FileTransitItem? {
        items.first { $0.id == id }
    }

    public func items(inStack stackID: UUID) -> [FileTransitItem] {
        items.filter { $0.stackID == stackID }
    }

    public func containsOriginal(path: String) -> Bool {
        items.contains { $0.originalPath == path }
    }

    /// Inserts records at `index` (clamped) or at the end. Limits are checked by the caller.
    public mutating func insert(_ newItems: [FileTransitItem], at index: Int? = nil) {
        let fresh = newItems.filter { candidate in !items.contains { $0.id == candidate.id } }
        let position = min(max(index ?? items.count, 0), items.count)
        items.insert(contentsOf: fresh, at: position)
    }

    /// Removes records into a new restorable batch. Returns the removed records and the records that left
    /// the restore history because of the limits (their managed content can now be deleted).
    @discardableResult
    public mutating func remove(_ ids: Set<UUID>, at date: Date, limits: FileTransitLimits) -> (removed: [FileTransitItem], purged: [FileTransitItem]) {
        var entries: [RemovedEntry] = []
        for (index, item) in items.enumerated() where ids.contains(item.id) {
            entries.append(RemovedEntry(item: item, index: index))
        }
        guard !entries.isEmpty else { return ([], []) }
        items.removeAll { ids.contains($0.id) }
        removedBatches.append(RemovedBatch(removedAt: date, entries: entries))
        return (entries.map(\.item), trimHistory(limits: limits))
    }

    /// Puts back the newest removal at the positions its records had.
    public mutating func restoreLatest(limits: FileTransitLimits) throws -> [FileTransitItem] {
        guard let batch = removedBatches.last else { throw FileTransitError.nothingToRestore }
        let entries = batch.entries.filter { entry in !items.contains { $0.id == entry.item.id } }
        guard items.count + entries.count <= limits.maximumItemCount else { throw FileTransitError.shelfFull }
        removedBatches.removeLast()
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            items.insert(entry.item, at: min(entry.index, items.count))
        }
        return entries.map(\.item)
    }

    /// Drops the oldest removals that hold managed content until at most `maximum` managed bytes are stored
    /// (shelf plus restore history). Returns the dropped records.
    public mutating func purgeRemovedContent(keepingAtMost maximum: Int64) -> [FileTransitItem] {
        var purged: [FileTransitItem] = []
        while liveManagedBytes + retainedManagedBytes > maximum,
              let index = removedBatches.firstIndex(where: { batch in batch.entries.contains { $0.item.managedByteCount > 0 } }) {
            purged += removedBatches.remove(at: index).entries.map(\.item)
        }
        return purged
    }

    /// Sets the lock of the given records; returns how many records exist.
    @discardableResult
    public mutating func setLocked(_ ids: Set<UUID>, to locked: Bool) -> Int {
        var count = 0
        for index in items.indices where ids.contains(items[index].id) {
            items[index].isLocked = locked
            count += 1
        }
        return count
    }

    /// Gives every record of the stack its own stack. Returns false when the stack does not exist.
    @discardableResult
    public mutating func separate(_ stackID: UUID) -> Bool {
        var found = false
        for index in items.indices where items[index].stackID == stackID {
            items[index].stackID = UUID()
            found = true
        }
        return found
    }

    /// Keeps the restore history within the limits; always keeps the newest batch.
    private mutating func trimHistory(limits: FileTransitLimits) -> [FileTransitItem] {
        var purged: [FileTransitItem] = []
        func total() -> Int { removedBatches.reduce(0) { $0 + $1.entries.count } }
        while removedBatches.count > 1, removedBatches.count > limits.maximumRemovedBatches || total() > limits.maximumRemovedItems {
            purged += removedBatches.removeFirst().entries.map(\.item)
        }
        return purged
    }
}
