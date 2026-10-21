import AppKit
import DirDeskCore

/// Single-step file operations with undo: rename, trash, new folder/file, duplicate, alias.
@MainActor
enum FileOperations {
    struct OperationError: Error {
        let message: String
    }

    static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw OperationError(message: L("A file name cannot be empty or contain a slash."))
        }
        return trimmed
    }

    /// Renames in place. Asks before changing a file extension, like the original.
    @discardableResult
    static func rename(_ url: URL, to newName: String, undoManager: UndoManager?, confirmExtension: Bool = true) throws -> URL {
        let name = try validateName(newName)
        let oldExtension = url.pathExtension
        let newExtension = (name as NSString).pathExtension
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        var finalName = name
        if confirmExtension, !isDirectory.boolValue, oldExtension.lowercased() != newExtension.lowercased(), !oldExtension.isEmpty || !newExtension.isEmpty {
            if extensionAlert(oldExtension: oldExtension, newExtension: newExtension).runModal() == .alertSecondButtonReturn {
                let base = (name as NSString).deletingPathExtension
                finalName = oldExtension.isEmpty ? base : base + "." + oldExtension
            }
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(finalName)
        guard destination.path != url.path else { return url }
        let caseOnly = destination.path.lowercased() == url.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: destination.path) {
            throw OperationError(message: L("An item with that name already exists."))
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw OperationError(message: error.localizedDescription)
        }
        FileUndo.register([.move(destination, to: url)], name: L("Rename"), undoManager: undoManager)
        return destination
    }

    /// "Use .new" (default) / "Keep .old", asked before a rename changes the extension.
    static func extensionAlert(oldExtension: String, newExtension: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("Change the file extension?")
        alert.informativeText = L("Changing an extension may cause the file to open in a different application.")
        alert.addButton(withTitle: newExtension.isEmpty ? L("Remove Extension") : LF("Use .%@", newExtension))
        alert.addButton(withTitle: oldExtension.isEmpty ? L("Keep No Extension") : LF("Keep .%@", oldExtension))
        return alert
    }

    /// Moves items to the Trash and registers an undo that puts them back.
    static func trash(_ urls: [URL], undoManager: UndoManager?, completion: @escaping ([URL]) -> Void) {
        var pairs: [(URL, URL)] = []
        var failures: [String] = []
        for url in urls {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let trashed = resulting as URL? { pairs.append((url, trashed)) }
            } catch {
                failures.append(url.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        FileUndo.register(pairs.reversed().map { .move($0.1, to: $0.0) }, name: L("Move to Trash"), undoManager: undoManager)
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("The operation could not be completed.")
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
        completion(pairs.map(\.0))
    }

    static func uniqueName(_ base: String, in directory: URL) -> URL {
        let first = directory.appendingPathComponent(base)
        if !FileManager.default.fileExists(atPath: first.path) { return first }
        return FileOperationCoordinator.keepBothURL(for: first)
    }

    static func createFolder(in directory: URL, undoManager: UndoManager?) throws -> URL {
        let url = uniqueName(L("untitled folder"), in: directory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw OperationError(message: error.localizedDescription)
        }
        registerTrashUndo([url], name: L("New Folder"), undoManager: undoManager)
        return url
    }

    static func createFile(from template: NewFileTemplate, in directory: URL, undoManager: UndoManager?) throws -> URL {
        let name = TemplateRenderer.fileName(for: template)
        let url = uniqueName(name, in: directory)
        let data = TemplateRenderer.contents(for: template)
        guard FileManager.default.createFile(atPath: url.path, contents: data) else {
            throw OperationError(message: L("The operation could not be completed."))
        }
        registerTrashUndo([url], name: L("New File"), undoManager: undoManager)
        return url
    }

    static func duplicate(_ urls: [URL], undoManager: UndoManager?) -> [URL] {
        var created: [URL] = []
        for url in urls {
            let destination = FileOperationCoordinator.keepBothURL(for: url)
            if (try? FileManager.default.copyItem(at: url, to: destination)) != nil { created.append(destination) }
        }
        registerTrashUndo(created, name: L("Duplicate"), undoManager: undoManager)
        return created
    }

    static func makeAlias(_ urls: [URL], undoManager: UndoManager?) -> [URL] {
        var created: [URL] = []
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let aliasName = LF("%@ alias", base) + (url.hasDirectoryPath || url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
            let destination = uniqueName(aliasName, in: url.deletingLastPathComponent())
            if let data = try? url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
               (try? URL.writeBookmarkData(data, to: destination)) != nil {
                created.append(destination)
            }
        }
        registerTrashUndo(created, name: L("Make Alias"), undoManager: undoManager)
        return created
    }

    /// Undo of creating items: they go to the Trash (redo brings them back).
    static func registerTrashUndo(_ urls: [URL], name: String, undoManager: UndoManager?) {
        FileUndo.register(urls.reversed().map { .trash($0) }, name: name, undoManager: undoManager)
    }

    /// Undo steps of a copy/move batch: copies go to the Trash, moves go back, replaced items return.
    static func undoSteps(for mutations: [FileOperationMutation]) -> [FileUndoStep] {
        var steps: [FileUndoStep] = []
        for mutation in mutations.reversed() {
            switch mutation.kind {
            case .copied: steps.append(.trash(mutation.destination))
            case .moved: steps.append(.move(mutation.destination, to: mutation.source))
            }
            if let backup = mutation.replacedBackupURL { steps.append(.move(backup, to: mutation.destination)) }
        }
        return steps
    }
}

/// Resolves template file names and contents, including `$date(FORMAT)` tokens and Office seeds.
enum TemplateRenderer {
    static func expandDates(_ text: String, now: Date = Date()) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\$date\\(([^()]*)\\)") else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let formatRange = Range(match.range(at: 1), in: text) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = String(text[formatRange]).isEmpty ? "yyyy-MM-dd" : String(text[formatRange])
            result.replaceSubrange(range, with: formatter.string(from: now))
        }
        return result
    }

    static func fileName(for template: NewFileTemplate, now: Date = Date()) -> String {
        var name = expandDates(template.fileNamePattern, now: now)
        if let format = template.dateFormat, !format.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            let stamp = formatter.string(from: now)
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            switch template.datePosition {
            case .beforeName: name = stamp + " " + name
            case .afterName: name = ext.isEmpty ? base + " " + stamp : base + " " + stamp + "." + ext
            }
        }
        return name
    }

    static func contents(for template: NewFileTemplate) -> Data {
        if let data = template.contentData { return data }
        if let kind = template.builtInKind, let seed = OfficeSeeds.seed(for: kind) { return seed }
        return Data(expandDates(template.contents).utf8)
    }
}
