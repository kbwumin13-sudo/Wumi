import Foundation
import CryptoKit
import OilFindCore
import Darwin

/// A disposable cache of name metadata. Bodies remain solely in SQLite.
/// The database identity prevents reuse after replacement; its bounded change
/// journal supplies commits made after this snapshot was saved.
///
/// Version 3 stores every column as an aligned section, so a snapshot is used
/// straight from a private file mapping instead of being copied into memory.
/// Version 2 caches are still read once and replaced by the owner.
enum NameSnapshotCache {
    // Older caches omit contextual pinyin aliases; rebuild the disposable name
    // snapshot once rather than silently returning incomplete name candidates.
    private static let legacyMagic=Data("MJNAME02".utf8)
    private static let magic=Data("MJNAME03".utf8)
    private struct Header:Codable {
        let inode:UInt64, device:UInt64, created:Double
        let revision:Int64, baseCount:Int, liveCount:Int
        let roots:[String:UInt32], extensions:[String:UInt32], kinds:[String:UInt32]
    }
    private struct MappedHeader:Codable {
        let inode:UInt64, device:UInt64, created:Double
        let revision:Int64, baseCount:Int, liveCount:Int, rows:Int, uniqueCount:Int
        let roots:[String:UInt32], extensions:[String:UInt32], kinds:[String:UInt32]
        let sections:[String:[Int]]
    }
    static func url(for database:URL)->URL {database.appendingPathExtension("names.cache")}
    private static func identity(_ url:URL)throws->(UInt64,UInt64,Double) {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard let inode=attributes[.systemFileNumber] as? NSNumber,
              let device=attributes[.systemNumber] as? NSNumber,
              let created=attributes[.creationDate] as? Date else {throw InvalidCache()}
        return (inode.uint64Value,device.uint64Value,created.timeIntervalSince1970)
    }
    static func load(database:URL,revision:Int64)throws->NameSnapshot {
        let cache=url(for:database)
        let handle=try FileHandle(forReadingFrom:cache)
        let prefix=try handle.read(upToCount:magic.count) ?? Data()
        try? handle.close()
        if prefix == magic { return try loadMapped(database:database,revision:revision) }
        guard prefix == legacyMagic else {throw InvalidCache()}
        return try loadLegacy(database:database,revision:revision)
    }

    private static func loadMapped(database:URL,revision:Int64)throws->NameSnapshot {
        let file=try MappedFile(url:url(for:database))
        let trailer=try CacheFileWriter.footer(of:file,magic:magic)
        let header=try JSONDecoder().decode(MappedHeader.self,from:trailer.footer)
        let id=try identity(database)
        guard header.inode==id.0,header.device==id.1,header.created==id.2,
              header.revision<=revision,revision-header.revision<=100_000,
              header.rows>=0,header.rows<Int(UInt32.max),header.uniqueCount>=0,header.uniqueCount<=header.rows else {throw InvalidCache()}
        let sections=try MappedSections(file:file,table:header.sections,limit:trailer.limit)
        let rows=header.rows
        let snapshot=NameSnapshot()
        snapshot.ids=SegmentedArray(mapped:try sections.buffer("ids",as:Int64.self,count:rows),owner:file)
        snapshot.sizes=SegmentedArray(mapped:try sections.buffer("sizes",as:Int64.self,count:rows),owner:file)
        snapshot.modified=SegmentedArray(mapped:try sections.buffer("modified",as:Double.self,count:rows),owner:file)
        snapshot.roots=SegmentedArray(mapped:try sections.buffer("roots",as:UInt32.self,count:rows),owner:file)
        snapshot.extensions=SegmentedArray(mapped:try sections.buffer("extensions",as:UInt32.self,count:rows),owner:file)
        snapshot.kinds=SegmentedArray(mapped:try sections.buffer("kinds",as:UInt32.self,count:rows),owner:file)
        snapshot.live=SegmentedArray(mapped:try sections.buffer("live",as:UInt8.self,count:rows),owner:file)
        snapshot.core=try DeduplicatedNameIndex(mapped:sections,prefix:"names.",rows:rows,uniqueCount:header.uniqueCount)
        snapshot.mapping=file
        try finish(snapshot,baseCount:header.baseCount,liveCount:header.liveCount,revision:header.revision,
                   roots:header.roots,extensions:header.extensions,kinds:header.kinds)
        return snapshot
    }

