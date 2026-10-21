import AppKit
import DirDeskCore

struct LightningTrashedItem: Sendable {
    let original: URL
    /// Where the item went; nil when the volume deleted it instead of keeping it in a Trash.
    let trashed: URL?
}

struct LightningTrashOutcome: Sendable {
    var moved: [LightningTrashedItem] = []
    var failures: [String] = []
}

/// File actions on Lightning Search results.
enum LightningSearchActions {
    /// Posted with the items as `[URL]` in `object`; the app stages them in File Transit.
    static let stageItemsNotification = Notification.Name("DirDeskStageItems")
    /// Cut marks the first pasteboard item with this type (value "true"), so a paste moves instead of copies.
    static let cutMarkerType = NSPasteboard.PasteboardType("com.kbwumin13.dirdesk.cut")

    @MainActor
    static func copy(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    @MainActor
    static func cut(_ urls: [URL]) {
        let items = urls.enumerated().map { offset, url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.path, forType: .string)
            if offset == 0 { item.setString("true", forType: cutMarkerType) }
            return item
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    @MainActor
    static func copyPaths(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Moves items to the Trash. Runs file operations synchronously: call it off the main thread.
    static func trash(_ urls: [URL]) -> LightningTrashOutcome {
        var outcome = LightningTrashOutcome()
        for url in urls {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                outcome.moved.append(LightningTrashedItem(original: url, trashed: resulting as URL?))
            } catch {
                outcome.failures.append(url.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        return outcome
    }

    /// Undo puts the items back where they were, with the same safety checks as other file changes.
    @MainActor
    static func registerUndo(_ items: [LightningTrashedItem], in undoManager: UndoManager?) {
        let steps = items.reversed().compactMap { item in item.trashed.map { FileUndoStep.move($0, to: item.original) } }
        FileUndo.register(steps, name: L("Move to Trash"), undoManager: undoManager)
    }
}
