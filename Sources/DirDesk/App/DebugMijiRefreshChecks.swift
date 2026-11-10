import AppKit
import Combine
import DirDeskCore
import MijiCore

/// Runs only from the existing opt-in, scratch-database model acceptance route.
@MainActor
enum DebugMijiRefreshChecks {
    static func run(databaseURL: URL, check: (String, Bool, String) -> Void) async throws {
        let database = try SearchDatabase(url: databaseURL)
        let service = LightningSearchService.shared
        guard let file = try database.catalogBatch(afterID: 0, limit: 100).first(where: { $0.file.name == "Wumi-note.txt" })?.file else {
            check("refresh fixture exists", false, "")
            return
        }
        _ = try database.completeContent(file: file, content: ExtractedContent(text: "ORIGINAL_BODY_TOKEN"))
        service.catalogDidChange(contentChanged: true)
        let model = MijiSearchModel()
        model.setSearchVisible(true)
        model.query = "Wumi-note"
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return condition()
        }
        _ = await wait { !model.searching && !model.previewText.isEmpty }
        try await Task.sleep(for: .milliseconds(2200))
        _ = await wait { !model.searching && !model.previewText.isEmpty }
        let snapshot = model.displayedSnapshot, selected = model.selectedID, preview = model.previewText
        var stayedCurrent = true, keptPreview = !preview.isEmpty, keptSelection = true, keptActions = true
        let initialIndex = service.indexGeneration
        for _ in 0..<3 {
            service.catalogDidChange()
            for _ in 0..<440 {
                stayedCurrent = stayedCurrent && model.currentSnapshot == snapshot && model.displayedSnapshot == snapshot
                keptPreview = keptPreview && model.previewText == preview
                keptSelection = keptSelection && model.selectedID == selected
                keptActions = keptActions && model.canPerformFileAction(.copyPath) && model.canPerformFileAction(.reveal)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        check("same query three catalog events never dim results", stayedCurrent, "")
        check("same query catalog events never clear preview", keptPreview, "")
        check("same query catalog events retain selection", keptSelection, "")
        check("same query catalog events keep current actions usable", keptActions, "")
        check("catalog notifications still reach the model", service.indexGeneration == initialIndex + 3, "")

        if let hit = model.selected {
            let old = model.displayedSnapshot
            model.query = "different request"
            model.query = "Wumi-note"
            _ = await wait { !model.searching }
            check("A B A rejects the first A callback", !model.isCurrentResult(hit, snapshot: old), "")
            let board = NSPasteboard.withUniqueName()
            board.setString("unchanged", forType: .string)
            model.performFileAction(.copyPath, hit: hit, snapshot: old, pasteboard: board)
            check("A B A stale menu cannot mutate pasteboard", board.string(forType: .string) == "unchanged", "")
            board.releaseGlobally()
            model.message = nil
            for change in [0, 1, 2] {
                let current = model.displayedSnapshot
                if change == 0 { model.kind = .image }
                if change == 1 { model.sort = .size }
                if change == 2 { model.context = databaseURL.deletingLastPathComponent() }
                check("request criterion \(change) immediately gates old row", !model.isCurrentResult(hit, snapshot: current), "")
                model.kind = nil; model.sort = .relevance; model.context = nil
                _ = await wait { !model.searching }
            }
        }

        if let root = try database.roots().first(where: { $0.id == "local" }), let hit = model.selected {
            let old = model.displayedSnapshot
            var moved = root
            moved.path += "/relocated-root"
            try database.saveRoot(moved); service.catalogDidChange()
            _ = await wait { model.roots.first { $0.id == root.id }?.path == moved.path }
            check("root path change immediately gates old callback", !model.isCurrentResult(hit, snapshot: old), "")
            try database.saveRoot(root); service.catalogDidChange()
            _ = await wait { !model.searching && model.roots.first { $0.id == root.id }?.path == root.path }
            check("root path A B A rejects first A callback", !model.isCurrentResult(hit, snapshot: old), "")
            let hiddenSnapshot = model.displayedSnapshot
            let hiddenHit = model.selected!
            model.setWindowVisible(false)
            try database.saveRoot(moved); service.refreshRoots()
            _ = await wait { model.roots.first { $0.id == root.id }?.path == moved.path }
            try database.saveRoot(root); service.refreshRoots()
            _ = await wait { model.roots.first { $0.id == root.id }?.path == root.path }
            model.setWindowVisible(true)
            let resumedRoot = await wait { !model.searching && model.displayedSnapshot == model.currentSnapshot }
            check("hidden root changes execute deferred request on show", resumedRoot && model.selected.map { model.isCurrentResult($0) } == true, "")
            check("hidden root path A B A rejects first A menu", !model.isCurrentResult(hiddenHit, snapshot: hiddenSnapshot), "")
            check("hidden root path A B A rejects first A media", model.fileOperationURL(for: hiddenHit, action: .preview, snapshot: hiddenSnapshot) == nil, "")
            model.message = nil

            let url = URL(fileURLWithPath: root.path).appendingPathComponent("refresh-replacement.txt")
            try Data("original".utf8).write(to: url)
            let signature = try FileSignature.read(url)
            try database.upsertFiles([FileRecord(rootID: root.id, relativePath: url.lastPathComponent, name: url.lastPathComponent,
                fileExtension: "txt", kind: .document, size: signature.size, modified: signature.modified, inode: signature.inode)], generation: 1)
            try service.engine?.names.refresh(rootID: root.id, relativePaths: [url.lastPathComponent], fullRescan: false)
            service.catalogDidChange()
            model.scope = .name; model.query = "refresh-replacement"
            _ = await wait { !model.searching && model.selected?.file.name == url.lastPathComponent }
            let replacement = url.appendingPathExtension("new")
            try Data("replacement".utf8).write(to: replacement)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)
            check("same path replacement cannot open previous file identity", !model.canPerformFileAction(.open), "")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            check("file replaced by directory cannot cut or move", !model.canPerformFileAction(.cutReference) && !model.canPerformFileAction(.sendTo), "")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: root.path).appendingPathComponent("Wumi-note.txt"))
            check("file replaced by symlink cannot open or copy", !model.canPerformFileAction(.open) && !model.canPerformFileAction(.copyReference), "")
            try FileManager.default.removeItem(at: url)
            check("missing file cannot reveal previous row", !model.canPerformFileAction(.reveal), "")
        }

        let resumed = MijiSearchModel()
        var hidFirstBatch = false
        let observer = resumed.$searchPhase.sink { phase in
            if phase == .supplementing, !hidFirstBatch, !resumed.hits.isEmpty {
                hidFirstBatch = true
                resumed.setWindowVisible(false)
            }
        }
        resumed.setSearchVisible(true)
        // Drain the subscriptions' initial catalog publish before observing a user query.
        try await Task.sleep(for: .milliseconds(2400))
        resumed.query = "Wumi-note"
        _ = await wait { hidFirstBatch }
        resumed.setWindowVisible(true)
        let completed = await wait { !resumed.searching && resumed.searchPhase == .complete }
        check("unfinished foreground resume records completed timing", hidFirstBatch && completed && resumed.completedMilliseconds != nil && resumed.searchStatus.timing == .complete, "firstBatchCaptured=\(hidFirstBatch)")
        observer.cancel(); resumed.setSearchVisible(false)

        for scope in [SearchScope.all, .content] {
            _ = try database.completeContent(file: file, content: ExtractedContent(text: "STABLE_REFRESH_TOKEN first version"))
            service.catalogDidChange(contentChanged: true)
            model.scope = scope; model.query = "STABLE_REFRESH_TOKEN"
            _ = await wait { !model.searching && model.hits.contains { $0.id == file.id } && model.previewText.contains("first version") }
            _ = try database.completeContent(file: file, content: ExtractedContent(text: "STABLE_REFRESH_TOKEN second version"))
            service.catalogDidChange(contentChanged: true)
            let updated = await wait { !model.searching && model.hits.first?.snippet.contains("second version") == true && model.previewText.contains("second version") }
            check("\(scope) unchanged query refreshes snippet and preview", updated, "")
            _ = try database.completeContent(file: file, content: ExtractedContent(text: "removed keyword"))
            service.catalogDidChange(contentChanged: true)
            check("\(scope) unchanged query removes obsolete body match", await wait { !model.searching && model.hits.isEmpty }, "")
        }
        model.setSearchVisible(false)
        check("refresh checks close and release preview", !model.searching && model.hits.isEmpty && model.previewText.isEmpty && model.previewPDF == nil, "")
        _ = try database.completeContent(file: file, content: ExtractedContent(text: "ORIGINAL_BODY_TOKEN"))
        service.catalogDidChange(contentChanged: true)
    }
}
