import Foundation

/// Synchronous, local extraction. Call from the scanner's serial background worker.
/// Never requests an iCloud/File Provider download; the scanner owns hydration policy.
public enum ContentExtractor {
    private static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"]
    private static let text: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "log", "json", "jsonl", "yaml", "yml", "xml", "tex",
        "swift", "py", "js", "ts", "jsx", "tsx", "css", "scss", "less", "c", "h", "cc", "cpp", "hpp",
        "m", "mm", "java", "kt", "kts", "go", "rs", "rb", "php", "sh", "zsh", "bash", "fish",
        "sql", "r", "jl", "lua", "pl", "dart", "vue", "svelte", "toml", "ini", "cfg", "conf", "ipynb"
    ]
    private static let documents: Set<String> = ["pdf", "docx", "pptx", "xlsx", "ppt", "xls", "html", "htm", "xhtml", "rtf", "rtfd", "doc", "epub", "pages", "numbers", "key", "keynote"]
    private static let iwork: Set<String> = ["pages", "numbers", "key", "keynote"]

    public static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return url.isFileURL && (images.contains(ext) || text.contains(ext) || documents.contains(ext))
    }

    public static func extract(url: URL, options: ExtractionOptions = ExtractionOptions(),
                               cancelled: @escaping () -> Bool = { false }) throws -> ExtractedContent {
        let context = ExtractionContext(cancelled: cancelled)
        try context.check()
        let ext = url.pathExtension.lowercased()
        guard supports(url) else { throw ContentExtractionError.unsupportedFormat(ext) }
        _ = try localFileSize(url, allowDirectory: iwork.contains(ext) || ext == "rtfd")
        if text.contains(ext) || ["html", "htm", "xhtml"].contains(ext) {
            let data = try boundedFileData(url, limit: ExtractionLimits.textBytes, context: context, truncate: true)
            let decoded = try decodeDocumentText(data, context: context, truncated: context.warnings.contains { $0.contains("截断") })
            context.append(["html", "htm", "xhtml"].contains(ext) ? HTMLTextExtractor.text(decoded) : decoded)
            try context.check()
            return context.result()
        }
        if images.contains(ext) {
            let data = try boundedFileData(url, limit: ExtractionLimits.inputBytes, context: context)
            let result = try extractImage(data, options: options, context: context)
            return context.result(labels: result.labels, pages: result.pages)
        }
        switch ext {
        case "pdf":
            let data = try boundedFileData(url, limit: ExtractionLimits.inputBytes, context: context)
            return context.result(pages: try extractPDF(data, options: options, context: context))
        case "docx", "pptx", "xlsx":
            let archive = try BoundedArchive(url: url, context: context)
            return context.result(pages: try extractOffice(archive, ext: ext, context: context))
        case "epub":
            let archive = try BoundedArchive(url: url, context: context)
            return context.result(pages: try extractEPUB(archive, context: context))
        case "ppt", "xls":
            let pages = try importCurrentDocument(url, format: ext.uppercased(), context: context)
            return context.result(pages: pages ?? 0)
        case "rtf", "rtfd", "doc":
            if ext == "rtfd" { try validateDocumentPackage(url, context: context) }
            let output = try runExtractionProcess("/usr/bin/textutil", arguments: ["-convert", "txt", "-stdout", "-encoding", "UTF-8", "-noload", "-nostore", "--", url.path],
                                                 limit: ExtractionLimits.textBytes, context: context, allowTruncation: true)
            if output.truncated { context.warn("系统文档转换输出超过 8 MiB，内容已截断") }
            context.append(try decodeDocumentText(output.data, context: context, truncated: output.truncated))
            return context.result()
        default:
            return try extractIWork(url, options: options, context: context)
        }
    }
}

private func validateDocumentPackage(_ url: URL, context: ExtractionContext) throws {
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, error in
        enumerationError = error; return false
    }) else {
        throw ContentExtractionError.invalidDocument("文档包无法遍历")
    }
    var entries = 0, bytes = 0
    for case let member as URL in enumerator {
        try context.check()
        entries += 1
        if entries > ExtractionLimits.archiveEntries { throw ContentExtractionError.resourceLimit("文档包条目超过 10000") }
        let size = try localFileSize(member, allowDirectory: true)
        guard size <= ExtractionLimits.memberBytes, bytes <= ExtractionLimits.inputBytes - size else {
            throw ContentExtractionError.resourceLimit("文档包体积超过限制")
        }
        bytes += size
    }
    if let enumerationError { throw enumerationError }
}

private func importCurrentDocument(_ url: URL, format: String, context: ExtractionContext) throws -> Int? {
    do {
        let imported = try SystemDocumentImporter.extract(url, context: context)
        guard !imported.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            context.warn("\(format) 系统即时导入未提供正文"); return nil
        }
        context.append(imported.text)
        return imported.pages
    } catch {
        try context.check() // Preserve cancellation and the extraction-wide deadline.
        context.warn("\(format) 系统即时导入失败：\(error.localizedDescription)")
        return nil
    }
}

private func readIWorkPreview(_ url: URL, archive: BoundedArchive?, paths: [String], context: ExtractionContext) throws -> Data? {
    for path in paths {
        try context.check()
        if let archive {
            if archive.contains(path) { return try archive.read(path) }
        } else {
            let preview = url.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: preview.path) {
                return try boundedFileData(preview, limit: ExtractionLimits.memberBytes, context: context)
            }
        }
    }
    return nil
}

private func extractIWork(_ url: URL, options: ExtractionOptions, context: ExtractionContext) throws -> ExtractedContent {
    let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    let archive: BoundedArchive?
    // Check packages/ZIP expansion before allowing the system importer to parse them.
    if directory { try validateDocumentPackage(url, context: context); archive = nil }
    else { archive = try BoundedArchive(url: url, context: context) }

    if let pages = try importCurrentDocument(url, format: "iWork", context: context) {
        return context.result(pages: pages)
    }
    var previewPages = 0
    do {
        if let data = try readIWorkPreview(url, archive: archive,
                                          paths: ["QuickLook/Preview.pdf", "QuickLook/preview.pdf", "Preview.pdf", "preview.pdf"], context: context) {
            context.warn("iWork 仅使用内嵌预览 PDF；预览未包含的正文无法提取")
            previewPages = try extractPDF(data, options: options, context: context)
            if context.textBytes > 0 { return context.result(pages: previewPages) }
        }
    } catch {
        try context.check()
        context.warn("iWork PDF 预览提取失败：\(error.localizedDescription)")
    }
    do {
        if let data = try readIWorkPreview(url, archive: archive,
                                          paths: ["QuickLook/preview.jpg", "QuickLook/Preview.jpg", "preview.jpg", "Preview.jpg"], context: context) {
            context.warn("iWork 仅提取 QuickLook 图片预览，无法代表完整正文")
            if options.recognizeImages {
                let previewOptions = ExtractionOptions(recognizeImages: true, classifyImages: false, ocrPDF: options.ocrPDF)
                _ = try extractImage(data, options: previewOptions, context: context)
            } else { context.warn("iWork 图片预览 OCR 已关闭") }
        }
    } catch {
        try context.check()
        context.warn("iWork 图片预览提取失败：\(error.localizedDescription)")
    }
    if context.textBytes == 0 { context.warn("iWork 没有可提取的即时导入正文或预览文字；IWA 正文未提取") }
    return context.result(pages: previewPages)
}
