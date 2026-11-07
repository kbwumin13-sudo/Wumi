import AppKit
import Combine
import DirDeskCore

/// Explicit fixture-only acceptance of the live desktop coordinator, pane and native view tree.
/// The caller owns application lifetime; this entry never terminates NSApplication.
@MainActor
enum DebugDesktopRun {
    static func run(output: URL) async {
        await Acceptance(output: output).run()
    }

    @MainActor
    private final class Acceptance {
        struct Stop: Error { let detail: String }
        let output: URL
        let coordinator = DesktopCoordinator.shared
        let files = FileManager.default
        let started = ProcessInfo.processInfo.systemUptime
        // Reserve the final ten seconds for undo/cleanup within the total 90-second budget.
        var cleaningUp = false
        var deadline: Double { started + (cleaningUp ? 90 : 80) }
        var checks: [[String: Any]] = []
        var fixture: URL?
        var initialPaths: Set<String> = []
        var createdPaths: Set<String> = []
        var subscriptions: Set<AnyCancellable> = []
        var operationReports: [FileOperationReport] = []
        var layoutKey: String?
        var savedLayout: Any?
        var savedEnabled: Any?
        var preferencesCaptured = false
        var textURL: URL?
        var trashOutstanding = false

        init(output: URL) { self.output = output.standardizedFileURL }

