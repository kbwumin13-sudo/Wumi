import AppKit
import DirDeskCore

/// Exercises close through the real window delegate, including the hosted SwiftUI hierarchy.
@MainActor
enum DebugWindowLifetimeChecks {
    private struct References {
        weak var controller: WorkspaceController?
        weak var model: WorkspaceModel?
        weak var window: NSWindow?
    }

    static func run(output: URL) {
        Task { @MainActor in
            var lines: [String] = []
            await check { name, passed, detail in
                lines.append("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
            }
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try? (lines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("window-lifetime.txt"), atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: output.appendingPathComponent("window-lifetime-done").path, contents: nil)
            NSApp.terminate(nil)
        }
    }

    static func check(report: (String, Bool, String) -> Void) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wumi-window-lifetime-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("lifecycle".utf8).write(to: folder.appendingPathComponent("example.txt"))
        } catch { report("window lifetime fixture", false, error.localizedDescription); return }
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalCount = appDelegate.controllers.count
        var references: [References] = []
        for mode in BrowserViewMode.allCases { references.append(await openAndClose(folder, mode: mode)) }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline && references.contains(where: { $0.controller != nil || $0.model != nil || $0.window != nil }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        report("closed windows leave the application registry", appDelegate.controllers.count == originalCount, "")
        report("closed workspace controllers are released", references.allSatisfy { $0.controller == nil }, "retained=\(references.filter { $0.controller != nil }.count)/4")
        report("closed workspace models are released", references.allSatisfy { $0.model == nil }, "retained=\(references.filter { $0.model != nil }.count)/4")
        report("closed workspace windows are released", references.allSatisfy { $0.window == nil }, "retained=\(references.filter { $0.window != nil }.count)/4")
    }

    private static func openAndClose(_ folder: URL, mode: BrowserViewMode) async -> References {
        let controller = appDelegate.newWindow(directory: folder)
        controller.activePane.viewConfiguration.mode = mode
        await controller.activePane.waitForRows()
        try? await Task.sleep(for: .milliseconds(100))
        let result = References(controller: controller, model: controller.model, window: controller.window)
        controller.close()
        return result
    }
}
