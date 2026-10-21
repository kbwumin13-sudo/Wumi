import Foundation

public enum BuiltInFileTemplateKind: String, Codable, CaseIterable, Sendable {
    case markdown, plainText, jsonFile, wordDocument, excelSpreadsheet, powerPointPresentation, csvSpreadsheet
    case pagesDocument, keynotePresentation, numbersSpreadsheet

    public var defaultFileName: String {
        switch self {
        case .markdown: "Untitled.md"
        case .plainText: "Untitled.txt"
        case .jsonFile: "Untitled.json"
        case .wordDocument: "Untitled.docx"
        case .excelSpreadsheet: "Untitled.xlsx"
        case .powerPointPresentation: "Untitled.pptx"
        case .csvSpreadsheet: "Untitled.csv"
        case .pagesDocument: "Untitled.pages"
        case .keynotePresentation: "Untitled.key"
        case .numbersSpreadsheet: "Untitled.numbers"
        }
    }

    public var defaultName: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        case .jsonFile: "JSON"
        case .wordDocument: "Word Document"
        case .excelSpreadsheet: "Excel Spreadsheet"
        case .powerPointPresentation: "PowerPoint Presentation"
        case .csvSpreadsheet: "CSV Spreadsheet"
        case .pagesDocument: "Pages Document"
        case .keynotePresentation: "Keynote Presentation"
        case .numbersSpreadsheet: "Numbers Spreadsheet"
        }
    }
}

public enum TemplateDatePosition: String, Codable, CaseIterable, Sendable {
    case beforeName, afterName
}

public struct NewFileTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var fileNamePattern: String
    public var contents: String
    public var contentData: Data?
    public var sortOrder: Int
    public var isDefault: Bool
    public var builtInKind: BuiltInFileTemplateKind?
    public var datePosition: TemplateDatePosition
    public var dateFormat: String?
    public var emoji: String?

    public init(id: UUID = UUID(), name: String, fileNamePattern: String, contents: String = "", contentData: Data? = nil,
                sortOrder: Int, isDefault: Bool = false, builtInKind: BuiltInFileTemplateKind? = nil,
                datePosition: TemplateDatePosition = .beforeName, dateFormat: String? = nil, emoji: String? = nil) {
        self.id = id
        self.name = name
        self.fileNamePattern = fileNamePattern
        self.contents = contents
        self.contentData = contentData
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.builtInKind = builtInKind
        self.datePosition = datePosition
        self.dateFormat = dateFormat
        self.emoji = emoji
    }

    /// Stable IDs for the seven default templates (00000101…00000107).
    static func builtInID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "D1DDE5C0-0000-4000-8000-%012d", 100 + n))!
    }

    public static let defaults: [NewFileTemplate] = {
        let kinds: [(BuiltInFileTemplateKind, String)] = [
            (.markdown, ""), (.plainText, ""), (.jsonFile, "{\n}\n"), (.wordDocument, ""),
            (.excelSpreadsheet, ""), (.powerPointPresentation, ""), (.csvSpreadsheet, ""),
        ]
        return kinds.enumerated().map { index, entry in
            NewFileTemplate(id: builtInID(index + 1), name: entry.0.defaultName, fileNamePattern: entry.0.defaultFileName,
                            contents: entry.1, sortOrder: index, isDefault: index == 0, builtInKind: entry.0)
        }
    }()
}

/// Everything the user can customize about commands, mirroring `dirdeck-efficiency-configuration-v1`.
public struct EfficiencyConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 32

    public var schemaVersion: Int = currentSchemaVersion
    public var contextMenuCommands: [ContextMenuCommand] = ContextMenuCommand.finderStylePreset
    public var externalTools: [ExternalTool] = EfficiencyConfiguration.defaultExternalTools
    public var fileTemplates: [NewFileTemplate] = NewFileTemplate.defaults
    public var shortcuts: [ShortcutCommand: ShortcutBinding] = ShortcutDefaults.primary
    public var secondaryShortcuts: [ShortcutCommand: ShortcutBinding] = [:]
    public var disabledShortcutCommands: [ShortcutCommand] = []
    public var workspacePreferences: WorkspacePreferences = .defaults
    public var enabledBuiltInTools: [BuiltInToolID] = BuiltInToolID.allCases
    public var toolbarCommands: [ToolbarCommand] = ToolbarCommand.defaultToolbar

    public init() {}

    public static let defaults = EfficiencyConfiguration()

    public static var defaultExternalTools: [ExternalTool] {
        [ExternalTool(id: UUID(uuidString: "D1DDE5C0-0000-4000-8000-000000000201")!, name: "Terminal",
                      bundleIdentifier: "com.apple.Terminal", applicationPath: "/System/Applications/Utilities/Terminal.app",
                      kind: .terminal, isDefault: true, sortOrder: 0)]
    }

    public var shortcutTable: ShortcutTable {
        ShortcutTable(primary: shortcuts, secondary: secondaryShortcuts, disabled: Set(disabledShortcutCommands))
    }

    public func defaultTool(of kind: ExternalToolKind) -> ExternalTool? {
        let tools = externalTools.filter { $0.kind == kind }.sorted { $0.sortOrder < $1.sortOrder }
        return tools.first(where: \.isDefault) ?? tools.first
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EfficiencyConfiguration()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        schemaVersion = v(.schemaVersion, d.schemaVersion)
        contextMenuCommands = v(.contextMenuCommands, d.contextMenuCommands)
        externalTools = v(.externalTools, d.externalTools)
        fileTemplates = v(.fileTemplates, d.fileTemplates)
        shortcuts = v(.shortcuts, d.shortcuts)
        secondaryShortcuts = v(.secondaryShortcuts, d.secondaryShortcuts)
        disabledShortcutCommands = v(.disabledShortcutCommands, d.disabledShortcutCommands)
        workspacePreferences = v(.workspacePreferences, d.workspacePreferences)
        enabledBuiltInTools = v(.enabledBuiltInTools, d.enabledBuiltInTools)
        toolbarCommands = v(.toolbarCommands, d.toolbarCommands)
    }
}
