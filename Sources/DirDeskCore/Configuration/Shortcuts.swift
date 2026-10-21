import Foundation

public enum ShortcutCommand: String, Codable, CaseIterable, Sendable {
    case newWindow, openSelection, invertSelection, newTab, closeTab, removeDuplicateTabs, reopenClosedTab
    case editPath, search, globalQuickSearch, navigateBack, navigateForward, navigateUp, addBookmark
    case newFolder, newFile, rename, duplicate, cut, copy, copyPath, paste, pasteAndMove, moveToTrash, quickLook
    case layoutSingle, layoutTwoColumns, layoutTwoRows, layoutFourGrid, layoutOneLeftTwoRight, layoutTwoLeftOneRight
    case layoutOneTopTwoBottom, layoutTwoTopOneBottom, layoutThreeRows, layoutThreeColumns, layoutFourColumns, layoutFourRows
    case previousPane, nextPane, toggleInspector, iconView, listView, columnView, imageView
    case batchRename, openTerminal, openEditor

    /// Pane layout selected by a layout command, if any.
    public var paneLayout: PaneLayout? {
        switch self {
        case .layoutSingle: .single
        case .layoutTwoColumns: .twoColumns
        case .layoutTwoRows: .twoRows
        case .layoutFourGrid: .fourGrid
        case .layoutOneLeftTwoRight: .oneLeftTwoRight
        case .layoutTwoLeftOneRight: .twoLeftOneRight
        case .layoutOneTopTwoBottom: .oneTopTwoBottom
        case .layoutTwoTopOneBottom: .twoTopOneBottom
        case .layoutThreeRows: .threeRows
        case .layoutThreeColumns: .threeColumns
        default: nil
        }
    }
}

