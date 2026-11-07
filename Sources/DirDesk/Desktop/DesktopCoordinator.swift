import AppKit
import Combine
import DirDeskCore
import SwiftUI

/// One directory runtime and one desktop window per physical screen. WatcherHub owns all FSEvents.
@MainActor
final class DesktopCoordinator: NSObject, ObservableObject {
    static let shared = DesktopCoordinator()
    static let enabledDefaultsKey = "dirdesk-desktop-enabled-v1"
    @Published private(set) var isEnabled = false
    @Published private(set) var layout = DesktopLayout()
    @Published private(set) var message: String?
    private(set) weak var appDelegate: AppDelegate?
    private(set) var pane: PaneRuntime?
    var desktopPanes: [PaneRuntime] { isEnabled ? [pane].compactMap { $0 } : [] }
    private var panels: [String: DesktopWindowController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingScreens: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var installed = false
    private var layoutKey = "dirdesk-desktop-layout-v1"
    private var activeZoneID = DesktopLayout.unassignedZoneID
    private var activeScreenID: String?
    let desktopUndo = DesktopUndoManager()
    var undoManager: UndoManager { desktopUndo }
    private var defaults: UserDefaults { .standard }

    func install(delegate: AppDelegate) {
        appDelegate = delegate
        guard !installed else { return }
        installed = true
        desktopUndo.onChange = { [weak self] in self?.refresh() }
        desktopUndo.onError = { [weak self] in self?.report($0) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScreenRefresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .dirDeskFilesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        setEnabled(defaults.bool(forKey: Self.enabledDefaultsKey))
    }
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            let directory = Self.desktopDirectory()
            // Fixture layouts cannot replace the user's daily desktop layout.
            layoutKey = "dirdesk-desktop-layout-v1" + (Self.fixtureDirectory == nil ? "" : ".fixture." + Data(directory.path.utf8).base64EncodedString())
            if let data = defaults.data(forKey: layoutKey), let saved = try? JSONDecoder().decode(DesktopLayout.self, from: data) { layout = saved }
            else { layout = DesktopLayout() }
            var configuration = ViewConfiguration()
            configuration.mode = .icons
            configuration.groupingMode = .none
            let runtime = PaneRuntime(directory: directory, configuration: configuration)
            runtime.onDirectoriesChanged = { [weak self] in self?.appDelegate?.watcherHub.refresh() }
            pane = runtime
            runtime.$directoryContentRevision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, let pane = self.pane, self.isEnabled else { return }
                self.layout.reconcile(pane.items)
                self.saveLayout()
                self.panels.values.forEach { $0.reload() }
            }.store(in: &subscriptions)
            runtime.load()
            reconcileScreens()
            appDelegate?.watcherHub.refresh()
        } else {
            pendingScreens?.cancel(); pendingScreens = nil
            pendingSave?.cancel(); pendingSave = nil
            persistNow()
            panels.values.forEach { $0.closeDesktop() }
            panels.removeAll()
            subscriptions.removeAll()
            pane?.onDirectoriesChanged = nil
            pane?.setSizeObservationActive(false)
            pane = nil
            message = nil
            appDelegate?.watcherHub.refresh()
        }
    }
    func shutdown() {
        // Keep the saved enabled preference for the next launch.
        let enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        setEnabled(false)
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        installed = false
    }
    func refresh() {
        guard isEnabled else { return }
        pane?.reload()
        appDelegate?.watcherHub.refresh()
    }
    static var fixtureDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-WumiDesktopFolder"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
    }
    private static func desktopDirectory() -> URL {
        fixtureDirectory ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
    private func scheduleScreenRefresh() {
        guard isEnabled else { return }
        pendingScreens?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcileScreens() }
        pendingScreens = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    private func reconcileScreens() {
        guard isEnabled, pane != nil else { return }
        guard let primary = NSScreen.screens.first else {
            panels.values.forEach { $0.closeDesktop() }
            panels.removeAll()
            return
        }
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { (Self.screenID($0), $0) })
        let sizes = screens.mapValues { (width: Double($0.visibleFrame.width), height: Double($0.visibleFrame.height)) }
        layout.prepare(screenSizes: sizes, primaryID: Self.screenID(primary))
        for id in Array(panels.keys) where screens[id] == nil { panels.removeValue(forKey: id)?.closeDesktop() }
        for (id, screen) in screens {
            if let controller = panels[id] { controller.update(screen: screen) }
            else {
                let controller = DesktopWindowController(coordinator: self, screen: screen, screenID: id)
                panels[id] = controller
                controller.showDesktop()
            }
        }
        saveLayout()
        // The pane and watched directory are unchanged by screen changes.
    }
    static func screenID(_ screen: NSScreen) -> String {
        String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }
    func activate(zoneID: String, screenID: String) { activeZoneID = zoneID; activeScreenID = screenID }
    func zones(on screenID: String) -> [DesktopZone] { layout.visibleZones(on: screenID, items: pane?.displayItems ?? []) }
    func items(in zoneID: String) -> [FileItem] { (pane?.displayItems ?? []).filter { layout.zoneID(for: $0) == zoneID } }
    func setAutomaticGrouping(_ enabled: Bool) { layout.automaticGrouping = enabled; saveLayout() }
    func addZone(screenID: String) {
        let count = layout.zones.filter(\.isCustom).count
        let zone = DesktopZone(title: L("New Collection"), screenID: screenID,
                               frame: .init(x: 40 + Double(count % 5) * 30, y: 120 + Double(count % 5) * 30, width: 340, height: 300))
        layout.zones.append(zone)
        saveLayout()
    }
    func updateZone(_ id: String, _ update: (inout DesktopZone) -> Void) {
        guard let index = layout.zones.firstIndex(where: { $0.id == id }) else { return }
        update(&layout.zones[index])
        saveLayout()
    }
    func removeZone(_ id: String) { layout.removeZone(id); saveLayout() }
    func assign(_ items: [FileItem], to zoneID: String) { _ = layout.assign(items, to: zoneID); saveLayout() }
    func didRename(_ old: FileItem, to new: FileItem) { layout.didRename(old, to: new); saveLayout() }
    func setSearch(screenID: String, widget: DesktopSearchWidget) { layout.searchWidgets[screenID] = widget; saveLayout() }
    func reveal(_ url: URL, select: Bool = true) {
        guard let delegate = appDelegate else { return }
        let directory = select ? url.deletingLastPathComponent() : url
        let controller = delegate.activeController ?? delegate.controllers.first ?? delegate.newWindow(directory: directory)
        controller.navigateActivePane(to: directory)
        if select { controller.activePane.select(urls: [url]) }
        FileOpenRouter.present(controller)
    }
    func preview(_ item: FileItem) {
        guard let delegate = appDelegate else { return }
        let controller = delegate.activeController ?? delegate.controllers.first ?? delegate.newWindow(directory: pane?.currentDirectory)
        SuperPreviewController.shared.show(item, controller: controller)
    }
    func report(_ text: String) { message = text }
    func clearMessage() { message = nil }
    private func saveLayout() {
        objectWillChange.send()
        panels.values.forEach { $0.reload() }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private func persistNow() {
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: layoutKey) }
    }
    func transfer(_ urls: [URL], into directory: URL, operation: NSDragOperation, sourceZone: String?) -> Bool {
        guard let delegate = appDelegate, !urls.isEmpty else { return false }
        Task {
            let move = await Task.detached {
                operation == .move || (operation == .generic && urls.allSatisfy { FileOperationSupport.sameVolume($0, directory) })
            }.value
            delegate.operations.start(.init(kind: move ? .move : .copy, sources: urls, destination: directory), undoManager: nil) { [weak self] report in
                guard let self else { return }
                Task {
                    let steps = await Task.detached { FileOperationsDesktopBridge.undoSteps(report.mutations) }.value
                    self.desktopUndo.add(steps, name: move ? L("Move") : L("Copy"))
                    self.refresh()
                    if !report.failures.isEmpty { self.report(report.failures.map(\.message).joined(separator: "\n")) }
                    guard let pane = self.pane else { return }
                    await pane.waitForRows()
                    if let sourceZone, pane.currentDirectory?.standardizedFileURL.path == directory.standardizedFileURL.path {
                        let created = Set(report.createdURLs.map(\.path))
                        self.assign(pane.items.filter { created.contains($0.url.path) }, to: sourceZone)
                    }
                    pane.select(urls: report.createdURLs)
                }
            }
        }
        return true
    }
}

