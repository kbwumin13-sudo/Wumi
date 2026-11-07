import Foundation
import Compression
import CryptoKit

public enum ContentCodecError: Error, Equatable {
    case invalidData
    case resourceLimit
    case compressionFailed
}

/// Stable v1 envelope: MJC1, codec (0 = raw, 1 = LZFSE), three zero bytes,
/// little-endian UInt64 original length, SHA256 of payload bytes, payload.
/// Integrity is checked for both codecs, before the content reaches JSONDecoder.
public enum ContentCodec {
    public static let maximumRawBytes = 128 * 1024 * 1024
    private static let headerBytes = 48
    private static let magic: [UInt8] = [0x4d, 0x4a, 0x43, 0x31]

    public static func digest(_ raw: Data) -> Data { Data(SHA256.hash(data: raw)) }

    public static func pack(_ raw: Data) throws -> Data {
        guard raw.count <= maximumRawBytes else { throw ContentCodecError.resourceLimit }
        var codec: UInt8 = 0
        var payload = raw
        if !raw.isEmpty {
            // A full-size destination is enough: only a strictly smaller result is useful.
            var compressed = Data(count: raw.count)
            let capacity = compressed.count
            let size = compressed.withUnsafeMutableBytes { destination in
                raw.withUnsafeBytes { source in
                    compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                              nil, COMPRESSION_LZFSE)
                }
            }
            if size > 0 && size < raw.count {
                compressed.count = size
                payload = compressed
                codec = 1
            }
        }
        var result = Data(magic)
        result.append(contentsOf: [codec, 0, 0, 0])
        let length = UInt64(raw.count)
        for byte in 0..<8 { result.append(UInt8(truncatingIfNeeded: length >> (byte * 8))) }
        result.append(digest(payload))
        result.append(payload)
        return result
    }

    public static func unpack(_ packed: Data) throws -> Data {
        guard packed.count >= headerBytes else { throw ContentCodecError.invalidData }
        // Data slices need not have zero-based indices.
        let header = Array(packed.prefix(headerBytes))
        guard Array(header[0..<4]) == magic, header[5..<8].allSatisfy({ $0 == 0 }),
              header[4] <= 1 else { throw ContentCodecError.invalidData }
        var length: UInt64 = 0
        for byte in 0..<8 { length |= UInt64(header[8 + byte]) << (byte * 8) }
        guard length <= UInt64(maximumRawBytes) else { throw ContentCodecError.resourceLimit }
        let size = Int(length)
        let payloadSize = packed.count - headerBytes
        guard header[4] == 0 ? payloadSize == size : (size > 0 && payloadSize > 0 && payloadSize < size)
        else { throw ContentCodecError.invalidData }
        let payload = Data(packed.dropFirst(headerBytes))
        guard digest(payload) == Data(header[16..<48]) else { throw ContentCodecError.invalidData }
        let raw: Data
        if header[4] == 0 {
            guard payload.count == size else { throw ContentCodecError.invalidData }
            raw = payload
        } else {
            guard size > 0, !payload.isEmpty, payload.count < size else { throw ContentCodecError.invalidData }
            // The spare byte detects streams that exceed the advertised original length.
            var decoded = Data(count: size + 1)
            try decoded.withUnsafeMutableBytes { destination in
                try payload.withUnsafeBytes { source in
                    var stream = compression_stream(dst_ptr: destination.bindMemory(to: UInt8.self).baseAddress!, dst_size: 0,
                                                    src_ptr: source.bindMemory(to: UInt8.self).baseAddress!, src_size: 0, state: nil)
                    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR
                    else { throw ContentCodecError.compressionFailed }
                    defer { compression_stream_destroy(&stream) }
                    stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = size + 1
                    stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                    stream.src_size = payload.count
                    while true {
                        let previousInput = stream.src_size, previousOutput = stream.dst_size
                        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        if status == COMPRESSION_STATUS_END {
                            guard stream.src_size == 0, stream.dst_size == 1 else { throw ContentCodecError.invalidData }
                            break
                        }
                        guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                              stream.src_size < previousInput || stream.dst_size < previousOutput
                        else { throw ContentCodecError.invalidData }
                    }
                }
            }
            decoded.count = size
            raw = decoded
        }
        return raw
    }

    public static func searchableText(_ packed: Data) throws -> String {
        let content = try JSONDecoder().decode(ExtractedContent.self, from: unpack(packed))
        return QueryParser.normalize(content.text + "\n" + content.labels.joined(separator: "\n"))
    }

    /// Candidate-only intersection; the caller must verify the exact normalized substring.
    /// Input has already been normalized using QueryParser.normalize.
    public static func matchExpression(_ normalizedTerm: String) -> String? {
        let scalars = Array(normalizedTerm.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        let width = min(3, scalars.count)
        let starts = scalars.count - width + 1
        let samples = min(16, starts)
        var tokens: [String] = []
        var seen = Set<String>()
        let hex = Array("0123456789abcdef".utf8)
        for sample in 0..<samples {
            let start = samples == 1 ? 0 : sample * (starts - 1) / (samples - 1)
            var gram = String.UnicodeScalarView()
            for index in start..<(start + width) { gram.append(scalars[index]) }
            var encoded: [UInt8] = [0x67]
            for byte in String(gram).utf8 { encoded.append(hex[Int(byte >> 4)]); encoded.append(hex[Int(byte & 15)]) }
            let token = String(decoding: encoded, as: UTF8.self)
            if seen.insert(token).inserted { tokens.append("\"" + token + "\"") }
        }
        return tokens.joined(separator: " AND ")
    }
}
