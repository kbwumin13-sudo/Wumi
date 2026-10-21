import CryptoKit
import Foundation

public enum ChecksumAlgorithm: String, CaseIterable, Sendable {
    case sha256, sha384, sha512, md5, sha1
}

/// Streams a regular file through CryptoKit and returns a lowercase hex digest.
public struct ChecksumService: Sendable {
    public let chunkSize: Int

    public init(chunkSize: Int = 1 << 20) {
        self.chunkSize = max(chunkSize, 4096)
    }

    public enum ChecksumError: Error {
        case notRegularFile, unreadable
    }

    public func checksum(of url: URL, algorithm: ChecksumAlgorithm, isCancelled: () -> Bool = { false }) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ChecksumError.notRegularFile }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ChecksumError.unreadable }
        defer { try? handle.close() }
        func run<H: HashFunction>(_ hasher: inout H) throws -> String {
            while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
                if isCancelled() { throw CancellationError() }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch algorithm {
        case .sha256: var h = SHA256(); return try run(&h)
        case .sha384: var h = SHA384(); return try run(&h)
        case .sha512: var h = SHA512(); return try run(&h)
        case .md5: var h = Insecure.MD5(); return try run(&h)
        case .sha1: var h = Insecure.SHA1(); return try run(&h)
        }
    }
}
