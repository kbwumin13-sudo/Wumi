import AppKit
import DirDeskCore
import MijiCore

/// Opt-in acceptance for the actual embedded Miji model, using an explicit scratch catalog.
@MainActor
enum DebugMijiRun {
    static func run(output: URL) {
        guard let path = UserDefaults.standard.string(forKey: "WumiSearchDatabase"),
              path.hasPrefix(output.deletingLastPathComponent().path + "/"),
              LightningSearchService.isReadOnly else { return }
        Task { @MainActor in
            var checks: [[String: Any]] = []
            func check(_ name: String, _ value: Bool, _ detail: String = "") { checks.append(["name": name, "passed": value, "detail": detail]) }
            @MainActor func wait(_ condition: () -> Bool) async -> Bool {
                let until = ProcessInfo.processInfo.systemUptime + 15
                while !condition(), ProcessInfo.processInfo.systemUptime < until {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return condition()
            }
            do {
                try fixture(databaseURL: URL(fileURLWithPath: path))
                let service = LightningSearchService.shared
                service.ensureStarted()
                check("shared index loaded", await wait { service.engine != nil })
                let model = MijiSearchModel()
                model.setSearchVisible(true)
                @MainActor func search(_ text: String) async -> [SearchHit] {
                    model.query = ""
                    model.query = text
                    _ = await wait { !model.searching }
                    return model.hits
                }
                check("Chinese filename", await search("数学分析").contains { $0.file.name == "数学分析笔记.md" })
                model.query = "a different request"
                check("debounce clears stale result actions", model.searching && model.hits.isEmpty && model.selectedID == nil)
                check("pinyin", await search("shuxue").contains { $0.file.name == "数学分析笔记.md" })
                check("pinyin initials", await search("sxfx").contains { $0.file.name == "数学分析笔记.md" })
                model.scope = .name
                check("name-only excludes body", await search("ORIGINAL_BODY_TOKEN").isEmpty)
                model.scope = .content
                check("document body", await search("ORIGINAL_BODY_TOKEN").map(\.file.name) == ["Wumi-note.txt"])
                model.scope = .all
                _ = await search("ORIGINAL_BODY_TOKEN")
                let contentSelection = model.selectedID
                model.refresh()
                check("catalog refresh keeps content selection pending", model.selectedID == contentSelection && !model.hits.isEmpty)
                _ = await wait { !model.searching }
                check("catalog refresh commits complete content results", model.selectedID == contentSelection && model.hits.map(\.file.name) == ["Wumi-note.txt"])
                // A window that goes away keeps results and selection, and pauses work until it returns.
                model.setWindowVisible(false)
                check("window away keeps results", model.selectedID == contentSelection && model.hits.map(\.file.name) == ["Wumi-note.txt"] && !model.searching)
                model.setWindowVisible(true)
                check("window back keeps selection", model.selectedID == contentSelection && model.hits.map(\.file.name) == ["Wumi-note.txt"])
                model.query = "shuxue"
                model.setWindowVisible(false)
                check("window away pauses a pending search", !model.searching)
                model.setWindowVisible(true)
                check("window back finishes the search", await wait { !model.searching } && model.hits.contains { $0.file.name == "数学分析笔记.md" })
                model.scope = .content
                check("image OCR", await search("ORIGINAL_OCR_TOKEN").map(\.file.name) == ["ocr-proof.png"])
                model.scope = .all
                model.kind = .image
                check("kind filter", await search("proof").map(\.file.name) == ["ocr-proof.png"])
                model.kind = nil
                check("extension syntax", Set(await search("ext:pdf proof").map(\.file.name)) == ["pdf-proof.pdf", "offline-proof.pdf"])
                check("excluded words", await search("proof -pdf").map(\.file.name) == ["ocr-proof.png"])
                check("no results", await search("no-such-file-27913").isEmpty)
                for text in ["proof", "数学", "no-such-file-27913", "Wumi-note"] { model.query = text }
                _ = await wait { !model.searching }
                check("latest query owns results", model.hits.map(\.file.name) == ["Wumi-note.txt"])
                var revealed: URL?
                model.onReveal = { revealed = $0 }
                model.revealSelected()
                check("Wumi reveal callback", revealed?.lastPathComponent == "Wumi-note.txt")
                model.setPreviewVisible(true)
                check("stored content preview", await wait { model.previewText.contains("ORIGINAL_BODY_TOKEN") })
                model.setPreviewVisible(false)
                model.rootID = "offline"
                check("offline results retained", await search("proof").map(\.file.name) == ["offline-proof.pdf"])
                revealed = nil
                model.revealSelected()
                check("offline reveal disabled", revealed == nil)
                model.rootID = nil
                model.scope = .name
                model.sort = .size
                check("size sorting", await search("proof").map(\.file.size) == [400, 300, 200])
                model.context = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("files/Folder")
                model.currentFolderOnly = true
                let scoped = await search("scope")
                check("folder boundary excludes sibling paths", scoped.map(\.file.name) == ["scope-inside.txt"],
                      "paths=\(scoped.map(\.path)); roots=\(model.roots.map(\.path)); error=\(model.message ?? "")")
                model.setSearchVisible(false)
                model.query = "数学"
                check("hidden model cancels search", !model.searching)
                check("collapsed panel height", MijiSearchModel.panelHeight(query: "", resultCount: 0) == 100)
                check("expanded panel height", MijiSearchModel.panelHeight(query: "a", resultCount: 9) == 563)
                let editor = NSTextView()
                editor.setMarkedText("shuxue", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                check("IME Return belongs to composition", MijiSearchKeyAction.action(for: enter, firstResponder: editor) == nil)
                editor.unmarkText()
                check("Return opens", MijiSearchKeyAction.action(for: enter, firstResponder: editor) == .open)
                let reveal = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                check("Command Return reveals", MijiSearchKeyAction.action(for: reveal, firstResponder: editor) == .reveal)
            } catch { checks.append(["name": "fixture and model acceptance", "passed": false, "error": error.localizedDescription]) }
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let result: [String: Any] = ["checks": checks, "passed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("miji-acceptance.json"), options: .atomic)
            }
            try? Data().write(to: output.appendingPathComponent("miji-acceptance-done"))
            NSApp.terminate(nil)
        }
    }

    private static func fixture(databaseURL: URL) throws {
        let db = try SearchDatabase(url: databaseURL)
        let folder = databaseURL.deletingLastPathComponent().appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try db.saveRoot(IndexedRoot(id: "local", path: folder.path, name: "本地测试"))
        try db.saveRoot(IndexedRoot(id: "offline", path: "/Volumes/Wumi-Miji-Offline", name: "离线测试", isExternal: true, isOnline: false))
        for (name, root, kind, size, text) in [
            ("数学分析笔记.md", "local", FileKind.document, 100, "连续函数与极限"),
            ("Wumi-note.txt", "local", .document, 150, "ORIGINAL_BODY_TOKEN"),
            ("ocr-proof.png", "local", .image, 200, "ORIGINAL_OCR_TOKEN"),
            ("pdf-proof.pdf", "local", .document, 300, "PDF 提取正文"),
            ("Folder/scope-inside.txt", "local", .document, 20, "inside"),
            ("FolderSibling/scope-outside.txt", "local", .document, 20, "outside"),
            ("offline-proof.pdf", "offline", .document, 400, "离线保存的正文")
        ] {
            let file = FileRecord(rootID: root, relativePath: name, name: (name as NSString).lastPathComponent,
                fileExtension: (name as NSString).pathExtension, kind: kind, size: Int64(size), modified: 1_792_598_400)
            try db.upsertFiles([file], generation: 1)
            if let saved = try db.catalogBatch(afterID: 0, limit: 100).first(where: { $0.file.rootID == root && $0.file.relativePath == name })?.file {
                _ = try db.completeContent(file: saved, content: ExtractedContent(text: text))
            }
            if root == "local" {
                let url = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }
    }
}
