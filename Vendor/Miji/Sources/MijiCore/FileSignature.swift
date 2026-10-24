import Foundation
import Darwin

/// Shared by scanning and extraction so both observe the same file version.
public struct FileSignature: Equatable {
    public var size: Int64
    public var modified: Double
    public var inode: Int64
    private static func metadata(_ url:URL) throws -> (signature:FileSignature,isDirectory:Bool,isRegular:Bool) {
        var info=stat()
        guard lstat(url.path,&info) == 0 else {
            let code=errno
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code),userInfo:[NSFilePathErrorKey:url.path])
        }
        // FileManager.attributesOfItem also reads extended attributes. Those
        // can wait on a provider or protected file and hold up the entire index.
        // Round through Date just as Foundation did, preserving stored signatures.
        let seconds=Double(info.st_mtimespec.tv_sec)-Date.timeIntervalBetween1970AndReferenceDate+Double(info.st_mtimespec.tv_nsec)/1_000_000_000
        let signature=FileSignature(size:info.st_size,modified:Date(timeIntervalSinceReferenceDate:seconds).timeIntervalSince1970,inode:Int64(bitPattern:UInt64(info.st_ino)))
        return (signature,info.st_mode & S_IFMT == S_IFDIR,info.st_mode & S_IFMT == S_IFREG)
    }
    public static func read(_ url: URL) throws -> FileSignature {
        try read(canonical:url.standardizedFileURL.resolvingSymlinksInPath())
    }
    /// For a URL that is already resolved, such as one enumerated below a canonical
    /// root without following symlinks. Saves a realpath walk per scanned file.
    static func read(canonical url: URL) throws -> FileSignature {
        let fm=FileManager.default
        let entry=try metadata(url)
        let signature=entry.signature
        guard entry.isDirectory,
              FileKind.classify(extension:url.pathExtension,isDirectory:true) == .document else {return signature}
        // Package mtime alone misses changes to existing children.
        var enumerationError:Error?
        guard let entries=fm.enumerator(at:url,includingPropertiesForKeys:nil,errorHandler:{_,error in enumerationError=error;return false}) else {throw CocoaError(.fileReadUnknown)}
        let children=(entries.allObjects as? [URL] ?? []).sorted{$0.path < $1.path}
        if let enumerationError {throw enumerationError}
        var hash:UInt64=14695981039346656037
        func add(_ text:String) {for byte in text.utf8 {hash=(hash ^ UInt64(byte)) &* 1099511628211};hash=hash &* 1099511628211}
        var total:Int64=0;var modified=signature.modified
        add(String(signature.inode));add(String(signature.modified.bitPattern))
        for child in children {
            let entry=try metadata(child)
            let size=entry.signature.size,date=entry.signature.modified
            add(String(child.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(url.path.count)));add(String(size));add(String(date.bitPattern));add(String(entry.signature.inode))
            if entry.isRegular {total += size}
            modified=max(modified,date)
        }
        return FileSignature(size:total,modified:modified,inode:Int64(bitPattern:hash))
    }
    public func matches(_ file:FileRecord) -> Bool {size==file.size && modified==file.modified && inode==file.inode}
}
