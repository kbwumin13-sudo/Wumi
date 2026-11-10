import Foundation

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case document, image, folder, application, code, audio, video, archive, other
    public var title: String {
        switch self { case .document: return "文档"; case .image: return "图片"; case .folder: return "文件夹"; case .application:return "应用";case .code:return "代码";case .audio: return "音频"; case .video: return "视频"; case .archive: return "压缩包"; case .other: return "其他" }
    }
    public static func classify(extension ext: String, isDirectory: Bool = false) -> FileKind {
        let ext = ext.lowercased()
        if ext == "app",isDirectory {return .application}
        if isDirectory {return ["pages","numbers","key","keynote","rtfd"].contains(ext) ? .document : .folder}
        if ["json","jsonl","xml","yaml","yml","tex","swift","py","js","ts","jsx","tsx","css","scss","less","c","h","cc","cpp","hpp","m","mm","java","kt","kts","go","rs","rb","php","sh","zsh","bash","fish","sql","r","jl","lua","pl","dart","vue","svelte","toml","ini","cfg","conf","ipynb"].contains(ext) {return .code}
        if ["pdf","doc","docx","ppt","pptx","xls","xlsx","pages","numbers","key","keynote","txt","md","markdown","csv","tsv","rtf","rtfd","html","htm","xhtml","epub","json","jsonl","xml","yaml","yml","tex","swift","py","js","ts","jsx","tsx","css","scss","less","c","h","cc","cpp","hpp","m","mm","java","kt","kts","go","rs","rb","php","sh","zsh","bash","fish","sql","r","jl","lua","pl","dart","vue","svelte","toml","ini","cfg","conf","ipynb","log"].contains(ext) { return .document }
        if isDirectory { return .folder }
        if ["png","jpg","jpeg","heic","heif","tiff","tif","bmp","gif","webp"].contains(ext) { return .image }
        if ["mp3","wav","flac","m4a","aac","aiff","ogg"].contains(ext) { return .audio }
        if ["mp4","mov","mkv","avi","webm","m4v"].contains(ext) { return .video }
        if ["zip","rar","7z","tar","gz","dmg","iso"].contains(ext) { return .archive }
        return .other
    }
}

public struct IndexedRoot: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var name: String
    public var volumeUUID: String?
    public var volumeRelativePath: String
    public var isExternal: Bool
    public var isOnline: Bool
    public var enabled: Bool
    public var lastScan: Date?
    public var lastError: String?
    public init(id: String = UUID().uuidString, path: String, name: String? = nil, volumeUUID: String? = nil, volumeRelativePath: String = "", isExternal: Bool = false, isOnline: Bool = true, enabled: Bool = true, lastScan: Date? = nil, lastError: String? = nil) {
        self.id=id; self.path=path; self.name=name ?? URL(fileURLWithPath: path).lastPathComponent; self.volumeUUID=volumeUUID; self.volumeRelativePath=volumeRelativePath; self.isExternal=isExternal; self.isOnline=isOnline; self.enabled=enabled; self.lastScan=lastScan; self.lastError=lastError
    }
}

public struct FileRecord: Codable, Identifiable, Sendable {
    public var id: Int64
    public var rootID: String
    public var relativePath: String
    public var name: String
    public var fileExtension: String
    public var kind: FileKind
    public var size: Int64
    public var modified: Double
    public var inode: Int64
    public var created: Double?
    public var isDirectory: Bool?
    public var isPackage: Bool?
    public var contentState: String
    public var contentError: String?
    public init(id: Int64 = 0, rootID: String, relativePath: String, name: String, fileExtension: String, kind: FileKind, size: Int64, modified: Double, inode: Int64 = 0, contentState: String = "pending", contentError: String? = nil, created: Double? = nil, isDirectory: Bool? = nil, isPackage: Bool? = nil) {
        self.id=id; self.rootID=rootID; self.relativePath=relativePath; self.name=name; self.fileExtension=fileExtension; self.kind=kind; self.size=size; self.modified=modified; self.inode=inode; self.contentState=contentState; self.contentError=contentError; self.created=created; self.isDirectory=isDirectory; self.isPackage=isPackage
    }
}

/// A page's text in the stored UTF-8 body. Separators between pages are excluded.
/// Empty pages have no entry; page numbers always refer to the original PDF.
public struct ContentPageRange: Codable, Equatable, Sendable {
    public var page: Int
    public var utf8Offset: Int
    public var utf8Length: Int
    public init(page: Int, utf8Offset: Int, utf8Length: Int) {
        self.page=page; self.utf8Offset=utf8Offset; self.utf8Length=utf8Length
    }
}

public struct ExtractedContent: Codable, Equatable, Sendable {
    public var text: String
    public var labels: [String]
    public var pages: Int
    public var warning: String?
    /// Nil for older indexes and formats without page boundaries.
    public var pageRanges: [ContentPageRange]?
    public init(text: String = "", labels: [String] = [], pages: Int = 0, warning: String? = nil,
                pageRanges: [ContentPageRange]? = nil) {
        self.text=text; self.labels=labels; self.pages=pages; self.warning=warning; self.pageRanges=pageRanges
    }
}
public struct ExtractionOptions: Sendable {
    public var recognizeImages: Bool
    public var classifyImages: Bool
    public var ocrPDF: Bool
    public init(recognizeImages: Bool = true, classifyImages: Bool = true, ocrPDF: Bool = true) { self.recognizeImages=recognizeImages; self.classifyImages=classifyImages; self.ocrPDF=ocrPDF }
}
public enum SearchScope: String, CaseIterable, Sendable { case all, name, content }
public enum SearchSort: String, CaseIterable, Sendable { case relevance, modified, name, size }
public struct SearchOptions: Sendable {
    public var kind: FileKind?
    public var rootID: String?
    public var scope: SearchScope
    public var sort: SearchSort
    public var onlineOnly: Bool
    public var limit: Int
    public init(kind: FileKind? = nil, rootID: String? = nil, scope: SearchScope = .all, sort: SearchSort = .relevance, onlineOnly: Bool = false, limit: Int = 300) { self.kind=kind; self.rootID=rootID; self.scope=scope; self.sort=sort; self.onlineOnly=onlineOnly; self.limit=limit }
}
public struct SearchHit: Identifiable, Sendable {
    public var id: Int64 { file.id }
    public var file: FileRecord
    public var root: IndexedRoot
    public var snippet: String
    public var matchedIn: String
    public var labels: String
    /// Bounded body evidence: 0 none, 1 mention, 2 nearby terms, 3 focused opening.
    public var contentRelevance: Int = 0
    public var path: String { URL(fileURLWithPath: root.path).appendingPathComponent(file.relativePath).path }
    public init(file: FileRecord, root: IndexedRoot, snippet: String = "", matchedIn: String = "文件名", labels: String = "", contentRelevance: Int = 0) { self.contentRelevance=contentRelevance; self.file=file; self.root=root; self.snippet=snippet; self.matchedIn=matchedIn; self.labels=labels }
}
public struct IndexStatistics: Sendable {
    public var files: Int
    public var documents: Int
    public var images: Int
    public var pending: Int
    public var errors: Int
    public var indexedContent: Int
    public init(files: Int = 0, documents: Int = 0, images: Int = 0, pending: Int = 0, errors: Int = 0, indexedContent: Int = 0) { self.files=files; self.documents=documents; self.images=images; self.pending=pending; self.errors=errors; self.indexedContent=indexedContent }
}
