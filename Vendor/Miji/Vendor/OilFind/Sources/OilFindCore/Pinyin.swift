import Foundation
import CoreFoundation

public final class Pinyin {
    public static let shared = Pinyin()
    private let offsets: [UInt32]
    private let bytes: [UInt8]
    private init() {
        let chars = (0x4e00...0x9fff).compactMap(UnicodeScalar.init).map(String.init)
        let joined = NSMutableString(string: chars.joined(separator: "\n"))
        CFStringTransform(joined, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(joined, nil, kCFStringTransformStripDiacritics, false)
        var parts = (joined as String).components(separatedBy: "\n")
        if parts.count != chars.count {
            parts = chars.map { c in
                let m = NSMutableString(string: c)
                CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
                CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
                return m as String
            }
        }
        var o: [UInt32] = [0], b: [UInt8] = []
        for p in parts {
            let clean = p.lowercased().utf8.filter { $0 >= 97 && $0 <= 122 }
            b.append(contentsOf: clean); o.append(UInt32(b.count))
        }
        offsets = o; bytes = b
    }
    // Miji adapter: optionally abbreviate Latin words in mixed Han/Latin names.
    public func keys(for name: UnsafeBufferPointer<UInt8>, full: inout [UInt8], initials: inout [UInt8], wordInitials: Bool = false) -> Bool {
        full.removeAll(keepingCapacity: true); initials.removeAll(keepingCapacity: true)
        var hasHan = false, i = 0, wordStart = true
        while i < name.count {
            let b = name[i]
            if b < 128 {
                let x = b >= 65 && b <= 90 ? b + 32 : b
                full.append(x)
                if wordInitials {
                    let word = (x >= 97 && x <= 122) || (x >= 48 && x <= 57)
                    if word && wordStart { initials.append(x) }
                    wordStart = !word
                } else { initials.append(x) }
                i += 1; continue
            }
            let width = b < 0xe0 ? 2 : b < 0xf0 ? 3 : 4
            guard i + width <= name.count else { break }
            let scalar: UInt32
            if width == 3 { scalar = (UInt32(b & 15) << 12) | (UInt32(name[i+1] & 63) << 6) | UInt32(name[i+2] & 63) }
            else { scalar = 0 }
            if scalar >= 0x4e00 && scalar <= 0x9fff {
                hasHan = true; let k = Int(scalar - 0x4e00), a = Int(offsets[k]), z = Int(offsets[k+1])
                if a < z { full.append(contentsOf: bytes[a..<z]); initials.append(bytes[a]) }
            } else {
                for j in i..<(i+width) { full.append(name[j]); initials.append(name[j]) }
            }
            wordStart = true
            i += width
        }
        return hasHan
    }
}
