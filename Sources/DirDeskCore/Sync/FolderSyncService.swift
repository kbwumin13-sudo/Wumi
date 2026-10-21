import Darwin
import Foundation

/// Compares two folders and copies changes between them. Nothing is ever deleted: an item missing on one side is
/// copied there, and a one-way run leaves extra items on the side it updates alone.
public enum FolderSyncService {
    static let partialPrefix = ".dirdesk-sync-partial-"

    /// Finder view state and this engine's own staging names are never synced.
    static func isIgnored(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix(partialPrefix)
    }

    // MARK: - Validation

    /// Checks the preset's name and both folders.
    public static func validate(_ preset: FolderSyncPreset) throws {
        guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolderSyncError.invalidName }
        try validateFolders(of: preset)
    }

    static func validateFolders(of preset: FolderSyncPreset) throws {
        let fm = FileManager.default
        for url in [preset.leftURL, preset.rightURL] {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FolderSyncError.folderMissing(url)
            }
            guard fm.isReadableFile(atPath: url.path) else { throw FolderSyncError.folderUnreadable(url) }
        }
        guard identity(of: preset.leftURL) != identity(of: preset.rightURL) else { throw FolderSyncError.sameFolder }
        if isNested(preset.leftURL, in: preset.rightURL) || isNested(preset.rightURL, in: preset.leftURL) {
            throw FolderSyncError.nestedFolders
        }
        let updated: [URL] = switch preset.direction {
        case .updateRight: [preset.rightURL]
        case .updateLeft: [preset.leftURL]
        case .updateBoth: [preset.leftURL, preset.rightURL]
        }
        for url in updated where !fm.isWritableFile(atPath: url.path) { throw FolderSyncError.folderNotWritable(url) }
    }

    /// Compares identities up the resolved ancestor chain, so symbolic links and letter case cannot hide nesting.
    static func isNested(_ inner: URL, in outer: URL) -> Bool {
        guard let target = identity(of: outer) else { return false }
        var current = inner.resolvingSymlinksInPath().standardizedFileURL
        while current.path != "/" {
            current = current.deletingLastPathComponent().standardizedFileURL
            if identity(of: current) == target { return true }
        }
        return false
    }

    // MARK: - Analysis

    /// Scans both folders and decides an action for every relative path. Throws `CancellationError` when cancelled.
    public static func analyze(preset: FolderSyncPreset, baseline: FolderSyncBaseline? = nil, limits: FolderSyncLimits = .default,
                               isCancelled: () -> Bool = { false }) throws -> FolderSyncAnalysis {
        try validateFolders(of: preset)
        let filters = FolderSyncFilterSet(preset.filters)
        let left = try scan(preset.leftURL, includeHiddenItems: preset.includeHiddenItems, filters: filters,
                            limit: limits.maximumItemCount, isCancelled: isCancelled)
        let right = try scan(preset.rightURL, includeHiddenItems: preset.includeHiddenItems, filters: filters,
                             limit: limits.maximumItemCount, isCancelled: isCancelled)
        let leftSensitive = isCaseSensitive(preset.leftURL)
        let rightSensitive = isCaseSensitive(preset.rightURL)
        let items = classify(left: left.entries, right: right.entries, direction: preset.direction, baseline: baseline,
                             tolerance: preset.modificationTimeTolerance,
                             caseSensitiveMatching: preset.caseSensitivity == .sensitive || (leftSensitive && rightSensitive),
                             leftCaseSensitive: leftSensitive, rightCaseSensitive: rightSensitive)
        return FolderSyncAnalysis(id: UUID(), preset: preset, baseline: baseline, createdAt: Date(), items: items,
                                  unreadableFolders: left.unreadableFolders + right.unreadableFolders,
                                  leftIsCaseSensitive: leftSensitive, rightIsCaseSensitive: rightSensitive)
    }

    struct Scan {
        var entries: [FolderSyncEntry] = []
        var unreadableFolders: [URL] = []
    }

    private static let scanKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
                                                     .contentModificationDateKey]

    /// Lists `root` depth-first. Excluded folders are not entered; with include rules, folders left holding no
    /// included file are dropped.
    static func scan(_ root: URL, includeHiddenItems: Bool, filters: FolderSyncFilterSet, limit: Int,
                     isCancelled: () -> Bool) throws -> Scan {
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = includeHiddenItems ? [] : [.skipsHiddenFiles]
        var scan = Scan()
        var pending = [""]
        while let directory = pending.popLast() {
            if isCancelled() { throw CancellationError() }
            let folder = directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: scanKeys, options: options)
            } catch {
                if directory.isEmpty { throw FolderSyncError.folderUnreadable(root) }
                scan.unreadableFolders.append(folder)
                continue
            }
            for child in children {
                let name = child.lastPathComponent
                guard !isIgnored(name),
                      let entry = entry(at: child, relativePath: directory.isEmpty ? name : directory + "/" + name),
                      filters.admits(entry.relativePath, isDirectory: entry.kind == .directory) else { continue }
                guard scan.entries.count < limit else { throw FolderSyncError.scanLimitExceeded }
                scan.entries.append(entry)
                if entry.kind == .directory { pending.append(entry.relativePath) }
            }
        }
        if filters.hasIncludeRules { scan.entries = droppingFoldersWithoutFiles(scan.entries) }
        return scan
    }

    /// nil for missing items and for sockets, pipes and devices, which are never synced.
    static func entry(at url: URL, relativePath: String) -> FolderSyncEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(scanKeys)) else { return nil }
        let kind: FolderSyncItemKind
        if values.isSymbolicLink == true {
            kind = .symbolicLink
        } else if values.isDirectory == true {
            kind = .directory
        } else if values.isRegularFile == true {
            kind = .file
        } else {
            return nil
        }
        let fingerprint = FolderSyncFingerprint(size: kind == .directory ? 0 : Int64(values.fileSize ?? 0),
                                                modificationDate: values.contentModificationDate ?? .distantPast)
        return FolderSyncEntry(relativePath: relativePath, kind: kind, fingerprint: fingerprint)
    }

    static func droppingFoldersWithoutFiles(_ entries: [FolderSyncEntry]) -> [FolderSyncEntry] {
        var holding = Set<String>()
        for entry in entries where entry.kind != .directory {
            var path = Substring(entry.relativePath)
            while let slash = path.lastIndex(of: "/") {
                path = path[..<slash]
                guard holding.insert(String(path)).inserted else { break }
            }
        }
        return entries.filter { $0.kind != .directory || holding.contains($0.relativePath) }
    }

    static func isCaseSensitive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
    }

    // MARK: - Classification

    private struct Pair {
        var left: FolderSyncEntry?
        var right: FolderSyncEntry?
        var collides = false
    }

    /// Pairs the two listings and picks an action for each relative path. Pure, so it can be tested with synthetic entries.
    static func classify(left: [FolderSyncEntry], right: [FolderSyncEntry], direction: FolderSyncDirection, baseline: FolderSyncBaseline?,
                         tolerance: TimeInterval, caseSensitiveMatching: Bool, leftCaseSensitive: Bool,
                         rightCaseSensitive: Bool) -> [FolderSyncAnalysisItem] {
        let key: (String) -> String = caseSensitiveMatching ? exactKey : foldedKey
        var groups: [String: (left: [FolderSyncEntry], right: [FolderSyncEntry])] = [:]
        for entry in left { groups[foldedKey(entry.relativePath), default: ([], [])].left.append(entry) }
        for entry in right { groups[foldedKey(entry.relativePath), default: ([], [])].right.append(entry) }
        var baselineIndex: [String: FolderSyncFingerprint] = [:]
        for (path, fingerprint) in baseline?.entries ?? [:] { baselineIndex[key(path)] = fingerprint }
        let leftFolders = folderIndex(left, key: key)
        let rightFolders = folderIndex(right, key: key)

        var items: [FolderSyncAnalysisItem] = []
        var settledFolders = Set<String>()
        for group in groups.values {
            for pair in pairs(in: group, caseSensitiveMatching: caseSensitiveMatching,
                              bothCaseSensitive: leftCaseSensitive && rightCaseSensitive) {
                let path = pair.left?.relativePath ?? pair.right?.relativePath ?? ""
                guard case let (action, reason)? = decide(pair, direction: direction, tolerance: tolerance,
                                                          baseline: baselineIndex[key(path)]) else { continue }
                items.append(FolderSyncAnalysisItem(relativePath: path, left: pair.left, right: pair.right, action: action,
                                                    conflictReason: reason,
                                                    leftPath: pair.left?.relativePath ?? mappedPath(path, folders: leftFolders, key: key),
                                                    rightPath: pair.right?.relativePath ?? mappedPath(path, folders: rightFolders, key: key)))
                // A folder in a type mismatch or case collision is settled as a whole; its contents get no items.
                if reason != nil, pair.left?.kind == .directory || pair.right?.kind == .directory {
                    settledFolders.insert(key(path) + "/")
                }
            }
        }
        if !settledFolders.isEmpty {
            items.removeAll { item in
                let path = key(item.relativePath)
                var end = path.endIndex
                while let slash = path[..<end].lastIndex(of: "/") {
                    if settledFolders.contains(String(path[...slash])) { return true }
                    end = slash
                }
                return false
            }
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    /// Entries whose paths fold to the same key. Without case-sensitive matching a group is one item unless a
    /// case-sensitive side holds several spellings; otherwise each spelling is its own item, and the spellings collide
    /// unless both sides can hold them apart.
    private static func pairs(in group: (left: [FolderSyncEntry], right: [FolderSyncEntry]), caseSensitiveMatching: Bool,
                              bothCaseSensitive: Bool) -> [Pair] {
        if !caseSensitiveMatching && group.left.count <= 1 && group.right.count <= 1 {
            return [Pair(left: group.left.first, right: group.right.first)]
        }
        var spellings: [String: Pair] = [:]
        for entry in group.left { spellings[exactKey(entry.relativePath), default: Pair()].left = entry }
        for entry in group.right { spellings[exactKey(entry.relativePath), default: Pair()].right = entry }
        let collides = spellings.count > 1 && !(caseSensitiveMatching && bothCaseSensitive)
        return spellings.values.map { pair in
            var pair = pair
            pair.collides = collides
            return pair
        }
    }

    /// nil means no item: a folder that exists on both sides.
    private static func decide(_ pair: Pair, direction: FolderSyncDirection, tolerance: TimeInterval,
                               baseline: FolderSyncFingerprint?) -> (FolderSyncAction, FolderSyncConflictReason?)? {
        let twoWay = direction == .updateBoth
        if pair.collides { return (twoWay ? .conflict : .skip, .caseCollision) }
        switch (pair.left, pair.right) {
        case let (left?, right?):
            if left.kind == .directory && right.kind == .directory { return nil }
            if left.kind != right.kind { return (twoWay ? .conflict : .skip, .typeMismatch) }
            if left.fingerprint.matches(right.fingerprint, tolerance: tolerance) { return (.skip, nil) }
            let leftLead = left.fingerprint.modificationDate.timeIntervalSince(right.fingerprint.modificationDate)
            switch direction {
            case .updateRight:
                // A one-way run never overwrites a file that is newer on the side it updates.
                return -leftLead > tolerance ? (.skip, nil) : (.updateRight, nil)
            case .updateLeft:
                return leftLead > tolerance ? (.skip, nil) : (.updateLeft, nil)
            case .updateBoth:
                // The side that changed since the baseline wins.
                guard let baseline else { return (.conflict, .differentWithoutBaseline) }
                switch (!left.fingerprint.matches(baseline, tolerance: tolerance), !right.fingerprint.matches(baseline, tolerance: tolerance)) {
                case (true, false): return (.updateRight, nil)
                case (false, true): return (.updateLeft, nil)
                case (true, true): return (.conflict, .bothChanged)
                case (false, false): return (.skip, nil)
                }
            }
        case (.some, nil):
            return direction == .updateLeft ? (.skip, nil) : (.copyToRight, nil)
        case (nil, .some):
            return direction == .updateRight ? (.skip, nil) : (.copyToLeft, nil)
        case (nil, nil):
            return nil
        }
    }

    private static func folderIndex(_ entries: [FolderSyncEntry], key: (String) -> String) -> [String: String] {
        var index: [String: String] = [:]
        for entry in entries where entry.kind == .directory { index[key(entry.relativePath)] = entry.relativePath }
        return index
    }

    /// Where an item missing on one side goes there: inside that side's existing parent folder, whose spelling may
    /// differ, or inside the spelling the parent will be created with.
    private static func mappedPath(_ path: String, folders: [String: String], key: (String) -> String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let parent = String(path[..<slash])
        return (folders[key(parent)] ?? mappedPath(parent, folders: folders, key: key)) + path[slash...]
    }

    static func exactKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    static func foldedKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Apply

    fileprivate enum Side {
        case left, right
        var opposite: Side { self == .left ? .right : .left }
    }

    private enum Operation {
        case copy(to: Side)
        case keepBoth
    }

    private struct Step {
        let item: FolderSyncAnalysisItem
        let operation: Operation
    }

    /// Carries out the analysis. Every conflict needs a decision, and every item about to be written must still look
    /// the way the analysis saw it; both are checked before anything changes. Failures of single items are reported in
    /// the summary; cancellation stops before the next item.
    public static func apply(_ analysis: FolderSyncAnalysis, decisions: [String: FolderSyncConflictDecision] = [:],
                             progress: (FolderSyncProgress) -> Void = { _ in },
                             isCancelled: () -> Bool = { false }) throws -> FolderSyncRunSummary {
        let startedAt = Date()
        let preset = analysis.preset
        try validateFolders(of: preset)
        let steps = try plannedSteps(analysis, decisions: decisions)
        for step in steps where !isUnchanged(step.item, in: preset) { throw FolderSyncError.staleAnalysis }
        let stepBytes = steps.map { incomingBytes($0, preset: preset) }
        try requireFreeSpace(left: stepBytes.reduce(0) { $0 + $1.left }, right: stepBytes.reduce(0) { $0 + $1.right }, preset: preset)

        var state = FolderSyncProgress(processedItemCount: 0, totalItemCount: steps.count, completedBytes: 0,
                                       totalBytes: stepBytes.reduce(0) { $0 + $1.left + $1.right }, currentRelativePath: nil)
        var synced: [String: FolderSyncFingerprint] = [:]
        var failures: [FolderSyncItemFailure] = []
        var copiedToLeft = 0, copiedToRight = 0
        var cancelled = false
        for (step, bytes) in zip(steps, stepBytes) {
            if isCancelled() {
                cancelled = true
                break
            }
            state.currentRelativePath = step.item.relativePath
            progress(state)
            do {
                synced.merge(try perform(step, preset: preset)) { $1 }
                switch step.operation {
                case .copy(to: .left): copiedToLeft += 1
                case .copy(to: .right): copiedToRight += 1
                case .keepBoth:
                    copiedToLeft += 1
                    copiedToRight += 1
                }
            } catch {
                failures.append(FolderSyncItemFailure(relativePath: step.item.relativePath, message: error.localizedDescription))
            }
            state.processedItemCount += 1
            state.completedBytes += bytes.left + bytes.right
            progress(state)
        }

        let outcome: FolderSyncRunOutcome = if cancelled {
            .cancelled
        } else if failures.isEmpty {
            .completed
        } else {
            failures.count == steps.count ? .failed : .completedWithIssues
        }
        return FolderSyncRunSummary(presetID: preset.id, startedAt: startedAt, finishedAt: Date(), outcome: outcome,
                                    copiedToLeftCount: copiedToLeft, copiedToRightCount: copiedToRight, failures: failures,
                                    baseline: nextBaseline(analysis, synced: synced))
    }

    private static func plannedSteps(_ analysis: FolderSyncAnalysis, decisions: [String: FolderSyncConflictDecision]) throws -> [Step] {
        var steps: [Step] = []
        for item in analysis.items {
            switch item.action {
            case .copyToRight, .updateRight:
                steps.append(Step(item: item, operation: .copy(to: .right)))
            case .copyToLeft, .updateLeft:
                steps.append(Step(item: item, operation: .copy(to: .left)))
            case .skip:
                break
            case .conflict:
                guard let decision = decisions[item.relativePath] else { throw FolderSyncError.unresolvedConflicts }
                // Keeping a side that does not have the item (possible in a case collision) copies nothing; nothing is deleted.
                switch decision {
                case .keepLeft where item.left != nil: steps.append(Step(item: item, operation: .copy(to: .right)))
                case .keepRight where item.right != nil: steps.append(Step(item: item, operation: .copy(to: .left)))
                case .keepBoth: steps.append(Step(item: item, operation: .keepBoth))
                case .keepLeft, .keepRight, .skip: break
                }
            }
        }
        return steps
    }

    /// Folders only need to still be folders. For a case collision the side without the item is not checked: on a
    /// case-insensitive disk its name resolves to the other spelling.
    private static func isUnchanged(_ item: FolderSyncAnalysisItem, in preset: FolderSyncPreset) -> Bool {
        let checksAbsence = item.conflictReason != .caseCollision
        func matches(_ expected: FolderSyncEntry?, _ root: URL, _ path: String) -> Bool {
            let current = entry(at: root.appendingPathComponent(path), relativePath: path)
            guard let expected else { return !checksAbsence || current == nil }
            guard let current, current.kind == expected.kind else { return false }
            return expected.kind == .directory || current.fingerprint == expected.fingerprint
        }
        return matches(item.left, preset.leftURL, item.leftPath) && matches(item.right, preset.rightURL, item.rightPath)
    }

    /// Bytes a step writes to each side. Creating a folder writes nothing itself (its contents are separate items);
    /// replacing a mismatched item or keeping both copies whole folders.
    private static func incomingBytes(_ step: Step, preset: FolderSyncPreset) -> (left: Int64, right: Int64) {
        func bytes(from side: Side, wholeFolders: Bool) -> Int64 {
            guard let entry = step.item.entry(on: side) else { return 0 }
            guard entry.kind == .directory else { return entry.fingerprint.size }
            return wholeFolders ? FileOperationCoordinator.totalBytes(of: [url(step.item, side, preset)]) : 0
        }
        switch step.operation {
        case .copy(let side):
            let size = bytes(from: side.opposite, wholeFolders: step.item.conflictReason != nil)
            return side == .left ? (size, 0) : (0, size)
        case .keepBoth:
            return (bytes(from: .right, wholeFolders: true), bytes(from: .left, wholeFolders: true))
        }
    }

    private static func requireFreeSpace(left: Int64, right: Int64, preset: FolderSyncPreset) throws {
        func require(_ needed: Int64, on url: URL) throws {
            guard needed > 0,
                  let available = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                      .volumeAvailableCapacityForImportantUsage,
                  needed > available else { return }
            throw FolderSyncError.insufficientSpace(needed: needed, available: available)
        }
        if FileOperationCoordinator.sameVolume(preset.leftURL, preset.rightURL) {
            try require(left + right, on: preset.leftURL)
        } else {
            try require(left, on: preset.leftURL)
            try require(right, on: preset.rightURL)
        }
    }

    /// Performs one step and returns the baseline entries it makes true.
    private static func perform(_ step: Step, preset: FolderSyncPreset) throws -> [String: FolderSyncFingerprint] {
        let item = step.item
        guard case .copy(let side) = step.operation else { return try keepBoth(item, preset: preset) }
        guard let source = item.entry(on: side.opposite) else { return [:] }
        let from = url(item, side.opposite, preset)
        let to = url(item, side, preset)
        let existing = item.entry(on: side)
        if item.conflictReason == .caseCollision && existing == nil {
            // Never overwrite the differently cased item that holds this name on a case-insensitive disk.
            try copyItem(from: from, to: itemExists(to.path) ? FileOperationCoordinator.keepBothURL(for: to) : to, replacing: false)
            return [:]
        }
        if let existing, existing.kind != source.kind {
            // Type mismatch settled for one side: the losing item goes to the Trash rather than being deleted.
            try FileManager.default.trashItem(at: to, resultingItemURL: nil)
            try copyItem(from: from, to: to, replacing: false)
        } else if source.kind == .directory {
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        } else {
            try copyItem(from: from, to: to, replacing: existing != nil)
        }
        return source.kind == .directory ? [:] : [item.relativePath: source.fingerprint]
    }

    /// Both versions end up on both sides: the newer one (the left one on a tie) under the original name, the other
    /// under a keep-both name ("Name 2.ext") that is free in both folders. On the newer side the incoming copy gets the
    /// new name; the other side renames its own item to it, so the folders match afterwards.
    private static func keepBoth(_ item: FolderSyncAnalysisItem, preset: FolderSyncPreset) throws -> [String: FolderSyncFingerprint] {
        let fm = FileManager.default
        guard let left = item.left, let right = item.right else {
            // Only one side has it (a case collision): copy it across under a keep-both name.
            let side: Side = item.left == nil ? .left : .right
            try copyItem(from: url(item, side.opposite, preset), to: FileOperationCoordinator.keepBothURL(for: url(item, side, preset)),
                         replacing: false)
            return [:]
        }
        let winner: Side = right.fingerprint.modificationDate > left.fingerprint.modificationDate ? .right : .left
        let loser = winner.opposite
        let winnerURL = url(item, winner, preset)
        let loserURL = url(item, loser, preset)
        let folder = (item.relativePath as NSString).deletingLastPathComponent
        let probe = KeepBothProbe(otherFolder: winnerURL.deletingLastPathComponent())
        let keptLoserURL = FileOperationCoordinator.keepBothURL(for: loserURL, fileManager: probe)
        let keptName = keptLoserURL.lastPathComponent

        try fm.moveItem(at: loserURL, to: keptLoserURL)
        do {
            try copyItem(from: winnerURL, to: loserURL, replacing: false)
        } catch {
            try? fm.moveItem(at: keptLoserURL, to: loserURL)
            throw error
        }
        try copyItem(from: keptLoserURL, to: winnerURL.deletingLastPathComponent().appendingPathComponent(keptName), replacing: false)

        let (winnerEntry, loserEntry) = winner == .left ? (left, right) : (right, left)
        var entries: [String: FolderSyncFingerprint] = [:]
        if winnerEntry.kind != .directory { entries[item.relativePath] = winnerEntry.fingerprint }
        if loserEntry.kind != .directory { entries[folder.isEmpty ? keptName : folder + "/" + keptName] = loserEntry.fingerprint }
        return entries
    }

    /// Makes FileOperationCoordinator.keepBothURL treat a name as taken when it exists in either folder. Every other
    /// item of the analysis already exists on at least one side, so its name cannot be picked either.
    private final class KeepBothProbe: FileManager {
        let otherFolder: URL

        init(otherFolder: URL) {
            self.otherFolder = otherFolder
            super.init()
        }

        override func fileExists(atPath path: String) -> Bool {
            FolderSyncService.itemExists(path)
                || FolderSyncService.itemExists(otherFolder.appendingPathComponent((path as NSString).lastPathComponent).path)
        }
    }

    /// Files identical on both sides, files this run synced, and the previous entry for everything else that still exists.
    private static func nextBaseline(_ analysis: FolderSyncAnalysis, synced: [String: FolderSyncFingerprint]) -> FolderSyncBaseline {
        let key: (String) -> String = analysis.matchesCaseSensitively ? exactKey : foldedKey
        var previous: [String: FolderSyncFingerprint] = [:]
        for (path, fingerprint) in analysis.baseline?.entries ?? [:] { previous[key(path)] = fingerprint }
        var entries = synced
        for item in analysis.items where entries[item.relativePath] == nil {
            if let left = item.left, let right = item.right, left.kind != .directory, left.kind == right.kind,
               left.fingerprint.matches(right.fingerprint, tolerance: analysis.preset.modificationTimeTolerance) {
                entries[item.relativePath] = left.fingerprint
            } else if let fingerprint = previous[key(item.relativePath)] {
                entries[item.relativePath] = fingerprint
            }
        }
        return FolderSyncBaseline(entries: entries)
    }

    // MARK: - File system

    /// Copies into a hidden partial name beside the destination, then renames it into place: rename(2) atomically
    /// replaces an existing file, and an exclusive rename publishes a new item without overwriting anything.
    static func copyItem(from source: URL, to destination: URL, replacing: Bool) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(partialPrefix + UUID().uuidString)
        do {
            try fm.copyItem(at: source, to: partial)
            let result = replacing ? rename(partial.path, destination.path) : renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL))
            if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    fileprivate static func url(_ item: FolderSyncAnalysisItem, _ side: Side, _ preset: FolderSyncPreset) -> URL {
        side == .left ? preset.leftURL.appendingPathComponent(item.leftPath) : preset.rightURL.appendingPathComponent(item.rightPath)
    }

    /// lstat, so a dangling symbolic link counts as an existing item.
    static func itemExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private struct FolderID: Equatable {
        let device: Int32
        let inode: UInt64
    }

    /// stat identity (following symbolic links), for comparing the two sync folders.
    private static func identity(of url: URL) -> FolderID? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FolderID(device: info.st_dev, inode: info.st_ino)
    }
}

private extension FolderSyncAnalysisItem {
    func entry(on side: FolderSyncService.Side) -> FolderSyncEntry? {
        side == .left ? left : right
    }
}
