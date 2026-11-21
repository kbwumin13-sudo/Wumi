import CryptoKit
import Darwin
import Foundation

/// Bounded reuse of the raw extractor output, scoped to one running helper
/// configuration. Only path-independent image and PDF extraction uses it.
final class ExtractionReuse {
    struct Key: Hashable {
        let format: String
        let digest: SHA256.Digest
    }

    private let byteBudget = 4 * 1024 * 1024
    private var bytes = 0
    private var order: [Key] = []
    private var entries: [Key: Data] = [:]

    static func key(_ url: URL, file: FileRecord, cancelled: () -> Bool) -> Key? {
        guard file.kind == .image || file.fileExtension == "pdf",
              file.size <= 32 * 1024 * 1024 else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size == file.size else { return nil }

        var hasher = SHA256()
        var remaining = Int(file.size)
        do {
            while remaining > 0 {
                guard !cancelled(), let chunk = try handle.read(upToCount: min(remaining, 256 * 1024)),
                      !chunk.isEmpty else { return nil }
                hasher.update(data: chunk)
                remaining -= chunk.count
            }
        } catch { return nil }
        return Key(format: file.fileExtension, digest: hasher.finalize())
    }

    func get(_ key: Key) -> Data? { entries[key] }

    func save(_ raw: Data, for key: Key) {
        guard entries[key] == nil, raw.count <= byteBudget else { return }
        while order.count >= 32 || bytes + raw.count > byteBudget {
            if let old = entries.removeValue(forKey: order.removeFirst()) { bytes -= old.count }
        }
        entries[key] = raw
        order.append(key)
        bytes += raw.count
    }
}
