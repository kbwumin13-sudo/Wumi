import AppKit
import DirDeskCore
import SwiftUI

/// Opt-in fixture acceptance through the same observable model and AppKit result table as the live UI.
/// Never runs against an implicit database or changes the user's files.
@MainActor
enum DebugIntegrationRun {
    static func run(output: URL) {
        guard UserDefaults.standard.string(forKey: "WumiSearchDatabase") != nil else { return }
        Task { @MainActor in
            let performance = UserDefaults.standard.bool(forKey: "WumiIntegrationPerformance")
            let activity = performance ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measure interactive search without App Nap") : nil
            defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
            var checks: [[String: Any]] = []
            func check(_ name: String, _ passed: Bool, _ detail: String = "") {
                checks.append(["name": name, "passed": passed, "detail": detail])
            }
            @MainActor func wait(_ condition: () -> Bool, seconds: Double = 8) async -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + seconds
                while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return condition()
            }
            let service = LightningSearchService.shared
            let loadStart = ProcessInfo.processInfo.systemUptime
            service.ensureStarted()
            check("index is searchable", await wait({ service.engine != nil && service.status.stage.isSearchable }, seconds: 90))
            let loadMilliseconds = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            let folder = UserDefaults.standard.string(forKey: "WumiDesktopFolder").map { URL(fileURLWithPath: $0) }
            let model = CompactSearchModel(context: nil, workspace: [], onReveal: { _ in })
            model.match = .name
            let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 530),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("Wumi.IntegrationAcceptance")
            window.contentView = NSHostingView(rootView: CompactSearchView(model: model, onDismiss: {}))
            window.orderFront(nil)
            @MainActor func search(_ query: String, match: CompactSearchModel.Match = .name) async -> [LightningRow] {
                model.match = match
                model.query = query
                _ = await wait({ !model.searching }, seconds: 15)
                return model.rows
            }
            var timings: [[String: Any]] = []
            if performance {
                for _ in 0..<30 {
                    for query in ["README", "数学", "shuxue", "sx", "Wumi", "不存在的文件-zz981"] {
                        model.query = ""
                        let start = ProcessInfo.processInfo.systemUptime
                        let rows = await search(query)
                        timings.append(["query": query, "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                        "engineMilliseconds": model.elapsedMilliseconds,
                                        "count": rows.count, "completed": !model.searching])
                    }
                }
                check("180 observable query completions", timings.count == 180 && timings.allSatisfy { $0["completed"] as? Bool == true })
            } else {
                let scoped = CompactSearchModel(context: folder, workspace: [], onReveal: { _ in })
                check("folder surface defaults to current folder", folder != nil && scoped.currentFolderOnly)
                check("global surface defaults to computer", !model.currentFolderOnly)
                check("name lookup", await search("Wumi-note").contains { $0.name == "Wumi-note.txt" })
                model.query = "no-such-name-23981"
                check("new query immediately removes stale actions", model.rows.isEmpty && model.searching)
                _ = await wait({ !model.searching })
                check("no results do not inherit old rows", model.rows.isEmpty)
                check("Chinese pinyin", await search("shuxue").contains { $0.name == "数学分析笔记.md" })
                check("document content", await search("WUMI_CONTENT_TOKEN_2026", match: .contents).contains { $0.name == "Wumi-note.txt" })
                check("image OCR", await search("OCR CHECK", match: .contents).contains { $0.name == "ocr-proof.png" })
                check("PDF text extraction or OCR", await search("WUMI_PDF_CONTENT_2026", match: .contents).contains { $0.name == "pdf-proof.pdf" })
                let andRows = await search("name:report AND content:WUMI_NESTED_TOKEN_2026")
                check("name AND content stays conjunctive", andRows.map(\.name) == ["report-budget.txt"], andRows.map(\.name).joined(separator: ","))
                let notRows = await search("name:report NOT content:WUMI_NESTED_TOKEN_2026")
                check("content negation", notRows.contains { $0.name == "report-other.txt" } && !notRows.contains { $0.name == "report-budget.txt" })
                _ = await search("Wumi-note")
                model.query = "size:nope"
                _ = await wait({ !model.searching })
                check("syntax failure clears old results", model.rows.isEmpty && model.error != nil)
                for query in ["Wumi", "report", "shuxue", "Wumi-note"] { model.query = query }
                _ = await wait({ !model.searching })
                check("rapid query cancellation keeps newest results", model.rows.map(\.name) == ["Wumi-note.txt"])
                model.setVisible(false)
                model.query = "report"
                check("hidden surface does not start queries", !model.searching && model.rows.isEmpty)
                if UserDefaults.standard.bool(forKey: "WumiIntegrationLiveIndex"), let folder,
                   folder.path.contains("/artifacts/"), !LightningSearchService.isReadOnly {
                    let text = folder.appendingPathComponent("Wumi-live-" + UUID().uuidString + ".txt")
                    let image = folder.appendingPathComponent("Wumi-live-" + UUID().uuidString + ".png")
                    defer { try? FileManager.default.removeItem(at: text); try? FileManager.default.removeItem(at: image) }
                    model.setVisible(true)
                    _ = await search("WUMI_LIVE_INDEX_TOKEN_2026", match: .contents)
                    do {
                        try Data("WUMI_LIVE_INDEX_TOKEN_2026".utf8).write(to: text, options: .withoutOverwriting)
                        check("live document appears without changing query", await wait({ model.rows.contains { $0.path == text.path } }, seconds: 25))
                        _ = await search("OCR CHECK", match: .contents)
                        try FileManager.default.copyItem(at: folder.appendingPathComponent("ocr-proof.png"), to: image)
                        check("owned OCR helper updates a live query", await wait({ model.rows.contains { $0.path == image.path } }, seconds: 25))
                        try FileManager.default.removeItem(at: image)
                        check("deleted file disappears from live results", await wait({ !model.rows.contains { $0.path == image.path } }, seconds: 25))
                    } catch { check("live indexing fixture operations", false, error.localizedDescription) }
                    model.setVisible(false)
                }
            }
            model.setVisible(false)
            window.orderOut(nil)
            let report: [String: Any] = ["completed": true, "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
                                         "checks": checks, "queryTimings": timings, "loadMilliseconds": loadMilliseconds,
                                         "timingNote": "Observable result completion, sampled every 10 ms; includes 20 ms debounce and main-queue delivery. An explicit interactive activity prevents App Nap during the benchmark. Not display frame latency."]
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("integration.json"), options: .atomic)
            }
            try? Data().write(to: output.appendingPathComponent("integration-done"))
            NSApp.terminate(nil)
        }
    }
}