        func run() async {
            do {
                guard let supplied = DesktopCoordinator.fixtureDirectory else {
                    throw Stop(detail: "Missing explicit -WumiDesktopFolder fixture; desktop was not enabled.")
                }
                let root = supplied.resolvingSymlinksInPath().standardizedFileURL
                guard supplied.path.contains("/artifacts/"), root.path.contains("/artifacts/"),
                      supplied.path == root.path,
                      try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw Stop(detail: "Fixture must be a real directory under /artifacts/, without symlink components.")
                }
                guard !coordinator.isEnabled || coordinator.pane?.currentDirectory?.standardizedFileURL == root else {
                    throw Stop(detail: "An unrelated desktop pane is active; refusing to change it.")
                }
                guard let delegate = coordinator.appDelegate else {
                    throw Stop(detail: "DesktopCoordinator must be installed by AppDelegate before acceptance.")
                }
                fixture = root
                initialPaths = try paths(in: root)
                let noteURL = root.appendingPathComponent("Wumi-note.txt")
                let noteValues = try noteURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard noteValues.isRegularFile == true, noteValues.isSymbolicLink != true else {
                    throw Stop(detail: "Expected existing fixture file Wumi-note.txt.")
                }
                let originalNote = try Data(contentsOf: noteURL)
                let defaults = UserDefaults.standard
                savedEnabled = defaults.object(forKey: DesktopCoordinator.enabledDefaultsKey)
                let key = "dirdesk-desktop-layout-v1.fixture." + Data(root.path.utf8).base64EncodedString()
                layoutKey = key
                savedLayout = defaults.object(forKey: key)
                preferencesCaptured = true

                coordinator.setEnabled(true)
                try await require("desktop enabled with loaded fixture rows and visible AppKit windows") {
                    self.coordinator.isEnabled && self.coordinator.pane?.loadState == .loaded &&
                    self.coordinator.pane?.rows.contains { $0.item?.url == noteURL } == true &&
                    !self.windows.isEmpty && self.windows.allSatisfy(\.isVisible)
                }
                guard let pane = coordinator.pane, let screen = NSScreen.screens.first else {
                    throw Stop(detail: "Loaded desktop has no pane or screen.")
                }
                pane.$items.sink { [weak self] items in
                    guard let self else { return }
                    for item in items where !self.initialPaths.contains(item.url.path) {
                        self.createdPaths.insert(item.url.path)
                    }
                }.store(in: &subscriptions)
                delegate.operations.$tasks.sink { [weak self] tasks in
                    guard let self else { return }
                    for task in tasks where task.plan.sources.allSatisfy({ self.isInside($0) }) {
                        if let report = task.report { self.operationReports.append(report) }
                    }
                }.store(in: &subscriptions)
                let screenID = DesktopCoordinator.screenID(screen)

                // Begin with the actual ungrouped FileGridController, located through NSWindow's tree.
                for zone in coordinator.layout.zones where zone.isCustom { coordinator.removeZone(zone.id) }
                coordinator.setAutomaticGrouping(false)
                try await require("ungrouped native FileGrid disables spring loading") {
                    let grids = self.views.compactMap { $0 as? FileCollectionView }
                    return !grids.isEmpty && grids.allSatisfy {
                        $0.owner?.pane === pane && $0.owner?.allowsSpringLoading == false &&
                        $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == pane.displayItems.count
                    }
                }

                let oldIDs = Set(coordinator.layout.zones.map(\.id))
                coordinator.addZone(screenID: screenID)
                guard let zone = coordinator.layout.zones.first(where: { !oldIDs.contains($0.id) }) else {
                    throw Stop(detail: "New collection was not added.")
                }
                coordinator.updateZone(zone.id) { $0.title = "Desktop acceptance" }
                let actions = DesktopBrowserActions(coordinator: coordinator, pane: pane, zoneID: zone.id, screenID: screenID)
                guard let note = pane.items.first(where: { $0.url == noteURL }) else {
                    throw Stop(detail: "Wumi-note.txt missing from live pane.")
                }
                coordinator.assign([note], to: zone.id)
                try await require("collection assignment refreshes native data source without moving files") {
                    self.nativeItems(in: zone.id).map(\.url).contains(noteURL) &&
                    self.coordinator.layout.zoneID(for: note) == zone.id && self.files.fileExists(atPath: noteURL.path)
                }
                let unassigned = DesktopBrowserActions(coordinator: coordinator, pane: pane,
                                                      zoneID: DesktopLayout.unassignedZoneID, screenID: screenID)
                try record("background drop accepted", unassigned.acceptDrop([noteURL], into: root, operation: .move, in: pane))
                try await require("visual drop refreshes collection membership and preserves fixture paths") {
                    !self.nativeItems(in: zone.id).contains { $0.url == noteURL } &&
                    self.nativeItems(in: DesktopLayout.unassignedZoneID).contains { $0.url == noteURL } &&
                    self.coordinator.layout.zoneID(for: note) == DesktopLayout.unassignedZoneID &&
                    (try? self.paths(in: root)) == self.initialPaths
                }

                let folder = try await create(folder: true, actions: actions, pane: pane, zoneID: zone.id)
                let folderURL = try await renameWithUndoRedo(folder, pane: pane, zoneID: zone.id)
                let text = try await create(folder: false, actions: actions, pane: pane, zoneID: zone.id)
                textURL = text.url
                let suffix = UUID().uuidString
                let renamed = try await renameWithUndoRedo(text, pane: pane, zoneID: zone.id)
                textURL = renamed

                guard let renamedItem = pane.items.first(where: { $0.url == renamed }) else {
                    throw Stop(detail: "Renamed item missing from pane.")
                }
                trashOutstanding = true
                actions.trash([renamedItem])
                try await require("trash removes fixture item from pane and native collection") {
                    !self.files.fileExists(atPath: renamed.path) && !pane.rows.contains { $0.item?.url == renamed } &&
                    !self.nativeItems(in: zone.id).contains { $0.url == renamed } && self.coordinator.desktopUndo.canUndo
                }
                coordinator.desktopUndo.undo()
                try await require("trash undo restores fixture item and native collection") {
                    self.has(renamed, pane: pane, zoneID: zone.id) && self.coordinator.desktopUndo.canRedo
                }
                trashOutstanding = false

                let moved = folderURL.appendingPathComponent(renamed.lastPathComponent)
                createdPaths.insert(moved.path)
                try record("folder drop accepted for actual move", actions.acceptDrop([renamed], into: folderURL, operation: .move, in: pane))
                try await require("folder drop waits for OperationCenter completion and native removal") {
                    !self.operationReports.isEmpty && self.operationReports.allSatisfy { $0.failures.isEmpty } &&
                    delegate.operations.tasks.isEmpty && self.coordinator.desktopUndo.canUndo &&
                    self.coordinator.desktopUndo.undoActionName == L("Move") && !self.coordinator.desktopUndo.canRedo &&
                    self.files.fileExists(atPath: moved.path) && !self.files.fileExists(atPath: renamed.path) &&
                    !pane.rows.contains { $0.item?.url == renamed } &&
                    !self.nativeItems(in: zone.id).contains { $0.url == renamed }
                }
                coordinator.desktopUndo.undo()
                try await require("folder move undo restores pane and native collection") {
                    self.has(renamed, pane: pane, zoneID: zone.id) && !self.files.fileExists(atPath: moved.path) &&
                    self.coordinator.desktopUndo.canRedo && delegate.operations.tasks.isEmpty
                }

                guard let beforeExternal = pane.items.first(where: { $0.url == renamed }) else {
                    throw Stop(detail: "Move undo did not restore the text item.")
                }
                let identity = DesktopLayout.identityKey(beforeExternal)
                let external = root.appendingPathComponent("Wumi-external-\(suffix)." + text.fileExtension)
                createdPaths.insert(external.path)
                // No refresh call: exercise WatcherHub -> PaneRuntime -> layout reconciliation -> NSView.
                try files.moveItem(at: renamed, to: external)
                textURL = external
                try await require("external rename follows identity through watcher, layout and native collection", seconds: 12) {
                    guard let item = pane.items.first(where: { $0.url == external }) else { return false }
                    return DesktopLayout.identityKey(item) == identity &&
                        self.coordinator.layout.assignments[identity]?.lastKnownPath == external.path &&
                        self.coordinator.layout.zoneID(for: item) == zone.id &&
                        self.has(external, pane: pane, zoneID: zone.id) &&
                        !self.nativeItems(in: zone.id).contains { $0.url == renamed }
                }
                let saved = coordinator.layout
                coordinator.setEnabled(false)
                try await require("disable removes desktop window layers and pane") { self.layersRemoved }
                coordinator.setEnabled(true)
                try await require("off/on restores layout and actual collection data") {
                    guard let restored = self.coordinator.pane else { return false }
                    return self.coordinator.layout == saved && restored !== pane &&
                        self.has(external, pane: restored, zoneID: zone.id) && !self.windows.isEmpty
                }
                try record("existing fixture note contents unchanged", try Data(contentsOf: noteURL) == originalNote)
            } catch {
                checks.append(["name": "acceptance stopped", "passed": false, "detail": describe(error), "state": state])
            }
            await cleanup()
            writeReport()
        }

