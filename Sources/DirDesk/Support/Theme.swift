import AppKit
import DirDeskCore
import SwiftUI

enum Theme {
    /// Semantic, opaque surfaces keep file metadata legible regardless of the desktop behind the window.
    static let chrome = Color(nsColor: .windowBackgroundColor)
    static let content = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let selectedTab = Color.primary.opacity(0.085)

    /// Soft background and text colors for date-age pills. Strength follows the date color theme.
    static func dateAgeColors(_ bucket: DateAgeBucket, theme: DateColorTheme, dark: Bool) -> (background: NSColor, text: NSColor) {
        let base: NSColor = switch bucket {
        case .minutes: NSColor(srgbRed: 0.93, green: 0.30, blue: 0.30, alpha: 1)
        case .hour: NSColor(srgbRed: 0.91, green: 0.36, blue: 0.62, alpha: 1)
        // Day, week and older were solved from the original's pills over two row backgrounds (dark mode,
        // default "light" theme): about 31 % of these colors. Minutes, hour and the stronger themes are not in
        // the captures, so their values are inferred.
        case .day: NSColor(srgbRed: 0.28, green: 0.56, blue: 0.85, alpha: 1)
        case .week: NSColor(srgbRed: 0.30, green: 0.66, blue: 0.46, alpha: 1)
        case .older: NSColor(srgbRed: 0.64, green: 0.47, blue: 0.75, alpha: 1)
        }
        let alpha: CGFloat = switch theme {
        case .light: dark ? 0.18 : 0.10
        case .medium: dark ? 0.32 : 0.22
        case .highContrast: dark ? 0.56 : 0.40
        }
        // The original keeps the date text near-white on dark pills.
        let text = dark ? NSColor(white: 0.9, alpha: 1) : base.blended(withFraction: 0.35, of: .black) ?? base
        return (base.withAlphaComponent(alpha), text)
    }

    static func bookmarkBarColor(_ background: BookmarkBarBackground, customRGB: Int, dark: Bool) -> Color {
        if background == .white || background == .paleGray { return chrome }
        let rgb: Int = switch background {
        case .white: 0xFFFFFF
        case .paleBlue: 0xEEF4FB
        case .paleMint: 0xEDF7F1
        case .paleLavender: 0xF2EFFA
        case .palePeach: 0xFBF1EA
        case .paleGray: 0xF2F2F4
        case .custom: customRGB
        }
        if dark {
            // Presets are a restrained wash; custom colors retain a stronger tint in dark appearance.
            let tint = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            let base = NSColor.windowBackgroundColor
            return Color(nsColor: base.blended(withFraction: background == .custom ? 0.18 : 0.035, of: tint) ?? base)
        }
        let tint = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        return background == .custom ? Color(nsColor: tint)
            : Color(nsColor: NSColor.windowBackgroundColor.blended(withFraction: 0.42, of: tint) ?? tint)
    }

    static let sidebarIconColors: [String: Color] = [
        "recent": .blue, "fileTransit": .cyan, "sharedFolder": .blue,
        "applications": .blue, "desktop": .blue, "downloads": .blue, "documents": .blue,
        "folder": .blue, "home": .blue, "iCloudDrive": .cyan, "thisMac": .gray, "airDrop": .blue, "trash": .gray,
    ]

    static func finderTagColor(_ labelNumber: Int?) -> NSColor? {
        switch labelNumber {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
