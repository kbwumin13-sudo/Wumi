import Foundation

// Lightning Search ("闪电搜索") query language: an Everything-style expression syntax.
// The grammar follows the in-app help strings listed in docs/recon/04 §5.1.

/// Parsed Lightning Search expression. Values stay symbolic (`today`, `~/Documents`) and are
/// resolved against the clock, calendar and home folder when the query runs.
public indirect enum LightningQuery: Equatable, Sendable {
    /// The empty query; matches every indexed item.
    case everything
    case term(LightningTerm)
    case filter(LightningFilter)
    case not(LightningQuery)
    case and([LightningQuery])
    case or([LightningQuery])
    /// `case:` / `nocase:`: forces case sensitivity on or off inside the subtree.
    case matchCase(Bool, LightningQuery)
}

/// A bare search word or quoted phrase. `*` matches any characters, `?` one character.
/// A term containing `/` is matched against the path (see `LightningPathPattern`).
public struct LightningTerm: Equatable, Sendable {
    public var text: String

    public init(_ text: String) {
        self.text = text
    }

    public var hasWildcards: Bool { text.contains("*") || text.contains("?") }
    public var isPath: Bool { text.contains("/") }
}

public enum LightningFilter: Equatable, Sendable {
    /// `ext:jpg;png`: lowercased extensions without dots. An empty list means "no extension".
    case `extension`([String])
    /// `type:image;video`: any of the categories.
    case type([LightningFileType])
    /// `folder:` (only folders), optionally with a name term: `folder:src`.
    case folder(LightningTerm?)
    /// `file:` (only files), optionally with a name term.
    case file(LightningTerm?)
    /// `name:report`: the term is matched against the item name only, never the path.
    case name(LightningTerm)
    /// `size:>1MB;empty`: any of the conditions. Folders never match a size filter.
    case size([LightningSizeCondition])
    case dateModified([LightningDateCondition])
    case dateCreated([LightningDateCondition])
    /// `infolder:` / `parent:`: descendants of any of the folders. `~` expands to the home folder.
    case inFolder([String])
    /// `nosubfolders:`: direct children of any of the folders.
    case noSubfolders([String])
    /// `regex:`: a regular expression on the item name; follows the effective case sensitivity.
    case regex(String)
    /// `content:`: literal text stored in files (not extracted PDF or Word text), scanned at query time.
    case content([String])
    /// `tag:`: a Finder tag whose name contains any of the values. An empty list means "has any tag".
    case tag([String])
    /// `tagexact:`: a Finder tag whose whole name is one of the values (the visual tag filter uses it).
    case tagExact([String])
}

/// File categories for `type:`. Aliases follow the original help ("type:text and type:office are
/// document aliases").
public enum LightningFileType: String, CaseIterable, Sendable {
    case file, folder, picture, video, audio, document, presentation, spreadsheet, pdf, archive, source, executable

    public static func named(_ name: String) -> LightningFileType? {
        switch name.lowercased() {
        case "file", "files": .file
        case "folder", "folders", "dir", "directory", "directories": .folder
        case "picture", "pictures", "image", "images", "photo", "photos", "pic": .picture
        case "video", "videos", "movie", "movies": .video
        case "audio", "music", "song", "songs": .audio
        case "doc", "docs", "document", "documents", "office", "text": .document
        case "presentation", "presentations", "ppt", "slides": .presentation
        case "spreadsheet", "spreadsheets", "xls", "excel", "sheet", "sheets": .spreadsheet
        case "pdf": .pdf
        case "archive", "archives", "compressed", "zip": .archive
        case "source", "dev", "code": .source
        case "exe", "executable", "executables", "program", "programs", "app", "apps", "application", "applications": .executable
        default: nil
        }
    }