        var windows: [NSWindow] {
            NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("Wumi.Desktop.") == true }
        }
        var views: [NSView] {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return windows.compactMap(\.contentView).flatMap(descendants)
        }
        var renameField: NSTextField? {
            views.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "Desktop.RenameField" }
        }
        var layersRemoved: Bool {
            !coordinator.isEnabled && coordinator.pane == nil && windows.allSatisfy { !$0.isVisible && $0.contentView?.subviews.isEmpty != false }
        }
        func nativeItems(in zoneID: String) -> [FileItem] {
            views.compactMap { $0 as? DesktopCollectionView }.filter { $0.owner?.zoneID == zoneID }.flatMap { collection in
                guard collection.numberOfSections > 0, let owner = collection.owner else { return [FileItem]() }
                return (0..<collection.numberOfItems(inSection: 0)).compactMap { owner.item(at: IndexPath(item: $0, section: 0)) }
            }
        }
        func has(_ url: URL, pane: PaneRuntime, zoneID: String) -> Bool {
            files.fileExists(atPath: url.path) && pane.loadState == .loaded &&
            pane.rows.contains { $0.item?.url.standardizedFileURL.path == url.standardizedFileURL.path } &&
            nativeItems(in: zoneID).contains { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
        }
        func paths(in directory: URL) throws -> Set<String> {
            Set(try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.path))
        }
        func isInside(_ url: URL) -> Bool {
            guard let fixture else { return false }
            return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(fixture.path + "/")
        }
        func record(_ name: String, _ passed: Bool, detail: String = "") throws {
            checks.append(["name": name, "passed": passed, "detail": detail])
            if !passed { throw Stop(detail: name + ": " + detail) }
        }
        func require(_ name: String, seconds: Double = 8, condition: () -> Bool) async throws {
            let limit = min(deadline, ProcessInfo.processInfo.systemUptime + seconds)
            while ProcessInfo.processInfo.systemUptime < limit, !Task.isCancelled {
                if condition() { try record(name, true); return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try record(name, false, detail: "Timed out or cancelled. " + state)
        }
        func create(folder: Bool, actions: DesktopBrowserActions, pane: PaneRuntime, zoneID: String) async throws -> FileItem {
            let before = Set(pane.items.map { $0.url.path })
            actions.create(folder: folder)
            try await require(folder ? "new folder starts native inline rename" : "new text file starts native inline rename") {
                guard let id = pane.renamingID, let item = pane.items.first(where: { $0.id == id }),
                      !before.contains(item.url.path), item.isDirectory == folder else { return false }
                return self.renameField?.stringValue == item.name && self.has(item.url, pane: pane, zoneID: zoneID)
            }
            guard let item = pane.items.first(where: { $0.id == pane.renamingID }), isInside(item.url) else {
                throw Stop(detail: "Created item escaped fixture or rename selection.")
            }
            createdPaths.insert(item.url.path)
            return item
        }
        func renameWithUndoRedo(_ item: FileItem, pane: PaneRuntime, zoneID: String) async throws -> URL {
            let kind = item.isDirectory ? "folder" : "text"
            let name = "Wumi-acceptance-" + UUID().uuidString + (item.isDirectory ? "" : "." + item.fileExtension)
            let renamed = item.url.deletingLastPathComponent().appendingPathComponent(name)
            createdPaths.insert(renamed.path)
            guard let field = renameField, let action = field.action, let target = field.target else {
                throw Stop(detail: "Native rename field or its target/action disappeared.")
            }
            field.stringValue = name
            try record(kind + " rename committed through native NSTextField action", NSApp.sendAction(action, to: target, from: field))
            try await require(kind + " rename refreshes pane and collection") {
                self.has(renamed, pane: pane, zoneID: zoneID) && !self.files.fileExists(atPath: item.url.path) &&
                pane.renamingID == nil && self.coordinator.desktopUndo.canUndo
            }
            coordinator.desktopUndo.undo()
            try await require(kind + " rename undo refreshes pane and collection") {
                self.has(item.url, pane: pane, zoneID: zoneID) && !self.files.fileExists(atPath: renamed.path) &&
                self.coordinator.desktopUndo.canRedo
            }
            coordinator.desktopUndo.redo()
            try await require(kind + " rename redo refreshes pane and collection") {
                self.has(renamed, pane: pane, zoneID: zoneID) && !self.files.fileExists(atPath: item.url.path) &&
                self.coordinator.desktopUndo.canUndo
            }
            return renamed
        }
        func dismissEditor(pane: PaneRuntime) {
            if let field = renameField {
                // Escape's delegate path avoids committing an incidental focus change.
                if let delegate = field.delegate as? DesktopGridController {
                    _ = delegate.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                }
            }
            pane.renamingID = nil
        }
        var state: String {
            let pane = coordinator.pane
            let failures = operationReports.flatMap(\.failures).map(\.message)
            return "enabled=\(coordinator.isEnabled), windows=\(windows.map { $0.identifier?.rawValue ?? "?" }), " +
                "load=\(String(describing: pane?.loadState)), rows=\(pane?.rows.count ?? -1), " +
                "items=\(pane?.items.map(\.name) ?? []), rename=\(String(describing: pane?.renamingID)), " +
                "rowNames=\(pane?.rows.compactMap { $0.item?.url.lastPathComponent } ?? []), " +
                "displayNames=\(pane?.displayItems.map { $0.url.lastPathComponent } ?? []), " +
                "native=\(coordinator.layout.zones.filter(\.isCustom).map { $0.id + ":" + nativeItems(in: $0.id).map(\.name).joined(separator: ",") }), " +
                "memberships=\(pane?.items.map { $0.name + ":" + coordinator.layout.zoneID(for: $0) + ":" + DesktopLayout.identityKey($0) } ?? []), " +
                "assignments=\(coordinator.layout.assignments), " +
                "undo=\(coordinator.desktopUndo.canUndo)/\(coordinator.desktopUndo.undoActionName), " +
                "message=\(coordinator.message ?? ""), operationFailures=\(failures)"
        }
        func describe(_ error: Error) -> String { (error as? Stop)?.detail ?? error.localizedDescription }

        func cleanup() async {
            guard preferencesCaptured, let fixture else { return }
            cleaningUp = true
            if let operations = coordinator.appDelegate?.operations {
                let pending = operations.tasks.filter { !$0.finished && $0.plan.sources.contains { self.createdPaths.contains($0.path) } }
                for task in pending { operations.cancel(task.id) }
                if !pending.isEmpty {
                    let ids = Set(pending.map(\.id))
                    do {
                        try await require("cleanup waits for cancelled fixture operations", seconds: 3) {
                            !operations.tasks.contains { ids.contains($0.id) && !$0.finished }
                        }
                    } catch { checks.append(["name": "cleanup operations", "passed": false, "detail": describe(error)]) }
                }
            }
            // Restore a trashed test item through the same undo flow; never enumerate the user's Trash.
            if trashOutstanding, let textURL, !files.fileExists(atPath: textURL.path), coordinator.desktopUndo.canUndo {
                coordinator.desktopUndo.undo()
                do { try await require("cleanup restores outstanding trash", seconds: 3) { self.files.fileExists(atPath: textURL.path) && self.coordinator.desktopUndo.canRedo } }
                catch { checks.append(["name": "cleanup trash", "passed": false, "detail": describe(error)]) }
            }
            if let pane = coordinator.pane { dismissEditor(pane: pane) }
            coordinator.setEnabled(false)
            do { try await require("final disable removes desktop window layers", seconds: 2) { self.layersRemoved } }
            catch { checks.append(["name": "final disable", "passed": false, "detail": describe(error)]) }
            subscriptions.removeAll()
            do {
                // Also capture a creation that completed on disk before its pane publication timed out.
                createdPaths.formUnion(try paths(in: fixture).subtracting(initialPaths))
                for path in createdPaths.sorted(by: { $0.count > $1.count }) where !initialPaths.contains(path) {
                    let url = URL(fileURLWithPath: path)
                    guard isInside(url) else { throw Stop(detail: "Refusing cleanup outside fixture: " + path) }
                    if files.fileExists(atPath: path) { try files.removeItem(at: url) }
                }
                try record("fixture initial paths restored", try paths(in: fixture) == initialPaths)
            } catch { checks.append(["name": "fixture cleanup", "passed": false, "detail": describe(error)]) }
            if let layoutKey { restore(savedLayout, forKey: layoutKey) }
            restore(savedEnabled, forKey: DesktopCoordinator.enabledDefaultsKey)
        }
        func restore(_ value: Any?, forKey key: String) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        func writeReport() {
            let report: [String: Any] = [
                "completed": true, "passed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
                "fixture": fixture?.path ?? "", "checks": checks, "finalState": state,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "timeoutSeconds": 90,
                "pollMilliseconds": 10, "createdPaths": createdPaths.sorted(),
            ]
            do {
                try files.createDirectory(at: output, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("desktop-acceptance.json"), options: .atomic)
                try Data("done\n".utf8).write(to: output.appendingPathComponent("desktop-acceptance-done"), options: .atomic)
            } catch { NSLog("Desktop acceptance report failed: %@", error.localizedDescription) }
        }
    }
}
