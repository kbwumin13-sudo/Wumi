import Foundation
import Darwin

/// Advisory interprocess ownership shared by host and explicit migration.
/// Never unlink a lock file: replacing its inode would allow two owners.
public final class DatabaseLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(databaseURL: URL) throws {
        let path=databaseURL.standardizedFileURL.resolvingSymlinksInPath().path+".host.lock"
        try FileManager.default.createDirectory(atPath:(path as NSString).deletingLastPathComponent,withIntermediateDirectories:true)
        let fd=open(path,O_RDWR | O_CREAT | O_CLOEXEC,0o600)
        guard fd>=0 else {throw SearchDatabaseError(message:"无法创建索引占用锁")}
        guard flock(fd,LOCK_EX | LOCK_NB)==0 else {
            close(fd);throw SearchDatabaseError(message:"目标索引已被另一宿主或迁移进程占用")
        }
        descriptor=fd
    }
    deinit {flock(descriptor,LOCK_UN);close(descriptor)}
}
