import Foundation

/// Runs potentially blocking system extractors in a disposable helper process.
/// The helper's `extract` command only emits content; database writes stay in the parent.
public enum IsolatedContentExtractor {
    private static let defaultTimeout: TimeInterval = 180
    // A UTF-8 byte can require six bytes as a JSON escape (e.g. \u0001).
    // Leave bounded room for labels, warnings, field names and pretty printing.
    private static let metadataBytes = 1024 * 1024
    private static let jsonBytes = ExtractionLimits.textBytes * 6 + metadataBytes

    public static func extract(url: URL, executable: URL,
                               cancelled: @escaping () -> Bool) throws -> ExtractedContent {
        try extract(url: url, executable: executable, cancelled: cancelled, timeout: defaultTimeout)
    }

    static func extract(url: URL, executable: URL, cancelled: @escaping () -> Bool,
                        timeout: TimeInterval) throws -> ExtractedContent {
        guard url.isFileURL, executable.isFileURL else {
            throw ContentExtractionError.invalidDocument("内容提取与 helper 必须使用本地文件 URL")
        }
        guard timeout.isFinite, timeout > 0, timeout <= defaultTimeout else {
            throw ContentExtractionError.invalidDocument("helper 超时必须大于 0 且不超过 180 秒")
        }
        let context = ExtractionContext(cancelled: cancelled)
        // This deadline is enforced by the parent, independently of Vision cancellation.
        // runExtractionProcess bounds both pipes and SIGKILLs/reaps on every failure.
        let output = try runExtractionProcess(executable.path, arguments: ["extract", "--file", url.path],
                                              limit: jsonBytes, context: context, timeout: timeout)
        try context.check()
        let content: ExtractedContent
        do {
            content = try JSONDecoder().decode(ExtractedContent.self, from: output.data)
        } catch {
            throw ContentExtractionError.invalidDocument("helper 返回的内容不是有效提取结果")
        }
        guard content.text.utf8.count <= ExtractionLimits.textBytes else {
            throw ContentExtractionError.resourceLimit("helper 正文超过 8 MiB")
        }
        var remainingMetadata = metadataBytes
        for value in content.labels + [content.warning ?? ""] {
            let size = value.utf8.count
            guard size <= remainingMetadata else {
                throw ContentExtractionError.resourceLimit("helper 标签或警告超过体积限制")
            }
            remainingMetadata -= size
        }
        try context.check()
        return content
    }
}
