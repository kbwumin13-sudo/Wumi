import Darwin
import Foundation

public struct DirectorySizeMeasurement: Equatable, Sendable {
    public let bytes: Int64
    public let isComplete: Bool

    public init(bytes: Int64, isComplete: Bool) {
        self.bytes = bytes
        self.isComplete = isComplete
    }
}

/// Logical sizes of non-directory entries, including hidden files and package contents.
/// Hard links count once per directory entry; directory metadata does not contribute.
/// Only metadata and directory streams are read, never file contents or cloud downloads.
public enum DirectorySizeCalculator {
    /// Runs synchronously on the caller's thread. Progress is a partial lower bound,
    /// followed by the final result; callbacks have no MainActor guarantee.
    /// Cancellation, filesystem errors and Int64 overflow make the result incomplete.
    public static func measure(
        _ url: URL,
        isCancelled: () -> Bool = { false },
        progress: (DirectorySizeMeasurement) -> Void = { _ in }
    ) -> DirectorySizeMeasurement {
        var bytes: Int64 = 0
        var complete = true
        func finish() -> DirectorySizeMeasurement {
            let result = DirectorySizeMeasurement(bytes: bytes, isComplete: complete)
            progress(result)
            return result
        }
        func add(_ size: Int64) {
            guard size >= 0 else { complete = false; return }
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            bytes = overflow ? Int64.max : sum
            if overflow { complete = false }
        }

        guard url.isFileURL, !isCancelled() else {
            complete = false
            return finish()
        }
        // A trailing slash would make lstat follow a directory symlink.
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var rootInfo = stat()
        guard lstat(path, &rootInfo) == 0 else {
            complete = false
            return finish()
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
            add(Int64(rootInfo.st_size))
            if isCancelled() { complete = false }
            return finish()
        }

        // O_NOFOLLOW also closes the lstat/open race if an entry becomes a symlink.
        func openDirectory(_ parent: Int32, _ name: UnsafePointer<CChar>, expected: stat) -> UnsafeMutablePointer<DIR>? {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var actual = stat()
            guard fstat(fd, &actual) == 0,
                  actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
                  let stream = fdopendir(fd) else {
                close(fd)
                return nil
            }
            return stream
        }
        guard let root = path.withCString({ openDirectory(AT_FDCWD, $0, expected: rootInfo) }) else {
            complete = false
            return finish()
        }
        // Depth-first streams use O(depth) memory/descriptors, independent of entry count.
        // Descriptor exhaustion is reported as incomplete, never as a successful truncation.
        var stack = [root]
        defer { for stream in stack { closedir(stream) } }
        var lastProgress = DispatchTime.now().uptimeNanoseconds
        while let stream = stack.last {
            if isCancelled() { complete = false; break }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastProgress >= 500_000_000 {
                progress(.init(bytes: bytes, isComplete: false))
                lastProgress = now
                if isCancelled() { complete = false; break }
            }
            errno = 0
            guard let entry = readdir(stream) else {
                let error = errno
                if error == EINTR { continue }
                if error != 0 { complete = false }
                closedir(stream)
                stack.removeLast()
                continue
            }
            var nameBuffer = entry.pointee.d_name
            withUnsafeBytes(of: &nameBuffer) { raw in
                let name = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                if name[0] == 46 && (name[1] == 0 || (name[1] == 46 && name[2] == 0)) { return }
                var info = stat()
                guard fstatat(dirfd(stream), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    complete = false
                    return
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    if let child = openDirectory(dirfd(stream), name, expected: info) {
                        stack.append(child)
                    } else {
                        complete = false
                    }
                } else {
                    add(Int64(info.st_size))
                }
            }
        }
        if isCancelled() { complete = false }
        return finish()
    }
}
