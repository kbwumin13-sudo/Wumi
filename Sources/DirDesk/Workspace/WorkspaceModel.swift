import AppKit
import Combine
import DirDeskCore

/// One tab: a pane layout with its panes.
@MainActor
final class TabRuntime: ObservableObject, Identifiable {
    let id: UUID
    @Published var customTitle: String?
    @Published var layout: PaneLayout
    @Published private(set) var panes: [PaneRuntime]
    @Published var activePaneID: UUID
    @Published var splitRatios: [Double]
    @Published var isPinned: Bool
    @Published var namedWorkspaceID: UUID?
    var onStateChange: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    init(state: WorkspaceTab) {
        id = state.id
        customTitle = state.customTitle
        layout = state.layout
        panes = state.panes.map(PaneRuntime.init(state:))
        activePaneID = state.activePaneID
        splitRatios = state.splitRatios
        isPinned = state.isPinned
        namedWorkspaceID = state.namedWorkspaceID
        if !panes.contains(where: { $0.id == activePaneID }), let first = panes.first { activePaneID = first.id }
        panes.forEach(observe)
    }

    convenience init(directory: URL, configuration: ViewConfiguration) {
        let pane = BrowserPaneState(destination: .directory(directory), viewConfiguration: configuration)
        self.init(state: WorkspaceTab(pane: pane))
    }

    private func observe(_ pane: PaneRuntime) {
        pane.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var activePane: PaneRuntime { panes.first { $0.id == activePaneID } ?? panes[0] }

    var title: String { customTitle ?? activePane.title }

    var state: WorkspaceTab {
        var tab = WorkspaceTab(id: id, pane: panes[0].state)
        tab.title = activePane.title
        tab.customTitle = customTitle
        tab.layout = layout
        tab.panes = panes.map(\.state)
        tab.activePaneID = activePaneID
        tab.splitRatios = splitRatios
        tab.isPinned = isPinned
        tab.namedWorkspaceID = namedWorkspaceID
        return tab
    }

    /// Switches layout, creating panes at the active pane's folder or dropping trailing panes.
    func setLayout(_ newLayout: PaneLayout, configuration: ViewConfiguration) {
        guard newLayout != layout else { return }
        let needed = newLayout.paneCount
        var list = panes
        if list.count < needed {
            let directory = activePane.currentDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            while list.count < needed {
                let pane = PaneRuntime(directory: directory, configuration: activePane.viewConfiguration)
                observe(pane)
                list.append(pane)
                pane.load()
            }
        } else if list.count > needed {
            list = Array(list.prefix(needed))
        }
        panes = list
        layout = newLayout
        splitRatios = []
        if !panes.contains(where: { $0.id == activePaneID }) { activePaneID = panes[0].id }
        onStateChange?()
    }

    func focusPane(offset: Int) {
        guard let index = panes.firstIndex(where: { $0.id == activePaneID }), panes.count > 1 else { return }
        activePaneID = panes[(index + offset + panes.count) % panes.count].id
        onStateChange?()
    }

    /// Exchanges the places of two panes ("Move Pane To" in the original's context menu).
    func swapPanes(_ first: UUID, _ second: UUID) {
        guard let a = panes.firstIndex(where: { $0.id == first }), let b = panes.firstIndex(where: { $0.id == second }), a != b else { return }
        panes.swapAt(a, b)
        onStateChange?()
    }

    func closeActivePane() {
        guard panes.count > 1 else { return }
        panes.removeAll { $0.id == activePaneID }
        layout = Self.layout(forCount: panes.count)
        activePaneID = panes[0].id
        splitRatios = []
        onStateChange?()
    }

    static func layout(forCount count: Int) -> PaneLayout {
        switch count {
        case 1: .single
        case 2: .twoColumns
        case 3: .threeColumns
        default: .fourGrid
        }
    }
}

/// State of one workspace window: its tabs, active tab, inspector visibility and closed-tab stack.
@MainActor
final class WorkspaceModel: ObservableObject {
    let windowID: UUID
    @Published private(set) var tabs: [TabRuntime] = []
    @Published var activeTabID: UUID {
        didSet {
            guard activeTabID != oldValue else { return }
            loadActiveTabIfNeeded()
            watcherChanged?()
        }
    }
    @Published var inspectorVisible: Bool { didSet { scheduleSave() } }
    private(set) var closedTabs: [WorkspaceTab] = []
    private var cancellables: Set<AnyCancellable> = []
    private var saveWorkItem: DispatchWorkItem?
    let sessionStore: WorkspaceSessionStore
    var watcherChanged: (() -> Void)?

    init(session: WindowSession, store: WorkspaceSessionStore) {
        windowID = session.id
        sessionStore = store
        activeTabID = session.activeTabID
        inspectorVisible = session.inspectorVisible
        closedTabs = session.closedTabs
        tabs = session.tabs.map(TabRuntime.init(state:))
        if tabs.isEmpty {
            tabs = [TabRuntime(directory: AppModel.shared.startupDirectory(), configuration: AppModel.shared.defaultViewConfiguration)]
        }
        if !tabs.contains(where: { $0.id == activeTabID }) { activeTabID = tabs[0].id }
        tabs.forEach(attach)
    }