    /// Lowercased extensions of the category; empty for `file` and `folder`, which test the item kind.
    public var extensions: [String] {
        switch self {
        case .file, .folder:
            return []
        case .picture:
            return ["jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "avif", "jxl",
                    "svg", "svgz", "ico", "icns", "psd", "ai", "eps", "raw", "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw",
                    "srf", "sr2", "orf", "rw2", "raf", "pef", "srw", "x3f", "3fr", "erf", "mrw", "jp2", "j2k", "tga", "exr",
                    "hdr", "pict", "pct", "xcf", "sketch"]
        case .video:
            return ["mp4", "m4v", "mov", "qt", "avi", "mkv", "wmv", "flv", "f4v", "webm", "mpg", "mpeg", "mpe", "m2v",
                    "m2ts", "mts", "ts", "3gp", "3g2", "ogv", "vob", "rm", "rmvb", "asf", "divx", "hevc", "dv", "mxf"]
        case .audio:
            return ["mp3", "m4a", "m4b", "m4p", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "alac", "ogg", "oga",
                    "opus", "wma", "ape", "mid", "midi", "caf", "amr", "au", "snd", "dsf", "dff", "wv", "ra", "mka", "ac3"]
        case .document:
            return ["txt", "text", "md", "markdown", "mdown", "rtf", "rtfd", "doc", "docx", "docm", "dot", "dotx", "odt",
                    "ott", "pages", "pdf", "tex", "log", "csv", "tsv", "xls", "xlsx", "xlsm", "xlsb", "ods", "numbers",
                    "ppt", "pptx", "pptm", "pps", "ppsx", "odp", "key", "keynote", "epub", "mobi", "azw", "azw3", "djvu",
                    "xps", "oxps", "wpd", "wps", "wri", "eml", "msg", "org", "rst", "adoc", "asciidoc"]
        case .presentation:
            return ["ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx", "potm", "key", "keynote", "odp", "otp"]
        case .spreadsheet:
            return ["xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm", "csv", "tsv", "numbers", "ods", "ots"]
        case .pdf:
            return ["pdf"]
        case .archive:
            return ["zip", "zipx", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma",
                    "tlz", "lz4", "zst", "tzst", "z", "cab", "iso", "dmg", "sparseimage", "sparsebundle", "sit", "sitx",
                    "cpio", "xar", "pkg", "mpkg", "ar", "deb", "rpm", "jar", "war", "ear", "apk", "ipa", "aar", "cbz", "cbr"]
        case .source:
            return ["c", "h", "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "h++", "m", "mm", "swift", "java", "kt", "kts",
                    "scala", "sc", "groovy", "gradle", "go", "rs", "py", "pyi", "pyw", "rb", "php", "pl", "pm", "lua", "js",
                    "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "vue", "svelte", "astro", "css", "scss", "sass", "less",
                    "html", "htm", "xhtml", "xml", "xsl", "json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "cfg",
                    "conf", "sh", "bash", "zsh", "fish", "ps1", "psm1", "bat", "cmd", "sql", "r", "dart", "cs", "fs",
                    "fsx", "vb", "erl", "hrl", "ex", "exs", "hs", "lhs", "clj", "cljs", "cljc", "edn", "elm", "ml", "mli",
                    "nim", "zig", "v", "sv", "svh", "vhd", "vhdl", "asm", "s", "cmake", "mk", "make", "proto", "graphql",
                    "gql", "ipynb", "jl", "f", "f90", "for", "pas", "d", "cr", "tf", "hcl", "nix", "gd", "glsl", "metal",
                    "hlsl", "cu", "plist", "xib", "storyboard", "entitlements", "pbxproj", "xcconfig", "strings", "sol"]
        case .executable:
            return ["app", "exe", "msi", "com", "bat", "cmd", "command", "tool", "sh", "bin", "run", "out", "appimage",
                    "jar", "apk", "ipa", "xpc", "workflow", "action", "scpt", "applescript", "prefpane", "saver"]
        }
    }
}

/// `>`, `>=`, `<`, `<=`, `=` (also the default when no operator is given) and `!=`.
public enum LightningComparison: String, Equatable, Sendable {
    case equal, notEqual, greater, greaterOrEqual, less, lessOrEqual
}

/// Named size ranges with Everything's thresholds. Bounds use decimal units (1 KB = 1000 bytes).
public enum LightningSizeClass: String, CaseIterable, Sendable {
    case empty, tiny, small, medium, large, huge, gigantic

    public static func named(_ name: String) -> LightningSizeClass? {
        let lowered = name.lowercased()
        if lowered == "giant" { return .gigantic }
        return LightningSizeClass(rawValue: lowered)
    }

    /// Inclusive byte bounds; nil means unbounded.
    public var bounds: (lower: Int64, upper: Int64?) {
        switch self {
        case .empty: (0, 0)
        case .tiny: (1, 10_000)
        case .small: (10_001, 100_000)
        case .medium: (100_001, 1_000_000)
        case .large: (1_000_001, 16_000_000)
        case .huge: (16_000_001, 128_000_000)
        case .gigantic: (128_000_001, nil)
        }
    }
}

