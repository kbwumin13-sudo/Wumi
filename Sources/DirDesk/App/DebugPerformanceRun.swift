import AppKit
import DirDeskCore

/// A real-window benchmark shared verbatim by the baseline and optimized app.
/// Public wiring belongs to DebugSnapshot; see scripts/performance/README.md.
@MainActor
enum DebugPerformanceRun {
    static func run(delegate: AppDelegate, output: URL) {
        Task { @MainActor in
            let runner = Runner(output: output)
            await runner.run(delegate: delegate)
        }
    }

    private struct Entry: Decodable {
        let name: String
        let size: Int64
        let mtime: Double
    }

    private struct Directory: Decodable {
        let path: String
        let entries: [Entry]

        func ordered(_ key: FileSortKey = .name, ascending: Bool = true) -> [Entry] {
            // Independent fixture oracle: never invoke the implementation's FileSorter.
            entries.sorted { a, b in
                let less: Bool
                switch key {
                case .size: less = a.size == b.size ? a.name < b.name : a.size < b.size
                case .modificationDate: less = a.mtime == b.mtime ? a.name < b.name : a.mtime < b.mtime
                default: less = a.name < b.name
                }
                return ascending ? less : (!less && a.name != b.name)
            }
        }
    }

    private struct Fixture: Decodable {
        let schemaVersion: Int
        let largeCount: Int
        let directories: [Directory]
    }

