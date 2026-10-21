import AppKit
import Carbon.HIToolbox
import Combine
import DirDeskCore

/// Floating Files configuration, stored like the original's `dirdeck-file-floating-v1`
/// (Carbon key code and modifier mask for the global shortcut).
struct FileFloatingConfiguration: Codable, Equatable {
    struct HotZone: Codable, Equatable {
        var enabled = true
        var hoverEnabled = true
        var custom = false
        /// 0…1 position along the edge (center of the zone).
        var center = 0.5
        /// Length along the edge and depth inward, in points (custom zones).
        var length = 220.0
        var depth = 6.0
    }

    var shortcutKey: UInt32 = UInt32(kVK_ANSI_F)
    var shortcutModifiers: UInt32 = UInt32(cmdKey | optionKey)
    var shortcutEnabled = true
    var shortcutLabel = "⌥⌘F"
    var hoverDelay = 0.15
    var panelWidth = 760.0
    var panelHeight = 400.0
    var lastDirectory: URL?
    var pinnedDirectories: [URL] = []
    /// Hot-zone settings per display (keyed by display name + edge).
    var screens: [String: HotZone] = [:]
    var viewMode: BrowserViewMode = .list

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FileFloatingConfiguration()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        shortcutKey = v(.shortcutKey, d.shortcutKey)
        shortcutModifiers = v(.shortcutModifiers, d.shortcutModifiers)
        shortcutEnabled = v(.shortcutEnabled, d.shortcutEnabled)
        shortcutLabel = v(.shortcutLabel, d.shortcutLabel)
        hoverDelay = v(.hoverDelay, d.hoverDelay)
        panelWidth = v(.panelWidth, d.panelWidth)
        panelHeight = v(.panelHeight, d.panelHeight)
        lastDirectory = try? c.decodeIfPresent(URL.self, forKey: .lastDirectory)
        pinnedDirectories = v(.pinnedDirectories, d.pinnedDirectories)
        screens = v(.screens, d.screens)
        viewMode = v(.viewMode, d.viewMode)
    }

    func hotZone(for screen: NSScreen, edge: FileTransitDockEdge) -> HotZone {
        screens[Self.key(screen, edge)] ?? HotZone()
    }

    static func key(_ screen: NSScreen, _ edge: FileTransitDockEdge) -> String {
        "\(screen.localizedName)|\(edge.rawValue)"
    }

    /// Label such as "⌥⌘F" for a Carbon key code and modifier mask.
    static func label(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyCodeNames.name(for: keyCode)
    }
}

@MainActor
final class FileFloatingStore: ObservableObject {
    static let shared = FileFloatingStore()
    @Published var configuration: FileFloatingConfiguration { didSet { save() } }
    private let store = PersistenceStore<FileFloatingConfiguration>(key: DefaultsKey.fileFloating) { FileFloatingConfiguration() }

    private init() {
        configuration = store.load().value
    }

    private func save() { try? store.save(configuration) }

    func reset() { configuration = FileFloatingConfiguration() }
}

/// Carbon virtual key codes → display names for shortcut labels.
enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        let table: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
            kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
            kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
            kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6",
            kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        ]
        return table[Int(keyCode)] ?? "#\(keyCode)"
    }

    /// Carbon modifier mask from AppKit flags.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}

/// System-wide shortcut through Carbon `RegisterEventHotKey` (no accessibility permission needed).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var reference: EventHotKeyRef?
    private var handlerInstalled = false
    private var action: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        unregister()
        self.action = action
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
                }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4444_534B), id: 1) // 'DDSK'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}