public enum LightningSizeCondition: Equatable, Sendable {
    case compare(LightningComparison, Int64)
    /// `a..b`, both bounds inclusive; a missing side is unbounded.
    case range(Int64?, Int64?)
    case named(LightningSizeClass)
}

/// A date value names a span of time: a keyword relative to "now" or a calendar day, month or year.
public enum LightningDateValue: Equatable, Sendable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear
    /// The last 7 days, month or year up to now.
    case pastWeek, pastMonth, pastYear
    case day(year: Int, month: Int, day: Int)
    case month(year: Int, month: Int)
    case year(Int)

    static func keyword(_ text: String) -> LightningDateValue? {
        switch text.lowercased() {
        case "today": .today
        case "yesterday": .yesterday
        case "thisweek": .thisWeek
        case "lastweek": .lastWeek
        case "thismonth": .thisMonth
        case "lastmonth": .lastMonth
        case "thisyear": .thisYear
        case "lastyear": .lastYear
        case "pastweek": .pastWeek
        case "pastmonth": .pastMonth
        case "pastyear": .pastYear
        default: nil
        }
    }

    /// The half-open interval `[start, end)` this value names.
    public func interval(now: Date, calendar: Calendar) -> Range<Date> {
        func span(_ component: Calendar.Component, offset: Int) -> Range<Date> {
            let anchor = calendar.date(byAdding: component, value: offset, to: now) ?? now
            guard let interval = calendar.dateInterval(of: component, for: anchor) else { return anchor..<anchor }
            return interval.start..<interval.end
        }
        func past(_ component: Calendar.Component) -> Range<Date> {
            (calendar.date(byAdding: component, value: -1, to: now) ?? now)..<Date.distantFuture
        }
        switch self {
        case .today: return span(.day, offset: 0)
        case .yesterday: return span(.day, offset: -1)
        case .thisWeek: return span(.weekOfYear, offset: 0)
        case .lastWeek: return span(.weekOfYear, offset: -1)
        case .thisMonth: return span(.month, offset: 0)
        case .lastMonth: return span(.month, offset: -1)
        case .thisYear: return span(.year, offset: 0)
        case .lastYear: return span(.year, offset: -1)
        case .pastWeek: return past(.weekOfYear)
        case .pastMonth: return past(.month)
        case .pastYear: return past(.year)
        case let .day(year, month, day):
            return Self.calendarSpan(DateComponents(year: year, month: month, day: day), .day, calendar)
        case let .month(year, month):
            return Self.calendarSpan(DateComponents(year: year, month: month, day: 1), .month, calendar)
        case let .year(year):
            return Self.calendarSpan(DateComponents(year: year, month: 1, day: 1), .year, calendar)
        }
    }

    private static func calendarSpan(_ components: DateComponents, _ unit: Calendar.Component, _ calendar: Calendar) -> Range<Date> {
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: unit, value: 1, to: start) else { return Date.distantPast..<Date.distantPast }
        return start..<end
    }

    var isAbsolute: Bool {
        switch self {
        case .day, .month, .year: true
        default: false
        }
    }
}

public enum LightningDateCondition: Equatable, Sendable {
    /// `>` means after the named span, `>=` from its start, `<` before it, `<=` until its end.
    case compare(LightningComparison, LightningDateValue)
    /// `a..b`: from the start of `a` through the end of `b`; a missing side is unbounded.
    case range(LightningDateValue?, LightningDateValue?)
}

/// A Lightning Search syntax error. `offset` counts Characters from the start of the expression.
public struct LightningSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var fragment: String
    public var offset: Int

    public init(message: String, fragment: String, offset: Int) {
        self.message = message
        self.fragment = fragment
        self.offset = offset
    }

    public static let unknownFilter = "Only supported filters are listed. Unknown filters report an error."
    public static let missingValue = "Missing value"
    public static let invalidRegularExpression = "Invalid regular expression."
    public static let invalidSize = "Enter a nonnegative file size."
    public static let invalidDate = "Enter a date as YYYY-MM-DD."
    public static let reversedRange = "The end of the range must not be before the start."
    public static let unknownType = "Unknown file type"
    public static let invalidFolder = "Choose a folder or enter an absolute path."

    public var description: String { "\(message) (\(fragment) at \(offset))" }
}
