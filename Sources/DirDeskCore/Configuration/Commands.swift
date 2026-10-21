import Foundation

/// Context-menu actions, including the four separators that can be ordered like actions.
public enum ContextMenuCommand: String, Codable, CaseIterable, Sendable {
    case open, openWith, openTerminal, openEditor, openInNewTab, quickLook
    case separatorOpen
    case getInfo, rename, builtInTools, compress, extract, extractTo, duplicate, makeAlias
    case separatorEdit
    case invertSelection, cut, copy, copyTo, share, tags, sendTo
    case separatorLocation
    case copyPath, reveal, bookmarks, checksum, batchRename, paneTransfer
    case separatorDestructive
    case trash

    public var isSeparator: Bool { rawValue.hasPrefix("separator") }

    /// "DirDeck Default" preset: declaration order with Built-in Tools ahead of Get Info, as the original's
    /// `ContextMenuCommand.defaultOrder` constant (DirDeckCore, static array read from the binary).
    public static let defaultPreset: [ContextMenuCommand] = [
        .open, .openWith, .openTerminal, .openEditor, .openInNewTab, .quickLook, .separatorOpen,
        .builtInTools, .getInfo, .rename, .compress, .extract, .extractTo, .duplicate, .makeAlias, .separatorEdit,
        .invertSelection, .cut, .copy, .copyTo, .share, .tags, .sendTo, .separatorLocation,
        .copyPath, .reveal, .bookmarks, .checksum, .batchRename, .paneTransfer, .separatorDestructive, .trash,
    ]

    /// "Finder Style" preset and the order a new configuration starts with: the original's
    /// `ContextMenuCommand.finderOrder` constant, which its configuration also uses as the default.
    public static let finderStylePreset: [ContextMenuCommand] = [
        .open, .openWith, .openInNewTab, .separatorOpen, .trash, .separatorDestructive,
        .getInfo, .rename, .compress, .duplicate, .makeAlias, .quickLook, .separatorEdit,
        .copy, .share, .tags, .separatorLocation, .builtInTools, .openTerminal, .openEditor,
        .extract, .extractTo, .invertSelection, .cut, .copyTo, .sendTo, .copyPath, .reveal,
        .bookmarks, .checksum, .batchRename, .paneTransfer,
    ]
}

/// Actions that can appear in the toolbar or its More menu.
public enum ToolbarCommand: String, Codable, CaseIterable, Sendable {
    case viewMode, paneLayout, newFolder, newFile, search, terminal, inspector, openFolder
    case sort, foldersFirst, grouping, externalTools, quickLook, copyPath, revealInFinder
    case hiddenFiles, airDrop, folderSync

    public static let defaultToolbar: [ToolbarCommand] = [.viewMode, .newFolder, .newFile, .terminal, .copyPath, .sort, .grouping]
}

public enum BuiltInToolCategory: String, Codable, CaseIterable, Sendable {
    case images, folders, pdf, metadataPrivacy
}

public enum BuiltInToolSelectionRule: String, Codable, Sendable {
    case exactlyOne, oneOrMore, twoOrMore

    public func accepts(count: Int) -> Bool {
        switch self {
        case .exactlyOne: count == 1
        case .oneOrMore: count >= 1
        case .twoOrMore: count >= 2
        }
    }
}

public enum BuiltInToolID: String, Codable, CaseIterable, Sendable {
    case collectIntoFolder, dissolveFolder
    case imageRotateLeft, imageRotateRight, imageCrop, imageConvert, imageCompress, imageWatermark
    case imageRemoveBackground, imagesCreatePDF
    case imageViewLocation, imageRemoveLocationMetadata
    case pdfSplit, pdfExtractPages, pdfMerge, pdfRotatePages, pdfCompress, pdfExportImages

    public var category: BuiltInToolCategory {
        switch self {
        case .collectIntoFolder, .dissolveFolder: .folders
        case .imageViewLocation, .imageRemoveLocationMetadata: .metadataPrivacy
        case .pdfSplit, .pdfExtractPages, .pdfMerge, .pdfRotatePages, .pdfCompress, .pdfExportImages: .pdf
        default: .images
        }
    }

    public var selectionRule: BuiltInToolSelectionRule {
        switch self {
        // Runtime reference: crop, background removal, photo location and the PDF page tools need exactly one item.
        case .imageCrop, .imageRemoveBackground, .imageViewLocation, .pdfSplit, .pdfExtractPages, .pdfRotatePages, .pdfExportImages: .exactlyOne
        case .pdfMerge: .twoOrMore
        default: .oneOrMore
        }
    }
}

public enum FloatingBallAction: String, Codable, CaseIterable, Sendable {
    case back, forward, up, selectAll, compressAll, collectAll, compressFolder, collectFolder, refresh, copyPath
}

public enum SidebarModule: String, Codable, CaseIterable, Sendable {
    case builtIn, commonPaths, locations, bookmarks, tags
}

public enum SidebarBuiltInItem: String, Codable, CaseIterable, Sendable {
    case recent, fileTransit, sharedFolder
}

public enum SidebarBuiltInLocation: String, Codable, CaseIterable, Sendable {
    case iCloudDrive, home, thisMac, airDrop, trash
}

public enum ExternalToolKind: String, Codable, CaseIterable, Sendable {
    case terminal, editor
}

public struct ExternalTool: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bundleIdentifier: String?
    public var applicationPath: String
    public var kind: ExternalToolKind
    public var isDefault: Bool
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, bundleIdentifier: String?, applicationPath: String,
                kind: ExternalToolKind, isDefault: Bool, sortOrder: Int) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.kind = kind
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }
}