    private struct Validation: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }

    private struct Resources: Encodable {
        let wallMilliseconds: Double
        let cpuMilliseconds: Double?
        let footprintStartBytes: UInt64?
        let footprintEndBytes: UInt64?
        let footprintPeakSampledBytes: UInt64?
        let wakeups: UInt64?
        let readBytes: UInt64?
        let writeBytes: UInt64?
    }

    private struct HeartbeatResult: Encodable {
        let intervalMilliseconds: Double
        let sampleCount: Int
        let skippedTicksWhilePending: Int
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
        let maxMilliseconds: Double?
        let delaysMilliseconds: [Double]
    }

    private struct Phase: Encodable {
        let name: String
        let resources: Resources
        let mainThreadHeartbeat: HeartbeatResult
        let validations: [Validation]
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let harnessVersion = "20261020.1"
        let startedAt: Date
        var finishedAt: Date?
        var completed = false
        var passed = false
        var fixturePath = ""
        var largeCount = 0
        var phases: [Phase] = []
        var validations: [Validation] = []
        var failures: [String] = []
        let environment = PerformanceReport.Environment.current(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        let notes = [
            "Heartbeat is enqueue-to-MainActor execution latency, NOT display FPS or frame time.",
            "A separate serial queue ticks every 20 ms; at most one MainActor probe is pending. Skipped ticks are reported, not zero-valued samples.",
            "Every phase includes content/order checks, AppKit subscription delivery, a 120 ms stable interval, a final 150 ms wait and the final pending heartbeat acknowledgement.",
            "Resources are process-wide DirDeskCore.ProcessUsage deltas (proc_pid_rusage); footprint is physical footprint, not RSS. Peak is sampled every 100 ms plus endpoints and can miss short peaks.",
            "Fixture verification/manifest decoding occur before stages; UI validation and heartbeat overhead are included. Warm caches are not cleared.",
            "Git subprocess invocation count is not measured. Async git work is not a completion barrier.",
            "80 s overall and per-phase cooperative deadlines; a fully blocked main thread cannot be interrupted by a normal AppKit termination. Main should retain an external watchdog."
        ]
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private final class Runner {
        let output: URL
        private var report = Report(startedAt: Date())
        private let deadline = ProcessInfo.processInfo.systemUptime + 80
        private var phaseDeadline: Double = 0
        private var phaseChecks: [Validation] = []
        private var finalUICondition: (() -> Bool)?

        init(output: URL) { self.output = output }

        func run(delegate: AppDelegate) async {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                // A repeated run must not mistake a previous success marker for this run's completion.
                try? FileManager.default.removeItem(at: output.appendingPathComponent("performance-done"))
                let defaults = UserDefaults.standard
                guard defaults.bool(forKey: "DirDeskSnapshotHidden"),
                      let support = defaults.string(forKey: "DirDeskApplicationSupport"), !support.isEmpty else {
                    throw Failure("Require -DirDeskSnapshotHidden YES (disable index startup) and isolated -DirDeskApplicationSupport. Main owns launch isolation.")
                }
                guard let path = defaults.string(forKey: "DirDeskPerformanceFixture") else {
                    throw Failure("Missing -DirDeskPerformanceFixture <generated fixture root>")
                }
                let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                report.fixturePath = root.path
                // All disk inspection is off MainActor and strictly confined to generated fixtures.
                let fixture = try await Task.detached(priority: .userInitiated) {
                    try Self.readFixture(root)
                }.value
                report.largeCount = fixture.largeCount
                guard fixture.largeCount == 5000 else {
                    throw Failure("The six-stage baseline comparison requires 5000 items; do not expand application grouping to the 20000-item load fixture.")
                }
                try check("fixture", true, "schema 1; \(fixture.largeCount) large entries; 12 distinct test directories")
                guard let controller = delegate.activeController ?? delegate.controllers.first else {
                    throw Failure("No WorkspaceController supplied by app startup")
                }
                let byPath = Dictionary(uniqueKeysWithValues: fixture.directories.map { ($0.path, $0) })
                guard let small = byPath["small"], let large = byPath["large"],
                      let switchA = byPath["switch-a"], let switchB = byPath["switch-b"] else {
                    throw Failure("Incomplete fixture directories")
                }
                let pane = controller.activePane
                try await measure("small_browse") {
                    pane.open(root.appendingPathComponent(small.path))
                    self.configure(pane)
                    try await self.waitForUI(controller, pane, root, small)
                    try self.check("small exact content and real table", true, "\(small.entries.count) entries")
                }
                try await measure("large_load") {
                    pane.open(root.appendingPathComponent(large.path))
                    self.configure(pane)
                    try await self.waitForUI(controller, pane, root, large)
                    try self.check("large exact content, metadata, rows and real table", true, "\(large.entries.count) entries; no truncation")
                }
                try await measure("repeated_sort") {
                    // Selection originates in the actual NSTableView, then must survive every rebuild.
                    guard let list = controller.listController(for: pane), list.tableView.numberOfRows > 3 else {
                        throw Failure("Large directory has no real list table")
                    }
                    let chosen = IndexSet([1, large.entries.count / 2, large.entries.count - 2])
                    list.tableView.selectRowIndexes(chosen, byExtendingSelection: false)
                    let selected = Set(chosen.map { pane.displayItems[$0].id })
                    try await self.wait("initial table selection") { pane.selectedIDs == selected }
                    // Each state differs from the preceding one; both directions of all three keys.
                    for key: FileSortKey in [.name, .size, .modificationDate] {
                        for ascending in [false, true] {
                            var configuration = pane.viewConfiguration
                            configuration.sortKey = key
                            configuration.sortAscending = ascending
                            pane.viewConfiguration = configuration
                            try await self.waitForUI(controller, pane, root, large, key: key, ascending: ascending, selected: selected)
                            try self.check("sort \(key.rawValue) \(ascending ? "ascending" : "descending") and selection", true,
                                           "independent manifest order; model + AppKit selected identities")
                        }
                    }
                }
                try await measure("application_grouping", timeout: 25) {
                    let selected = pane.selectedIDs
                    var configuration = pane.viewConfiguration
                    configuration.sortKey = .name
                    configuration.sortAscending = true
                    configuration.groupingMode = .application
                    pane.viewConfiguration = configuration
                    // Wait for complete rows before checking the independent Launch Services oracle.
                    try await self.waitForUI(controller, pane, root, large, selected: selected, grouped: true)
                    let expected = self.applicationGroups(root: root, directory: large)
                    try await self.wait("application group membership, order and headers") {
                        self.groupsMatch(pane, expected)
                    }
                    try await self.waitForUI(controller, pane, root, large, selected: selected, grouped: true)
                    try self.check("application groups", self.groupsMatch(pane, expected),
                                   "\(expected.count) groups; one independent default-app lookup per extension, after UI grouping")
                    try self.check("grouping preserves selection", pane.selectedIDs == selected)
                }
                try await measure("rapid_switch") {
                    self.configure(pane)
                    // Yield between requests, but deliberately don't wait for the old directory's load.
                    for index in 0..<12 {
                        let directory = index % 3 == 0 ? large : (index % 3 == 1 ? switchA : switchB)
                        pane.open(root.appendingPathComponent(directory.path))
                        await self.pause(0.008)
                    }
                    // Distinct final path and disjoint names expose late writes from cancelled work.
                    pane.open(root.appendingPathComponent(small.path))
                    self.configure(pane)
                    try await self.waitForUI(controller, pane, root, small)
                    await self.pause(0.35)
                    try await self.waitForUI(controller, pane, root, small)
                    try self.check("rapid switch final folder has no stale items or selection", pane.selectedIDs.isEmpty,
                                   "12 overlapping requests + final small; exact manifest/table content rechecked after 350 ms")
                }

                let restoreDirectories = [large, small, switchA, switchB] + (0..<8).compactMap { byPath[String(format: "tab-%02d", $0)] }
                guard restoreDirectories.count == 12 else { throw Failure("Need all 12 restore directories") }
                let tabs = restoreDirectories.map { directory -> WorkspaceTab in
                    var state = BrowserPaneState(destination: .directory(root.appendingPathComponent(directory.path)))
                    state.viewConfiguration = self.configuration()
                    state.selectedIdentities = [FileIdentity(fallbackPath: root.appendingPathComponent(directory.path)
                        .appendingPathComponent(directory.ordered()[0].name).path)]
                    return WorkspaceTab(pane: state)
                }
                let session = WindowSession(tabs: tabs, activeTabID: tabs[0].id, inspectorVisible: false)
                let sessionData = try PersistenceStore<WindowSession>.encoder.encode(session)
                try await measure("restore_tabs", timeout: 25) {
                    let decoded = try JSONDecoder().decode(WindowSession.self, from: sessionData)
                    let restored = delegate.open(session: decoded)
                    try self.check("restore 12 serialized tabs", restored.model.tabs.count == 12)
                    for (index, tab) in restored.model.tabs.enumerated() {
                        restored.model.selectTab(tab.id)
                        let active = tab.activePane
                        let directory = restoreDirectories[index]
                        // No pane.load() here: activation must exercise the app's eager OR lazy loading path.
                        try await self.waitForUI(restored, active, root, directory)
                        let expectedPath = root.appendingPathComponent(directory.path).appendingPathComponent(directory.ordered()[0].name).path
                        try await self.wait("restored tab selection \(index)") {
                            active.selectedItems.map(\.url.path) == [expectedPath] && self.tableSelectionMatches(restored, active)
                        }
                        try self.check("activate restored tab \(index)", true,
                                       "\(directory.path): exact rows, real table, restored selection")
                    }
                    try self.check("final restored directory has no old data", restored.activePane.currentDirectory?.path == root.appendingPathComponent("tab-07").path)
                }
                report.completed = true
            } catch {
                report.failures.append(String(describing: error))
                report.validations.append(Validation(name: "run completed", passed: false, detail: String(describing: error)))
            }
            report.finishedAt = Date()
            report.passed = report.completed && report.failures.isEmpty && report.validations.allSatisfy(\.passed)
            do {
                try writeReport()
                try Data((report.passed ? "PASS\n" : "FAIL\n").utf8).write(to: output.appendingPathComponent("performance-done"), options: .atomic)
            } catch {
                // Do not emit a success marker if the JSON could not be written.
                NSLog("DirDesk performance report write failed: %@", String(describing: error))
            }
            NSApp.terminate(nil)
        }

        private func configuration() -> ViewConfiguration {
            var result = ViewConfiguration()
            result.mode = .list
            result.sortKey = .name
            result.sortAscending = true
            result.groupingMode = .none
            result.foldersFirst = false
            result.pinnedFolderPaths = []
            result.visibleListColumns = [.name, .modificationDate, .size, .kind]
            return result
        }

        private func configure(_ pane: PaneRuntime) { pane.viewConfiguration = configuration() }

        private func check(_ name: String, _ passed: Bool, _ detail: String = "") throws {
            let validation = Validation(name: name, passed: passed, detail: detail)
            phaseChecks.append(validation)
            report.validations.append(validation)
            if !passed { throw Failure("Validation failed: \(name): \(detail)") }
        }

        private func measure(_ name: String, timeout: Double = 15, body: () async throws -> Void) async throws {
            phaseChecks = []
            finalUICondition = nil
            let startTime = ProcessInfo.processInfo.systemUptime
            phaseDeadline = min(deadline, startTime + timeout)
            let start = ProcessUsage.current()
            let heartbeat = Heartbeat()
            heartbeat.start()
            var failure: Error?
            do {
                if startTime >= deadline { throw Failure("Overall deadline before \(name)") }
                try await body()
            } catch {
                failure = error
                let validation = Validation(name: "\(name) completion", passed: false, detail: String(describing: error))
                phaseChecks.append(validation)
                report.validations.append(validation)
            }
            // Includes the final runloop turn and the last outstanding (possibly delayed) probe.
            await pause(0.15)
            if failure == nil, let finalUICondition {
                do {
                    try await wait("\(name) final UI barrier", condition: finalUICondition)
                    try check("\(name) final UI barrier", true, "content/order, model rows and subscribed AppKit table after final wait")
                } catch {
                    failure = error
                    let validation = Validation(name: "\(name) final UI barrier", passed: false, detail: String(describing: error))
                    phaseChecks.append(validation)
                    report.validations.append(validation)
                }
            }
            let (latency, sampledPeak) = await heartbeat.stop()
            let end = ProcessUsage.current()
            let wall = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
            if start == nil || end == nil {
                failure = failure ?? Failure("Core ProcessUsage unavailable in \(name)")
                let validation = Validation(name: "\(name) ProcessUsage", passed: false, detail: "proc_pid_rusage returned nil")
                phaseChecks.append(validation)
                report.validations.append(validation)
            }
            if ProcessInfo.processInfo.systemUptime > phaseDeadline {
                failure = failure ?? Failure("Deadline exceeded in \(name)")
                let validation = Validation(name: "\(name) deadline", passed: false, detail: "stage or overall cooperative deadline exceeded")
                phaseChecks.append(validation)
                report.validations.append(validation)
            }
            func delta(_ key: KeyPath<ProcessUsage, UInt64>) -> UInt64? {
                guard let start, let end else { return nil }
                let a = start[keyPath: key], b = end[keyPath: key]
                return b >= a ? b - a : 0
            }
            let resources = Resources(wallMilliseconds: wall, cpuMilliseconds: delta(\.cpuTimeNanoseconds).map { Double($0) / 1_000_000 },
                                      footprintStartBytes: start?.footprintBytes, footprintEndBytes: end?.footprintBytes,
                                      footprintPeakSampledBytes: [sampledPeak, start?.footprintBytes, end?.footprintBytes].compactMap { $0 }.max(),
                                      wakeups: delta(\.wakeups), readBytes: delta(\.diskReadBytes), writeBytes: delta(\.diskWrittenBytes))
            report.phases.append(Phase(name: name, resources: resources, mainThreadHeartbeat: latency, validations: phaseChecks))
            try writeReport() // Retain completed stages if a later stage fails or an external watchdog intervenes.
            if let failure { throw failure }
        }

        private func writeReport() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: output.appendingPathComponent("performance.json"), options: .atomic)
        }

        private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        private func wait(_ label: String, condition: () -> Bool) async throws {
            while ProcessInfo.processInfo.systemUptime < phaseDeadline {
                if condition() { return }
                await pause(0.03)
            }
            throw Failure("Timeout: \(label)")
        }

        private func waitForUI(_ controller: WorkspaceController, _ pane: PaneRuntime, _ root: URL, _ directory: Directory,
                               key: FileSortKey = .name, ascending: Bool = true, selected: Set<FileIdentity>? = nil,
                               grouped: Bool = false) async throws {
            let expected = directory.ordered(key, ascending: ascending)
            let names = expected.map(\.name)
            let metadata = Dictionary(uniqueKeysWithValues: directory.entries.map { ($0.name, $0) })
            let path = root.appendingPathComponent(directory.path).path
            let matches: () -> Bool = {
                guard pane.loadState == .loaded, !pane.truncated, pane.currentDirectory?.path == path,
                      pane.displayItems.map(\.name) == names,
                      pane.displayItems.allSatisfy({ item in
                          guard let entry = metadata[item.name] else { return false }
                          return item.url.deletingLastPathComponent().path == path && item.size == entry.size &&
                              abs((item.modificationDate?.timeIntervalSince1970 ?? 0) - entry.mtime) < 0.01
                      }), self.rowsMatch(pane, names: names, grouped: grouped),
                      self.tableMatches(controller, pane), self.tableSelectionMatches(controller, pane),
                      selected.map({ pane.selectedIDs == $0 && self.tableSelectionMatches(controller, pane) }) ?? true else {
                    return false
                }
                return true
            }
            finalUICondition = matches
            var stableSince: Double?
            try await wait("\(directory.path) displayItems + rows + AppKit (\(key.rawValue), \(ascending), grouped=\(grouped)); state=\(pane.loadState)") {
                let now = ProcessInfo.processInfo.systemUptime
                guard matches() else { stableSince = nil; return false }
                if stableSince == nil { stableSince = now }
                return now - (stableSince ?? now) >= 0.12
            }
        }

        private func rowsMatch(_ pane: PaneRuntime, names: [String], grouped: Bool) -> Bool {
            let rowNames = pane.rows.compactMap { $0.item?.name }
            if !grouped { return pane.groups.isEmpty && pane.rows.count == names.count && rowNames == names }
            guard !pane.groups.isEmpty, pane.rows.count == names.count + pane.groups.count,
                  rowNames.count == names.count, Set(rowNames) == Set(names),
                  rowNames == pane.groups.flatMap({ $0.items.map(\.name) }) else { return false }
            var offset = 0
            for group in pane.groups {
                guard offset < pane.rows.count,
                      case .group(let id, let title, let count) = pane.rows[offset], id == group.id,
                      title == (group.isLiteral ? group.title : L(group.title)), count == group.items.count else { return false }
                offset += group.items.count + 1
            }
            return true
        }

        private func tableMatches(_ controller: WorkspaceController, _ pane: PaneRuntime) -> Bool {
            guard controller.activePane === pane, let list = controller.listController(for: pane),
                  list.view.window === controller.window, let tableWindow = list.tableView.window,
                  tableWindow === controller.window, list.tableView.numberOfRows == pane.rows.count,
                  list.numberOfRows(in: list.tableView) == pane.rows.count else { return false }
            let table = list.tableView
            // Read the actual table data source for every row: count alone accepts stale same-sized data.
            for (index, row) in pane.rows.enumerated() {
                let actual = list.item(atRow: index)
                if let item = row.item {
                    if actual?.id != item.id || actual?.url != item.url || actual?.name != item.name { return false }
                } else if actual != nil || !list.tableView(table, isGroupRow: index) { return false }
            }
            // Check cells already materialized by AppKit, without forcing reloadData or rebuilding the view ourselves.
            table.layoutSubtreeIfNeeded()
            table.displayIfNeeded()
            let visible = table.rows(in: table.visibleRect)
            return table.numberOfColumns > 0 && visible.length > 0 &&
                table.rowView(atRow: visible.location, makeIfNecessary: false) != nil
        }

        private func tableSelectionMatches(_ controller: WorkspaceController, _ pane: PaneRuntime) -> Bool {
            guard let list = controller.listController(for: pane) else { return false }
            let ids = Set(list.selectedItems().map(\.id))
            return ids == pane.selectedIDs
        }

        private func applicationGroups(root: URL, directory: Directory) -> [(String, [String])] {
            var applications: [String: String] = [:]
            var groups: [String: [String]] = [:]
            for entry in directory.ordered() {
                let ext = (entry.name as NSString).pathExtension
                let group: String
                if let cached = applications[ext] { group = cached }
                else {
                    let app = NSWorkspace.shared.urlForApplication(toOpen: root.appendingPathComponent(directory.path).appendingPathComponent(entry.name))
                    group = app.map { "app:" + FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "app:none"
                    applications[ext] = group
                }
                groups[group, default: []].append(entry.name)
            }
            return groups.keys.sorted { a, b in
                if a == "app:none" { return false }
                if b == "app:none" { return true }
                return String(a.dropFirst(4)).localizedStandardCompare(String(b.dropFirst(4))) == .orderedAscending
            }.map { ($0, groups[$0] ?? []) }
        }

        private func groupsMatch(_ pane: PaneRuntime, _ expected: [(String, [String])]) -> Bool {
            pane.groups.count == expected.count && zip(pane.groups, expected).allSatisfy { group, expectation in
                group.id == expectation.0 && group.items.map(\.name) == expectation.1
            }
        }

        nonisolated private static func readFixture(_ root: URL) throws -> Fixture {
            guard root.path.contains("/artifacts/performance-20261020/fixtures/"),
                  root.resolvingSymlinksInPath().path == root.path else { throw Failure("Fixture must be a real directory below artifacts/performance-20261020/fixtures") }
            let manifest = root.appendingPathComponent("manifest.json")
            guard manifest.resolvingSymlinksInPath().path == manifest.path else { throw Failure("Symlink manifest rejected") }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: manifest))
            let required = Set(["small", "large", "switch-a", "switch-b"] + (0..<8).map { String(format: "tab-%02d", $0) })
            guard fixture.schemaVersion == 1, [5000, 20000].contains(fixture.largeCount),
                  fixture.directories.count == required.count, Set(fixture.directories.map(\.path)) == required else { throw Failure("Invalid fixture manifest") }
            for directory in fixture.directories {
                let url = root.appendingPathComponent(directory.path)
                guard url.resolvingSymlinksInPath().path == url.path else { throw Failure("Symlink fixture directory rejected") }
                let actual = try FileManager.default.contentsOfDirectory(atPath: url.path)
                let names = directory.entries.map(\.name)
                guard !names.isEmpty, Set(names).count == names.count, Set(names) == Set(actual),
                      directory.path != "large" || names.count == fixture.largeCount else { throw Failure("Fixture content mismatch: \(directory.path)") }
                for entry in directory.entries {
                    guard !entry.name.contains("/"), entry.name != ".", entry.name != "..", entry.size > 0 else { throw Failure("Invalid fixture entry") }
                    let file = url.appendingPathComponent(entry.name)
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          (attributes[.size] as? NSNumber)?.int64Value == entry.size,
                          abs(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) - entry.mtime) < 0.01 else {
                        throw Failure("Fixture file metadata mismatch: \(directory.path)/\(entry.name)")
                    }
                }
            }
            return fixture
        }
    }

    /// All mutable state belongs to `queue`. MainActor only acknowledges probes by dispatching back.
    /// Priming synchronously before each stage ensures a synchronous main-thread stall is observed too.
    private final class Heartbeat: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.kbwumin13.dirdesk.performance-heartbeat", qos: .userInitiated)
        private var timer: DispatchSourceTimer?
        private var running = false
        private var pending = false
        private var skipped = 0
        private var delays: [Double] = []
        private var peak: UInt64?
        private var tickCount = 0

        func start() {
            queue.sync {
                running = true
                tick()
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
                source.setEventHandler { [weak self] in self?.tick() }
                timer = source
                source.resume()
            }
        }

        private func tick() {
            guard running else { return }
            if tickCount % 5 == 0, let usage = ProcessUsage.current() { peak = max(peak ?? 0, usage.footprintBytes) }
            tickCount += 1
            guard !pending else { skipped += 1; return }
            pending = true
            let enqueued = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor [self] in
                let delay = Double(DispatchTime.now().uptimeNanoseconds - enqueued) / 1_000_000
                queue.async { [self] in delays.append(delay); pending = false }
            }
        }

        @MainActor
        func stop() async -> (HeartbeatResult, UInt64?) {
            queue.sync { running = false; timer?.cancel(); timer = nil }
            // Do not block MainActor with queue.sync while waiting for an outstanding MainActor probe.
            while queue.sync(execute: { pending }) { try? await Task.sleep(nanoseconds: 1_000_000) }
            return queue.sync {
                let sorted = delays.sorted()
                func percentile(_ p: Double) -> Double? {
                    guard !sorted.isEmpty else { return nil }
                    return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))]
                }
                return (HeartbeatResult(intervalMilliseconds: 20, sampleCount: delays.count, skippedTicksWhilePending: skipped,
                                        p50Milliseconds: percentile(0.50), p95Milliseconds: percentile(0.95), maxMilliseconds: sorted.last,
                                        delaysMilliseconds: delays), peak)
            }
        }
    }
}
