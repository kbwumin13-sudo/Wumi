import AppKit
import AVKit
import PDFKit
import QuickLookUI

enum SearchKeyAction: Equatable {
    case focusSearch, reveal, preview, copyPath, hide, settings, moveDown, moveUp, moveLeft, moveRight, copyFile, open
    case selectMode(SearchMode)

    @MainActor
    static func action(for event: NSEvent, firstResponder: NSResponder?, navigateHorizontally: Bool = false) -> SearchKeyAction? {
        // The input method owns the whole key sequence until marked text is committed.
        // In particular, Return commits literal pinyin; it must not open a search result.
        if let client = firstResponder as? NSTextInputClient, client.hasMarkedText() {
            return nil
        }
        var parent=firstResponder as? NSView
        var embeddedPreview=false
        while let view=parent {
            if view is PDFView || view is AVPlayerView || view is QLPreviewView {embeddedPreview=true;break}
            parent=view.superview
        }
        let command = event.modifierFlags.contains(.command)
        if command {
            if event.modifierFlags.intersection([.control, .option, .shift]).isEmpty {
                switch event.keyCode {
                case 29: return .selectMode(.all)
                case 18: return .selectMode(.apps)
                case 19: return .selectMode(.files)
                case 20: return .selectMode(.clipboard)
                default: break
                }
            }
            switch event.keyCode {
            case 3: return .focusSearch
            case 15: return .reveal
            case 16: return .preview
            case 8 where event.modifierFlags.contains(.shift): return .copyPath
            case 8 where !(firstResponder is NSTextView) && !embeddedPreview: return .copyFile
            case 13: return .hide
            case 43: return .settings
            default: break
            }
        }
        if embeddedPreview {return nil}
        if let text=firstResponder as? NSTextView,!text.isEditable {return nil}
        let horizontalWithoutEditing = navigateHorizontally && event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
        let movesHorizontally = !(firstResponder is NSTextView) || horizontalWithoutEditing
        switch event.keyCode {
        case 123 where movesHorizontally: return .moveLeft
        case 124 where movesHorizontally: return .moveRight
        case 125: return .moveDown
        case 126: return .moveUp
        case 36, 76: return command ? .reveal : .open
        case 49 where !(firstResponder is NSTextView): return .preview
        case 53: return .hide
        default: return nil
        }
    }
}
