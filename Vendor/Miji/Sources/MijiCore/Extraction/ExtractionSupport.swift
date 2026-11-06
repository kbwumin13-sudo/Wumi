import Foundation
import Darwin

public enum ContentExtractionError: Error, LocalizedError, Equatable {
    case cancelled
    case unsupportedFormat(String)
    case unavailableLocally
    case invalidDocument(String)
    case resourceLimit(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "内容提取已取消"
        case .unsupportedFormat(let ext): return "不支持的内容格式：\(ext)"
        case .unavailableLocally: return "文件尚未下载到本机，已跳过内容读取"
        case .invalidDocument(let reason): return "无法提取文档：\(reason)"
        case .resourceLimit(let reason): return "内容提取超过安全限制：\(reason)"
        case .timedOut: return "内容提取超过 180 秒时间限制"
        }
    }
}

// Limits apply to the entire extraction, including all ZIP members and PDF pages.
// An over-limit binary is rejected; text that can safely be read in part gets a warning.
enum ExtractionLimits {
    static let inputBytes = 64 * 1024 * 1024
    static let textBytes = 8 * 1024 * 1024
    static let memberBytes = 32 * 1024 * 1024
    static let expandedBytes = 128 * 1024 * 1024
    static let archiveEntries = 10_000
}

final class ExtractionContext {
    let cancelled: () -> Bool
    let deadline = Date().addingTimeInterval(180)
    var warnings: [String] = []
    private var chunks: [String] = []
    private var pageRanges: [ContentPageRange]?
    private(set) var textBytes = 0
    var isFull: Bool { textBytes >= ExtractionLimits.textBytes }
    init(cancelled: @escaping () -> Bool) { self.cancelled = cancelled }

    func check() throws {
        if cancelled() { throw ContentExtractionError.cancelled }
        if Date() >= deadline { throw ContentExtractionError.timedOut }
    }

    func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    @discardableResult
    func append(_ text: String, separator: String = "\n") -> Range<Int>? {
        guard !text.isEmpty, !isFull else { return nil }
        let prefix = chunks.isEmpty ? "" : separator
        let start = textBytes + prefix.utf8.count
        let remaining = ExtractionLimits.textBytes - textBytes
        let combined = prefix + text
        if combined.utf8.count <= remaining {
            chunks.append(combined); textBytes += combined.utf8.count
            return start..<textBytes
        } else {
            // Decode only complete UTF-8 scalars, so the truncated index remains valid text.
            let bytes = Array(combined.utf8.prefix(remaining))
            var end = bytes.count
            while end > 0, String(bytes: bytes[..<end], encoding: .utf8) == nil { end -= 1 }
            if end > 0 { chunks.append(String(bytes: bytes[..<end], encoding: .utf8)! ) }
            textBytes = ExtractionLimits.textBytes
            warn("提取文字达到 8 MiB 上限，内容已截断")
            let bodyBytes = end - prefix.utf8.count
            return bodyBytes > 0 ? start..<(start + bodyBytes) : nil
        }
    }

    func beginPageMapping() { if pageRanges == nil { pageRanges = [] } }

    func appendPage(_ text: String, page: Int) {
        beginPageMapping()
        if let range = append(text, separator: "\n\n"), !range.isEmpty {
            pageRanges?.append(ContentPageRange(page: page, utf8Offset: range.lowerBound, utf8Length: range.count))
        }
    }

    func result(labels: [String] = [], pages: Int = 0) -> ExtractedContent {
        let text = chunks.joined()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && labels.isEmpty {
            warn("未找到可提取的文字或图片类别")
        }
        return ExtractedContent(text: text, labels: labels, pages: pages,
                                warning: warnings.isEmpty ? nil : warnings.joined(separator: "；"), pageRanges: pageRanges)
    }
}

func localFileSize(_ url: URL, allowDirectory: Bool = false) throws -> Int {
    guard url.isFileURL else { throw ContentExtractionError.invalidDocument("仅支持本地文件 URL") }
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
    // File Provider placeholders can be dataless even outside iCloud Drive.
    if info.st_flags & UInt32(SF_DATALESS) != 0 { throw ContentExtractionError.unavailableLocally }
    let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded {
        throw ContentExtractionError.unavailableLocally
    }
    if info.st_mode & S_IFMT == S_IFLNK {
        throw ContentExtractionError.invalidDocument("不读取符号链接")
    }
    guard info.st_mode & S_IFMT == S_IFREG || (allowDirectory && info.st_mode & S_IFMT == S_IFDIR) else {
        throw ContentExtractionError.invalidDocument("不是常规文件或受支持的文档包")
    }
    guard info.st_size <= Int64(ExtractionLimits.inputBytes) else {
        throw ContentExtractionError.resourceLimit("输入文件大于 64 MiB")
    }
    return Int(info.st_size)
}

func boundedFileData(_ url: URL, limit: Int, context: ExtractionContext, truncate: Bool = false) throws -> Data {
    try context.check()
    let size = try localFileSize(url)
    if size > limit && !truncate { throw ContentExtractionError.resourceLimit("输入内容大于 \(limit) 字节") }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var data = Data()
    // Chunking lets cancellation interrupt large local reads and also limits a growing file.
    while data.count < limit {
        try context.check()
        let chunk = try file.read(upToCount: min(64 * 1024, limit - data.count)) ?? Data()
        if chunk.isEmpty { return data }
        data.append(chunk)
    }
    if !(try file.read(upToCount: 1) ?? Data()).isEmpty {
        if truncate { context.warn("输入文字超过读取上限，内容已截断") }
        else { throw ContentExtractionError.resourceLimit("文件在读取时超过体积限制") }
    }
    return data
}