    /// Shared checks and indexes for both versions. Every column has one entry per row.
    private static func finish(_ snapshot:NameSnapshot,baseCount:Int,liveCount:Int,revision:Int64,
                               roots:[String:UInt32],extensions:[String:UInt32],kinds:[String:UInt32])throws {
        let count=snapshot.ids.count
        var live=0
        guard count<=Int(UInt32.max),snapshot.core.count==count,
              snapshot.sizes.count==count,snapshot.modified.count==count,snapshot.roots.count==count,
              snapshot.extensions.count==count,snapshot.kinds.count==count,snapshot.live.count==count,
              baseCount>=0,baseCount<=count,
              snapshot.live.allSatisfy({ live+=Int($0);return $0<=1 }),live==liveCount,
              valid(roots),valid(extensions),valid(kinds),
              snapshot.roots.allSatisfy({$0<UInt32(roots.count)}),
              snapshot.extensions.allSatisfy({$0<UInt32(extensions.count)}),
              snapshot.kinds.allSatisfy({$0<UInt32(kinds.count)}) else {throw InvalidCache()}
        if baseCount>1 {
            for i in 1..<baseCount where snapshot.ids[i-1]>=snapshot.ids[i] {throw InvalidCache()}
        }
        snapshot.rootKeys=roots;snapshot.extensionKeys=extensions;snapshot.kindKeys=kinds
        snapshot.baseCount=baseCount;snapshot.liveCount=liveCount;snapshot.changeRevision=revision
        for i in baseCount..<count {snapshot.changedIDs[snapshot.ids[i]]=UInt32(i)}
    }

    private static func loadLegacy(database:URL,revision:Int64)throws->NameSnapshot {
        let handle=try FileHandle(forReadingFrom:url(for:database))
        defer {try? handle.close()}
        let length=try handle.seekToEnd()
        guard length>UInt64(legacyMagic.count+40),length<=UInt64(Int.max) else {throw InvalidCache()}
        let payloadEnd=Int(length)-32
        try handle.seek(toOffset:0)
        guard try read(handle,count:legacyMagic.count)==legacyMagic else {throw InvalidCache()}
        try handle.seek(toOffset:0)
        var digest=SHA256(),remaining=payloadEnd
        while remaining>0 {
            let count=min(1_048_576,remaining)
            try autoreleasepool {digest.update(data:try read(handle,count:count))}
            remaining-=count
        }
        guard try Data(digest.finalize())==read(handle,count:32) else {throw InvalidCache()}
        try handle.seek(toOffset:UInt64(legacyMagic.count))
        var decoder=Decoder(handle:handle,end:payloadEnd,offset:legacyMagic.count)
        let header=try JSONDecoder().decode(Header.self,from:decoder.block())
        let id=try identity(database)
        guard header.inode==id.0,header.device==id.1,header.created==id.2,
              header.revision<=revision,revision-header.revision<=100_000 else {throw InvalidCache()}
        let snapshot=NameSnapshot()
        snapshot.ids=SegmentedArray(try decoder.array(Int64.self))
        snapshot.sizes=SegmentedArray(try decoder.array(Int64.self))
        snapshot.modified=SegmentedArray(try decoder.array(Double.self))
        snapshot.roots=SegmentedArray(try decoder.array(UInt32.self))
        snapshot.extensions=SegmentedArray(try decoder.array(UInt32.self))
        snapshot.kinds=SegmentedArray(try decoder.array(UInt32.self))
        snapshot.live=SegmentedArray(try decoder.array(UInt8.self))
        snapshot.core=try autoreleasepool {try DeduplicatedNameIndex(serialized:decoder.block())}
        guard decoder.offset==payloadEnd else {throw InvalidCache()}
        try finish(snapshot,baseCount:header.baseCount,liveCount:header.liveCount,revision:header.revision,
                   roots:header.roots,extensions:header.extensions,kinds:header.kinds)
        return snapshot
    }