    convenience init(directory: URL, store: WorkspaceSessionStore) {
        let tab = WorkspaceTab(pane: BrowserPaneState(destination: .directory(directory), viewConfiguration: AppModel.shared.defaultViewConfiguration))
        self.init(session: WindowSession(tabs: [tab], activeTabID: tab.id), store: store)
    }

    private func attach(_ tab: TabRuntime) {
        tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        tab.onStateChange = { [weak self] in
            self?.scheduleSave()
            self?.watcherChanged?()
        }
        for pane in tab.panes { attach(pane) }
    }

    func attach(_ pane: PaneRuntime) {
        pane.onStateChange = { [weak self] in self?.scheduleSave() }
        pane.onDirectoriesChanged = { [weak self] in self?.watcherChanged?() }
    }

    var activeTab: TabRuntime { tabs.first { $0.id == activeTabID } ?? tabs[0] }
    var activePane: PaneRuntime { activeTab.activePane }

    var allPanes: [PaneRuntime] { tabs.flatMap(\.panes) }

    func startLoading() {
        loadActiveTabIfNeeded()
    }

    /// Restored background tabs keep their navigation and selection state without reading their folders.
    /// Once visited, their existing watchers continue to keep them current.
    private func loadActiveTabIfNeeded() {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else { return }
        for pane in tab.panes where pane.loadState == .idle { pane.load() }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(directory: URL? = nil, destination: PaneDestination? = nil, after reference: UUID? = nil, activate: Bool = true) -> TabRuntime? {
        guard tabs.count < WindowSession.maximumTabs else {
            NSSound.beep()
            return nil
        }
        let start = directory ?? activePane.currentDirectory ?? AppModel.shared.startupDirectory()
        let pane = BrowserPaneState(destination: destination ?? .directory(start), viewConfiguration: activePane.viewConfiguration)
        let tab = TabRuntime(state: WorkspaceTab(pane: pane))
        attach(tab)
        let index = (reference.flatMap { id in tabs.firstIndex { $0.id == id } } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: min(index, tabs.count))
        if activate { activeTabID = tab.id }
        scheduleSave()
        watcherChanged?()
        return tab
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        scheduleSave()
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activeTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    /// Closes a tab; returns false when it was the last tab (the window should close instead).
    @discardableResult
    func closeTab(_ id: UUID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let closing = tabs.remove(at: index)
        closedTabs.append(closing.state)
        if closedTabs.count > WindowSession.maximumClosedTabs { closedTabs.removeFirst() }
        if activeTabID == id { activeTabID = tabs[min(index, tabs.count - 1)].id }
        scheduleSave()
        watcherChanged?()
        return true
    }

    func closeTabs(rightOf id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for tab in tabs[(index + 1)...].reversed() where !tab.isPinned { closeTab(tab.id) }
    }

    func reopenClosedTab() {
        guard var state = closedTabs.popLast(), tabs.count < WindowSession.maximumTabs else {
            NSSound.beep()
            return
        }
        state.id = UUID()
        let tab = TabRuntime(state: state)
        attach(tab)
        tabs.append(tab)
        activeTabID = tab.id
        scheduleSave()
        watcherChanged?()
    }

    /// Removes single-pane tabs showing the same folder, keeping pinned and multi-pane tabs.
    @discardableResult
    /// Leaves one single-pane tab per folder: the active tab when it is one of them, else a pinned one, else the
    /// first. Pinned and multi-pane tabs are never closed.
    func removeDuplicateTabs() -> Int {
        var groups: [String: [TabRuntime]] = [:]
        for tab in tabs where tab.panes.count == 1 {
            if let path = tab.activePane.currentDirectory?.path { groups[path, default: []].append(tab) }
        }
        var removed = 0
        for group in groups.values where group.count > 1 {
            let keeper = group.first { $0.id == activeTabID } ?? group.first(where: \.isPinned) ?? group[0]
            for tab in group where tab.id != keeper.id && !tab.isPinned {
                if closeTab(tab.id) { removed += 1 }
            }
        }
        return removed
    }

    func moveTab(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: max(0, min(index, tabs.count)))
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned.toggle()
        // Pinned tabs stay at the front.
        let pinned = tabs.filter(\.isPinned), others = tabs.filter { !$0.isPinned }
        tabs = pinned + others
        scheduleSave()
    }

    func adoptTab(_ state: WorkspaceTab) {
        let tab = TabRuntime(state: state)
        attach(tab)
        tabs.append(tab)
        activeTabID = tab.id
        scheduleSave()
        watcherChanged?()
    }

    func detachTab(_ id: UUID) -> WorkspaceTab? {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabID == id { activeTabID = tabs[min(index, tabs.count - 1)].id }
        scheduleSave()
        watcherChanged?()
        return tab.state
    }

    // MARK: Session persistence

    var session: WindowSession {
        var session = WindowSession(id: windowID, tabs: tabs.map(\.state), activeTabID: activeTabID, inspectorVisible: inspectorVisible)
        session.closedTabs = closedTabs
        return session
    }

    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        sessionStore.save(session)
        if let path = activePane.currentDirectory?.path { AppModel.shared.lastLocationPath = path }
    }
}