struct ProcessOutput {
    let data: Data
    let truncated: Bool
    let diagnostics: String
    init(data: Data, truncated: Bool, diagnostics: String = "") {
        self.data = data; self.truncated = truncated; self.diagnostics = diagnostics
    }
}

private func checkProcessOutputFile(_ url: URL, limit: Int) throws {
    var info = stat()
    if lstat(url.path, &info) != 0 {
        if errno == ENOENT { return }
        throw ContentExtractionError.invalidDocument("无法检查系统导入临时输出")
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw ContentExtractionError.invalidDocument("系统导入输出不是常规文件") }
    guard info.st_size <= Int64(limit) else { throw ContentExtractionError.resourceLimit("系统导入 plist 输出超过体积限制") }
}

/// Foundation.Process normally creates a new process group on macOS. Nested Foundation helpers
/// can create further groups, so group signalling alone does not contain their descendants.
func stopExtractionProcess(_ process: Process, ownedGroup: pid_t?) {
    let root = process.processIdentifier
    let host = getpid(), hostGroup = getpgrp()
    func children(of parent: pid_t) -> [pid_t] {
        // Unlike proc_listpids, proc_listchildpids returns a PID count, not a byte count.
        let estimate = proc_listchildpids(parent, nil, 0)
        guard estimate > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(estimate) + 16)
        let written = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return [] }
        return Array(children.prefix(Int(written))).filter { $0 > 1 && $0 != host && $0 != root }
    }
    var descendants: [pid_t] = []
    if process.isRunning {
        // Freeze each parent before enumerating its children so it cannot spawn replacements during cleanup.
        kill(root, SIGSTOP)
        var pending = children(of: root)
        var visited = Set<pid_t>()
        while let child = pending.popLast() {
            guard visited.insert(child).inserted else { continue }
            kill(child, SIGSTOP)
            descendants.append(child)
            pending.append(contentsOf: children(of: child))
        }
    }
    for child in descendants.reversed() { kill(child, SIGKILL) }
    if let group = ownedGroup, group > 1, group == root, group != hostGroup, group != host {
        kill(-group, SIGKILL)
    }
    if process.isRunning { kill(root, SIGKILL) }
    process.waitUntilExit()
}

// No shell, no extraction to disk, bounded stdout/stderr, and cancellation during execution.
func runExtractionProcess(_ executable: String, arguments: [String], limit: Int,
                          context: ExtractionContext, allowTruncation: Bool = false,
                          timeout: TimeInterval? = nil, outputFile: URL? = nil,
                          outputFileLimit: Int = ExtractionLimits.inputBytes) throws -> ProcessOutput {
    try context.check()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout; process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    // Extraction is background indexing work, like the queue that waits for it.
    process.qualityOfService = .background
    try process.run()
    let group = getpgid(process.processIdentifier)
    let ownedGroup: pid_t? = group == process.processIdentifier && group > 1 && group != getpgrp() ? group : nil
    try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
    let outFD = stdout.fileHandleForReading.fileDescriptor
    let errFD = stderr.fileHandleForReading.fileDescriptor
    defer {
        stopExtractionProcess(process, ownedGroup: ownedGroup)
        try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
    }
    guard fcntl(outFD, F_SETFL, O_NONBLOCK) != -1, fcntl(errFD, F_SETFL, O_NONBLOCK) != -1 else {
        throw ContentExtractionError.invalidDocument("无法设置系统转换进程的非阻塞输出")
    }
    var output = Data(), errors = Data(), outEOF = false, errEOF = false
    let processDeadline = timeout.map { Date().addingTimeInterval($0) }
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    while process.isRunning || !outEOF || !errEOF {
        try context.check()
        if let processDeadline, Date() >= processDeadline {
            throw ContentExtractionError.invalidDocument("系统提取进程超过 \(Int(timeout ?? 0)) 秒限制")
        }
        if let outputFile { try checkProcessOutputFile(outputFile, limit: outputFileLimit) }
        for fd in [outFD, errFD] {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                if fd == outFD {
                    if count > limit - output.count {
                        if !allowTruncation { throw ContentExtractionError.resourceLimit("解压或系统转换输出超过限制") }
                        output.append(contentsOf: buffer.prefix(max(0, limit - output.count)))
                        return ProcessOutput(data: output, truncated: true)
                    }
                    output.append(contentsOf: buffer.prefix(count))
                } else if errors.count < 4096 {
                    errors.append(contentsOf: buffer.prefix(min(count, 4096 - errors.count)))
                }
            } else if count == 0 {
                if fd == outFD { outEOF = true } else { errEOF = true }
            } else if errno != EAGAIN && errno != EINTR {
                throw ContentExtractionError.invalidDocument("读取系统转换进程输出失败")
            }
        }
        if process.isRunning || !outEOF || !errEOF { usleep(10_000) }
    }
    process.waitUntilExit()
    try context.check()
    if let outputFile { try checkProcessOutputFile(outputFile, limit: outputFileLimit) }
    guard process.terminationStatus == 0 else {
        let message = String(data: errors, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "系统转换失败"
        throw ContentExtractionError.invalidDocument(String(message.prefix(1000)))
    }
    return ProcessOutput(data: output, truncated: false, diagnostics: String(data: errors, encoding: .utf8) ?? "")
}
