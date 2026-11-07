import Foundation
import Darwin
import PDFKit
import MijiCore

struct MijiPreviewResolution {
    var text: String
    var page: Int?
    var line: Int?
    var warning: String?
}

/// Resolves a selected result only. It never extracts new content or writes the index.
enum MijiPreviewResolver {
    static let textLimit = 16_000

    static func terms(in query: String) -> [String] {
        var seen = Set<String>()
        return QueryParser.parse(query).terms.compactMap {
            guard $0.field == .text, !$0.isExcluded, seen.insert($0.value).inserted else { return nil }
            return $0.value
        }
    }

    /// Checking availability precedes every live preview, including Quick Look and playback.
    /// Reading a File Provider placeholder here must not start a download.
    static func localURL(for hit: SearchHit) -> URL? {
        guard hit.root.isOnline else { return nil }
        let url = URL(fileURLWithPath: hit.path)
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR),
              info.st_flags & UInt32(SF_DATALESS) == 0,
              access(url.path, R_OK) == 0 else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              !(values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded)
        else { return nil }
        return url
    }

    static func resolve(hit: SearchHit, content: ExtractedContent?, query: String,
                        cancelled: () -> Bool) -> MijiPreviewResolution {
        guard !cancelled() else { return MijiPreviewResolution(text: "", page: nil, line: nil, warning: nil) }
        let words = terms(in: query)
        let body = content?.text ?? ""
        let match = firstMatch(in: body, words: words, cancelled: cancelled)
        var result = MijiPreviewResolution(text: excerpt(body.isEmpty ? hit.snippet : body, around: match),
                                       page: nil, line: nil, warning: content?.warning)
        if hit.file.kind == .code, let match, !cancelled() {
            let before = body[..<match.lowerBound]
            let line = before.unicodeScalars.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            result.line = line
            let lines = body.components(separatedBy: "\n")
            let start = max(0, line - 6), end = min(lines.count, line + 24)
            result.text = String((start..<end).map { "\($0 + 1)  \(lines[$0])" }.joined(separator: "\n").prefix(textLimit))
        }
        guard hit.file.fileExtension.lowercased() == "pdf", !words.isEmpty, !cancelled() else { return result }
        if let match, let ranges = content?.pageRanges {
            let offset = body[..<match.lowerBound].utf8.count
            let total = body.utf8.count
            if let range = ranges.first(where: {
                $0.page > 0 && $0.utf8Offset >= 0 && $0.utf8Length > 0 &&
                $0.utf8Offset <= total && $0.utf8Length <= total - $0.utf8Offset &&
                offset >= $0.utf8Offset && offset - $0.utf8Offset < $0.utf8Length
            }) {
                result.page = range.page
                return result
            }
        }
        // Old indexes have no page boundaries. Search only the selected local PDF's
        // text layer, with cancellation between pages. Scanned pages need a saved map.
        guard let url = localURL(for: hit) else { return result }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1024 * 1024 else {
            result.warning = joined(result.warning, "PDF 较大，未扫描命中页；仍可手动翻页")
            return result
        }
        let deadline = Date().addingTimeInterval(2)
        guard let document = PDFDocument(url: url), !document.isLocked else { return result }
        for index in 0..<document.pageCount {
            if cancelled() { return result }
            if Date() >= deadline {
                result.warning = joined(result.warning, "命中页查找已达到时间上限；仍可手动翻页")
                return result
            }
            let text = autoreleasepool { document.page(at: index)?.string ?? "" }
            if firstMatch(in: text, words: words, cancelled: cancelled) != nil {
                result.page = index + 1
                return result
            }
        }
        return result
    }

    private static func firstMatch(in text: String, words: [String], cancelled: () -> Bool) -> Range<String.Index>? {
        var first: Range<String.Index>?
        for word in words {
            guard !cancelled() else { return nil }
            if let found = text.range(of: word, options: [.caseInsensitive]),
               first == nil || found.lowerBound < first!.lowerBound { first = found }
        }
        return first
    }

    private static func excerpt(_ text: String, around match: Range<String.Index>?) -> String {
        guard let match else { return String(text.prefix(textLimit)) }
        let start = text.index(match.lowerBound, offsetBy: -800, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(textLimit))
    }

    private static func joined(_ existing: String?, _ message: String) -> String {
        existing.map { $0 + "；" + message } ?? message
    }
}
