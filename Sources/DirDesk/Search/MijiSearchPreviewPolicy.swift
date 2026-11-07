import Foundation
import MijiCore

enum MijiSearchPreviewMode: String, CaseIterable, Identifiable {
    case automatic, shown, hidden
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .shown: return "显示"
        case .hidden: return "隐藏"
        }
    }
}

/// Result metadata only: no file probes, extraction, or thumbnail requests.
/// Selection and asynchronous loading outcomes never change the panel size.
enum MijiSearchPreviewPolicy {
    static func usesTextReader(_ hit: SearchHit) -> Bool {
        hit.file.kind == .code || (hit.file.kind == .document && ["txt", "md", "markdown", "csv", "tsv", "log"].contains(hit.file.fileExtension.lowercased()))
    }

    /// Keep local-file previews available before indexing finishes or after an
    /// extraction failure. This renders the selected original without extracting it.
    static func usesSystemPreview(_ hit: SearchHit, hasIndexedText: Bool) -> Bool {
        (hit.file.kind == .document || hit.file.kind == .code) && hit.file.fileExtension.lowercased() != "pdf" &&
            !(usesTextReader(hit) && hasIndexedText)
    }

    static func hasContent(_ hit: SearchHit) -> Bool {
        switch hit.file.kind {
        case .image, .document, .code, .audio, .video: return true
        case .application, .folder, .archive: return false
        case .other:
            return hit.matchedIn.contains("正文") && !hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func showsPane(mode: MijiSearchPreviewMode, hits: [SearchHit]) -> Bool {
        guard !hits.isEmpty else { return false }
        switch mode {
        case .automatic: return hits.contains(where: hasContent)
        case .shown: return true
        case .hidden: return false
        }
    }
}