public enum ShortcutModifier: String, Codable, CaseIterable, Sendable, Comparable {
    case control, option, shift, cmd

    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .cmd: "⌘"
        }
    }

    /// Display order used by macOS menus: ⌃⌥⇧⌘.
    public static func < (lhs: ShortcutModifier, rhs: ShortcutModifier) -> Bool {
        let order: [ShortcutModifier] = [.control, .option, .shift, .cmd]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// A key plus modifiers. `key` uses the original's tokens: letters, digits, punctuation,
/// "tab", "delete", "space", "return", "up"/"down"/"left"/"right", "escape", or "dd" for the double-tap trigger.
public struct ShortcutBinding: Codable, Hashable, Sendable {
    public var modifiers: [ShortcutModifier]
    public var key: String

    public init(_ modifiers: [ShortcutModifier], _ key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    public var isDoubleTap: Bool { key.count == 2 && modifiers.isEmpty && Set(key).count == 1 }

    /// Modifier order does not matter: the original stores both [cmd, option] and [option, cmd].
    public static func == (lhs: ShortcutBinding, rhs: ShortcutBinding) -> Bool {
        Set(lhs.modifiers) == Set(rhs.modifiers) && lhs.key.lowercased() == rhs.key.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Set(modifiers))
        hasher.combine(key.lowercased())
    }

    public var normalized: ShortcutBinding {
        ShortcutBinding(Array(Set(modifiers)).sorted(), key.lowercased())
    }

    public var displayString: String {
        if isDoubleTap { return key.uppercased() }
        return modifiers.sorted().map(\.symbol).joined() + Self.keySymbol(key)
    }

    static func keySymbol(_ key: String) -> String {
        switch key.lowercased() {
        case "tab": "⇥"
        case "delete": "⌫"
        case "forwarddelete": "⌦"
        case "space": "Space"
        case "return": "↩"
        case "escape": "⎋"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.uppercased()
        }
    }

    public enum ParseError: Error, Equatable {
        case empty, unknownToken(String), missingModifier, missingKey, multipleKeys
    }

    private static let modifierTokens: [String: ShortcutModifier] = [
        "cmd": .cmd, "command": .cmd, "⌘": .cmd,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "control": .control, "ctrl": .control, "⌃": .control,
    ]

    private static let namedKeys: Set<String> = [
        "tab", "delete", "forwarddelete", "space", "return", "enter", "escape", "esc",
        "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    /// Parses text such as "cmd+option+k" or "dd". Single plain characters need a modifier,
    /// except named keys (Space, Return, Delete…) and the double-tap form.
    public static func parse(_ text: String) throws -> ShortcutBinding {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { throw ParseError.empty }
        let tokens = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: [ShortcutModifier] = []
        var key: String?
        for token in tokens {
            guard !token.isEmpty else { throw ParseError.unknownToken(text) }
            if let modifier = modifierTokens[token] {
                modifiers.append(modifier)
                continue
            }
            guard key == nil else { throw ParseError.multipleKeys }
            if token.count == 1 || namedKeys.contains(token) {
                key = token == "enter" ? "return" : (token == "esc" ? "escape" : token)
            } else if token.count == 2, Set(token).count == 1, tokens.count == 1 {
                key = token
            } else {
                throw ParseError.unknownToken(token)
            }
        }
        guard let key else { throw ParseError.missingKey }
        let binding = ShortcutBinding(modifiers, key).normalized
        if binding.modifiers.isEmpty && key.count == 1 && !binding.isDoubleTap {
            throw ParseError.missingModifier
        }
        return binding
    }

    public var textForm: String {
        if isDoubleTap { return key }
        let names: [ShortcutModifier: String] = [.cmd: "cmd", .option: "option", .shift: "shift", .control: "control"]
        return (modifiers.sorted().map { names[$0]! } + [key]).joined(separator: "+")
    }
}

public enum ShortcutDefaults {
    /// Primary bindings shipped by the original (35 of 47 commands are bound).
    public static let primary: [ShortcutCommand: ShortcutBinding] = [
        .copy: .init([.cmd], "c"),
        .search: .init([.cmd], "f"),
        .openTerminal: .init([.option, .cmd], "t"),
        .iconView: .init([.cmd], "1"),
        .nextPane: .init([.control], "tab"),
        .moveToTrash: .init([.cmd], "delete"),
        .quickLook: .init([], "space"),
        .addBookmark: .init([.cmd], "d"),
        .columnView: .init([.cmd], "3"),
        .pasteAndMove: .init([.option, .cmd], "v"),
        .invertSelection: .init([.shift, .cmd], "i"),
        .newFolder: .init([.shift, .cmd], "n"),
        .copyPath: .init([.shift, .cmd], "u"),
        .rename: .init([], "return"),
        .editPath: .init([.shift, .cmd], "g"),
        .newTab: .init([.cmd], "t"),
        .toggleInspector: .init([.option, .cmd], "i"),
        .navigateForward: .init([.cmd], "]"),
        .batchRename: .init([.control, .cmd], "r"),
        .openSelection: .init([.cmd], "o"),
        .reopenClosedTab: .init([.shift, .cmd], "t"),
        .openEditor: .init([.option, .cmd], "e"),
        .newWindow: .init([.cmd], "n"),
        .removeDuplicateTabs: .init([.shift, .cmd], "k"),
        .previousPane: .init([.shift, .control], "tab"),
        .listView: .init([.cmd], "2"),
        .globalQuickSearch: .init([], "dd"),
        .navigateBack: .init([.cmd], "["),
        .newFile: .init([.option, .cmd], "n"),
        .paste: .init([.cmd], "v"),
        .navigateUp: .init([.cmd], "up"),
        .imageView: .init([.cmd], "4"),
        .cut: .init([.cmd], "x"),
        .closeTab: .init([.cmd], "w"),
        .duplicate: .init([.shift, .cmd], "d"),
    ]
}

public struct ShortcutConflict: Equatable, Sendable {
    public var binding: ShortcutBinding
    public var commands: [ShortcutCommand]
}

/// Resolved table of primary and secondary bindings with conflict detection.
public struct ShortcutTable: Sendable {
    public var primary: [ShortcutCommand: ShortcutBinding]
    public var secondary: [ShortcutCommand: ShortcutBinding]
    public var disabled: Set<ShortcutCommand>

    public init(primary: [ShortcutCommand: ShortcutBinding], secondary: [ShortcutCommand: ShortcutBinding], disabled: Set<ShortcutCommand>) {
        self.primary = primary
        self.secondary = secondary
        self.disabled = disabled
    }

    public func bindings(for command: ShortcutCommand) -> [ShortcutBinding] {
        guard !disabled.contains(command) else { return [] }
        return [primary[command], secondary[command]].compactMap { $0 }
    }

    public func command(for binding: ShortcutBinding) -> ShortcutCommand? {
        let wanted = binding.normalized
        for command in ShortcutCommand.allCases where !disabled.contains(command) {
            if bindings(for: command).contains(where: { $0.normalized == wanted }) { return command }
        }
        return nil
    }

    public var conflicts: [ShortcutConflict] {
        var owners: [ShortcutBinding: [ShortcutCommand]] = [:]
        for command in ShortcutCommand.allCases {
            for binding in bindings(for: command) {
                owners[binding.normalized, default: []].append(command)
            }
        }
        return owners.filter { $0.value.count > 1 }
            .map { ShortcutConflict(binding: $0.key, commands: $0.value) }
            .sorted { $0.binding.textForm < $1.binding.textForm }
    }
}