    /// Writes version 3 to a private temporary file and renames it into place, so a
    /// mapping of the previous cache keeps its own, unchanged file.
    static func save(_ snapshot:NameSnapshot,database:URL)throws {
        guard let revision=snapshot.changeRevision else {return}
        let id=try identity(database)
        let destination=url(for:database)
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0o600)
        guard descriptor>=0 else {throw InvalidCache()}
        var closed=false
        defer {
            if !closed {close(descriptor)}
            try? FileManager.default.removeItem(at:temporary)
        }
        let writer=try CacheFileWriter(descriptor:descriptor,magic:magic)
        try writer.section("ids") {try snapshot.ids.write(to:writer)}
        try writer.section("sizes") {try snapshot.sizes.write(to:writer)}
        try writer.section("modified") {try snapshot.modified.write(to:writer)}
        try writer.section("roots") {try snapshot.roots.write(to:writer)}
        try writer.section("extensions") {try snapshot.extensions.write(to:writer)}
        try writer.section("kinds") {try snapshot.kinds.write(to:writer)}
        try writer.section("live") {try snapshot.live.write(to:writer)}
        try snapshot.core.write(to:writer,prefix:"names.")
        let header=MappedHeader(inode:id.0,device:id.1,created:id.2,revision:revision,baseCount:snapshot.baseCount,
                                liveCount:snapshot.liveCount,rows:snapshot.ids.count,uniqueCount:snapshot.core.uniqueCount,
                                roots:snapshot.rootKeys,extensions:snapshot.extensionKeys,kinds:snapshot.kindKeys,
                                sections:writer.sections)
        try writer.finish(footer:JSONEncoder().encode(header))
        closed=true
        guard close(descriptor)==0 else {throw CocoaError(.fileWriteUnknown)}
        guard rename(temporary.path,destination.path)==0 else {throw CocoaError(.fileWriteUnknown)}
    }
    private static func valid(_ map:[String:UInt32])->Bool {
        Set(map.values)==Set((0..<map.count).map {UInt32($0)})
    }
    private struct InvalidCache:Error {}
    private static func read(_ handle:FileHandle,count:Int)throws->Data {
        guard count>0 else {return Data()}
        var data=try handle.read(upToCount:count) ?? Data()
        while data.count<count {
            guard let next=try handle.read(upToCount:count-data.count),!next.isEmpty else {throw InvalidCache()}
            data.append(next)
        }
        return data
    }
    private struct Decoder {
        let handle:FileHandle,end:Int
        var offset:Int
        mutating func block()throws->Data {
            guard offset<=end-8 else {throw InvalidCache()}
            let length=try read(handle,count:8).withUnsafeBytes {$0.loadUnaligned(as:UInt64.self).littleEndian}
            offset+=8
            guard length<=UInt64(end-offset) else {throw InvalidCache()}
            offset+=Int(length)
            return try read(handle,count:Int(length))
        }
        mutating func array<T>(_ type:T.Type)throws->[T] {
            // Only the primitive numeric columns above use this decoder. Read
            // into their final storage instead of retaining a full Data copy.
            guard offset<=end-8 else {throw InvalidCache()}
            let length=try read(handle,count:8).withUnsafeBytes {$0.loadUnaligned(as:UInt64.self).littleEndian}
            offset+=8
            let stride=MemoryLayout<T>.stride
            guard length<=UInt64(end-offset),length%UInt64(stride)==0 else {throw InvalidCache()}
            let bytes=Int(length),count=bytes/stride
            let result=try [T](unsafeUninitializedCapacity:count) {buffer,initialized in
                let destination=UnsafeMutableRawBufferPointer(buffer)
                var received=0
                while received<bytes {
                    let size=Darwin.read(handle.fileDescriptor,destination.baseAddress!.advanced(by:received),min(1_048_576,bytes-received))
                    if size<0 && errno==EINTR {continue}
                    guard size>0 else {throw InvalidCache()}
                    received+=size
                }
                initialized=count
            }
            offset+=bytes
            return result
        }
    }
}
