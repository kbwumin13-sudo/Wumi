import AppKit

enum MijiSearchKeyAction: Equatable {
    case focusSearch, reveal, preview, copyPath, hide, settings, moveDown, moveUp, open

    @MainActor
    static func action(for event: NSEvent, firstResponder: NSResponder?) -> MijiSearchKeyAction? {
        // The input method owns the whole key sequence until marked text is committed.
        // In particular, Return commits literal pinyin; it must not open a search result.
        if let client = firstResponder as? NSTextInputClient, client.hasMarkedText() {
            return nil
        }
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.keyCode {
            case 3: return .focusSearch
            case 15: return .reveal
            case 16: return .preview
            case 8 where event.modifierFlags.contains(.shift): return .copyPath
            case 13: return .hide
            case 43: return .settings
            default: break
            }
        }
        switch event.keyCode {
        case 125: return .moveDown
        case 126: return .moveUp
        case 36, 76: return command ? .reveal : .open
        case 49 where !(firstResponder is NSTextView): return .preview
        case 53: return .hide
        default: return nil
        }
    }
}