/// The same undo mutation mapping as FileOperations, evaluated off the UI actor so fingerprints do not block it.
private enum FileOperationsDesktopBridge {
    static func undoSteps(_ mutations: [FileOperationMutation]) -> [FileUndoStep] {
        mutations.reversed().flatMap { mutation -> [FileUndoStep] in
            var steps: [FileUndoStep] = mutation.kind == .copied ? [.trash(mutation.destination)] : [.move(mutation.destination, to: mutation.source)]
            if let backup = mutation.replacedBackupURL { steps.append(.move(backup, to: mutation.destination)) }
            return steps
        }
    }
}

/// Keeps filesystem verification and undo execution off the UI actor, including redo.
@MainActor
final class DesktopUndoManager: UndoManager {
    struct Entry { var steps: [FileUndoStep]; var name: String }
    private var backward: [Entry] = []
    private var forward: [Entry] = []
    private var pending: [Entry] = []
    private var busy = false
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    override var canUndo: Bool { !busy && !backward.isEmpty }
    override var canRedo: Bool { !busy && !forward.isEmpty }
    override var undoActionName: String { backward.last?.name ?? "" }
    override var redoActionName: String { forward.last?.name ?? "" }
    func add(_ steps: [FileUndoStep], name: String) {
        guard !steps.isEmpty else { return }
        if busy { pending.append(.init(steps: steps, name: name)); return }
        backward.append(.init(steps: steps, name: name)); forward.removeAll()
    }
    override func undo() { apply(redo: false) }
    override func redo() { apply(redo: true) }
    private func apply(redo: Bool) {
        guard !busy, let entry = redo ? forward.last : backward.last else { return }
        busy = true
        Task {
            let result = await Task.detached { () -> Result<[FileUndoStep], Error> in
                if let error = FileUndoSafety.verify(entry.steps) { return .failure(error) }
                return Result { try FileUndoSafety.perform(entry.steps) }
            }.value
            busy = false
            switch result {
            case .success(let reverse):
                if redo { forward.removeLast(); backward.append(.init(steps: reverse, name: entry.name)) }
                else { backward.removeLast(); forward.append(.init(steps: reverse, name: entry.name)) }
                onChange?()
                NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
            case .failure(let error):
                onError?((error as? FileUndoStop).map { FileUndo.message(for: $0) } ?? error.localizedDescription)
            }
            if !pending.isEmpty {
                backward.append(contentsOf: pending)
                pending.removeAll()
                forward.removeAll()
            }
        }
    }
}
