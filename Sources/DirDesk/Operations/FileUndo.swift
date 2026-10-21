import AppKit
import DirDeskCore

/// Undo and redo of file changes, with the original's safety stops: before anything is touched, every item must still
/// be where DirDesk left it, unchanged, and its old place must be free. Otherwise nothing changes and the user is told
/// why. A successful undo registers the exact reverse as redo, and the other way round.
@MainActor
enum FileUndo {
    /// Registers `steps` (what undo should do) under `name` on the window's undo manager.
    static func register(_ steps: [FileUndoStep], name: String, undoManager: UndoManager?) {
        guard let undoManager, !steps.isEmpty else { return }
        undoManager.registerUndo(withTarget: NSApp) { _ in
            run(steps, name: name, undoManager: undoManager)
        }
        undoManager.setActionName(name)
    }

    private static func run(_ steps: [FileUndoStep], name: String, undoManager: UndoManager) {
        let redoing = undoManager.isRedoing
        if let stop = FileUndoSafety.verify(steps) {
            report(message(for: stop))
            return
        }
        do {
            let reverse = try FileUndoSafety.perform(steps)
            register(reverse, name: name, undoManager: undoManager)
            NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
            appDelegate.activeController?.activePane.operationResult = .init(
                summary: redoing ? L("File operation redone") : L("File operation undone"), details: [], showsEllipsis: false)
        } catch {
            NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
            report(error.localizedDescription)
        }
    }

    static func message(for stop: FileUndoStop) -> String {
        switch stop {
        case .missing(let name): LF("Undo stopped: “%@” is no longer there.", name)
        case .occupied(let name): LF("Undo stopped: another item is now named “%@”.", name)
        case .changed(let name): LF("Undo stopped: “%@” was changed outside Wumi.", name)
        }
    }

    private static func report(_ message: String) {
        if let controller = appDelegate.activeController {
            controller.presentError(message)
        } else {
            ApplicationErrorLog.shared.record(message: message, source: .fileOperation)
            NSSound.beep()
        }
    }
}
