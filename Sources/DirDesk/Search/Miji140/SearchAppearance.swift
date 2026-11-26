import AppKit
import SwiftUI
import MijiCore

/// Panel appearance. Follows the system by default; dark glass stays selectable.
enum SearchAppearance: String, CaseIterable, Identifiable {
    case system, darkGlass
    var id: Self { self }
    var title: String { self == .darkGlass ? "深色毛玻璃" : "跟随系统" }
    static let storageKey = MijiSearchAppearance.storageKey
    var windowAppearance: NSAppearance? { self == .darkGlass ? NSAppearance(named: .darkAqua) : nil }
}

/// Window and layout metrics for the floating search modes.
enum PanelMetrics {
    static let compactWidth: CGFloat = 640
    static let fileWidth: CGFloat = 640
    static let appWidth: CGFloat = 844
    static let clipboardWidth: CGFloat = 640
    static let previewWidth: CGFloat = 1050
    static let appHeight: CGFloat = 577
    static let fileHeight: CGFloat = 547
    static let clipboardHeight: CGFloat = 547

    static let edge: CGFloat = 12
    static let content: CGFloat = 20
    static let searchHeight: CGFloat = 56
    static let expandedHeaderHeight: CGFloat = 58
    static let footerHeight: CGFloat = 30
    static let scopeHeight: CGFloat = 40
    static let rowHeight: CGFloat = 50
    static let rowSpacing: CGFloat = 2
    static let listInset: CGFloat = 6
    static let rowRadius: CGFloat = 10
    static let controlHeight: CGFloat = 26

    static let entryDiameter: CGFloat = 54
    static let entrySpacing: CGFloat = 10
    static let dockWidth: CGFloat = entryDiameter * 3 + entrySpacing * 2
    static let dockGap: CGFloat = 10
    static let compactFieldWidth: CGFloat = compactWidth - dockWidth - dockGap

    static let panelRadius: CGFloat = 26
    static let capsuleRadius: CGFloat = searchHeight / 2
}

enum SearchPalette {
    static func accent(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .controlAccentColor)
    }

    static func selectedRow(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .controlAccentColor)
    }

    static func chipFill(_ scheme: ColorScheme, hovered: Bool, selected: Bool) -> Color {
        if selected {
            return scheme == .dark ? Color.white.opacity(0.28) : Color(nsColor: .controlAccentColor).opacity(0.18)
        }
        if scheme == .dark {
            return Color.white.opacity(hovered ? 0.17 : 0.105)
        } else {
            return Color.black.opacity(hovered ? 0.11 : 0.065)
        }
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
    }
}

enum SearchSurface: Hashable {
    case field, panel, dock

    var radius: CGFloat {
        switch self {
        case .field: return PanelMetrics.capsuleRadius
        case .panel: return PanelMetrics.panelRadius
        case .dock: return PanelMetrics.entryDiameter / 2
        }
    }

    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

/// Native macOS 26+ Liquid Glass surface with a crisp macOS 14–15 NSVisualEffectView fallback.
struct SearchGlass: View {
    let surface: SearchSurface
    var interactive: Bool = false
    var tintedBackdrop: Bool = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = scheme == .dark
        let strongerRim = reduceTransparency || contrast == .increased
        let shape = surface.shape

        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                    .overlay {
                        shape.strokeBorder(Color.primary.opacity(strongerRim ? 0.42 : 0.20), lineWidth: 1)
                    }
            } else if #available(macOS 26.0, *) {
                nativeLiquidGlass(dark: dark, strongerRim: strongerRim)
            } else {
                legacyBlurGlass(shape: shape, dark: dark, strongerRim: strongerRim)
            }
        }
        .overlay {
            if tintedBackdrop && !reduceTransparency {
                shape.fill(LinearGradient(colors: [
                    Color(white: dark ? 0.20 : 0.98).opacity(dark ? 0.50 : 0.62),
                    Color(white: dark ? 0.12 : 0.90).opacity(dark ? 0.64 : 0.72)
                ], startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(dark ? 0.24 : 0.75), location: 0),
                        .init(color: .white.opacity(dark ? 0.05 : 0.15), location: 0.48),
                        .init(color: (dark ? Color.white : .black).opacity(dark ? 0.12 : 0.16), location: 1)
                    ], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeLiquidGlass(dark: Bool, strongerRim: Bool) -> some View {
        let glass: Glass = interactive ? .regular.interactive() : .regular
        switch surface {
        case .field:
            Capsule()
                .fill(.clear)
                .glassEffect(glass, in: Capsule())
                .overlay {
                    if strongerRim {
                        Capsule().strokeBorder(Color.white.opacity(dark ? 0.34 : 0.55), lineWidth: 1)
                    }
                }
        case .dock:
            Circle()
                .fill(.clear)
                .glassEffect(glass, in: Circle())
                .overlay {
                    if strongerRim {
                        Circle().strokeBorder(Color.white.opacity(dark ? 0.34 : 0.55), lineWidth: 1)
                    }
                }
        case .panel:
            let shape = RoundedRectangle(cornerRadius: PanelMetrics.panelRadius, style: .continuous)
            shape
                .fill(.clear)
                .glassEffect(glass, in: shape)
                .overlay {
                    if strongerRim {
                        shape.strokeBorder(Color.white.opacity(dark ? 0.34 : 0.55), lineWidth: 1)
                    }
                }
        }
    }

    private func legacyBlurGlass(shape: RoundedRectangle, dark: Bool, strongerRim: Bool) -> some View {
        ZStack {
            LegacySearchMaterial(surface: surface)
            if dark {
                shape.fill(LinearGradient(colors: [
                    Color.white.opacity(surface == .dock ? 0.08 : 0.07),
                    Color.white.opacity(0.03)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                shape.fill(.white.opacity(0.18))
            }
            shape.strokeBorder(
                LinearGradient(colors: [
                    .white.opacity(strongerRim ? 0.57 : dark ? 0.24 : 0.62),
                    (dark ? Color.white : .black).opacity(strongerRim ? 0.32 : 0.13)
                ], startPoint: .top, endPoint: .bottom),
                lineWidth: strongerRim ? 1 : 0.75
            )
        }
    }
}

private struct LegacySearchMaterial: NSViewRepresentable {
    let surface: SearchSurface

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.maskImage = Self.masks[surface]
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static let masks = Dictionary(uniqueKeysWithValues: [SearchSurface.field, .panel, .dock].map { surface in
        let cap = ceil(surface.radius * 1.5)
        let edge = cap * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(surface.shape.path(in: rect).cgPath)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return (surface, image)
    })
}

/// Shared by the category buttons and the search field.
struct SearchModeGlyph: View {
    let mode: SearchMode
    var size: CGFloat = 21
    var weight: Font.Weight = .regular

    var body: some View {
        // The square grid is optically narrower than the folder at equal point sizes.
        Image(systemName: mode.symbol)
            .font(.system(size: mode == .apps ? size + 1 : size, weight: weight))
    }
}

/// Quiet icon button with a consistent hit area and subtle hover/press fill.
struct SearchIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconButton(configuration: configuration) }
    private struct IconButton: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .background(Circle()
                    .fill(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.15 : hovering ? 0.08 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Spotlight's signature translucent capsule chip for category & file-type filters.
struct SpotlightChipStyle: ButtonStyle {
    var selected = false
    var height: CGFloat = 26
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, selected: selected, height: height,
             fontSize: fontSize, horizontalPadding: horizontalPadding)
    }

    private struct Chip: View {
        let configuration: Configuration
        let selected: Bool
        let height: CGFloat
        let fontSize: CGFloat
        let horizontalPadding: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        @State private var hovered = false

        var body: some View {
            let fill = SearchPalette.chipFill(scheme, hovered: hovered || configuration.isPressed, selected: selected)
            let foreground: Color = selected
                ? (scheme == .dark ? .white : Color(nsColor: .controlAccentColor))
                : Color.primary.opacity(hovered ? 0.96 : 0.84)
            configuration.label
                .font(.system(size: fontSize, weight: selected ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(Capsule().fill(fill))
                .overlay {
                    if selected && scheme == .dark {
                        Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                    }
                }
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}

/// Compact pill control used in preview pane actions and menus.
struct SearchControlStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        Control(configuration: configuration, emphasized: emphasized)
    }

    private struct Control: View {
        let configuration: Configuration
        let emphasized: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let shape = Capsule()
            let accent = SearchPalette.accent(scheme)
            let fill = emphasized ? accent.opacity(hovered ? 0.95 : 0.85)
                                  : Color.primary.opacity(configuration.isPressed ? 0.18 : hovered ? 0.14 : 0.095)
            configuration.label
                .font(.system(size: 12, weight: emphasized ? .semibold : .medium))
                .foregroundStyle(emphasized ? Color.white : Color.primary.opacity(0.88))
                .padding(.horizontal, 11)
                .frame(height: PanelMetrics.controlHeight)
                .background(shape.fill(fill))
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}

/// Filename emphasis: matched characters turn semibold and keep the label colour.
func highlightedFilename(_ name: String, query: String, selected: Bool, size: CGFloat = 13.5) -> AttributedString {
    emphasized(name, terms: MijiPreviewResolver.terms(in: query), size: size, limit: 40, matchColor: nil)
}

/// Snippet emphasis for result rows: matched terms take the primary label colour.
func highlightedSnippet(_ text: String, query: String, selected: Bool, size: CGFloat = 11.5) -> AttributedString {
    emphasized(text, terms: MijiPreviewResolver.terms(in: query), size: size, limit: 20, matchColor: selected ? nil : .primary)
}

private func emphasized(_ text: String, terms: [String], size: CGFloat, limit: Int, matchColor: Color?) -> AttributedString {
    var result = AttributedString(text)
    for term in terms where !term.isEmpty {
        var start = text.startIndex
        for _ in 0..<limit {
            guard start < text.endIndex,
                  let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex),
                  let mapped = Range(range, in: result) else { break }
            result[mapped].font = .system(size: size, weight: .semibold)
            if let matchColor { result[mapped].foregroundColor = matchColor }
            start = range.upperBound
        }
    }
    return result
}

enum ResultFormat {
    /// Spotlight-style Chinese relative timestamps: "今天 16:26", "昨天 23:47", or "2026/10/19 14:13".
    static func date(_ seconds: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: seconds), calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month().day()) + " \(time)"
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day(.defaultDigits))
    }

    static func size(_ hit: SearchHit) -> String {
        switch hit.file.kind {
        case .folder: return "文件夹"
        case .application where hit.file.size == 0: return "应用程序"
        default: return ByteCountFormatter.string(fromByteCount: hit.file.size, countStyle: .file)
        }
    }

    static func kindLabel(_ hit: SearchHit) -> String {
        let ext = hit.file.fileExtension.lowercased()
        switch ext {
        case "md", "markdown": return "Markdown"
        case "pdf": return "PDF 文稿"
        case "png": return "PNG 图像"
        case "jpg", "jpeg": return "JPEG 图像"
        case "heic": return "HEIC 图像"
        case "webp": return "WebP 图像"
        case "svg": return "SVG 图像"
        case "dmg": return "磁盘映像"
        case "zip": return "ZIP 归档"
        case "tex": return "TeX 文件"
        case "swift": return "Swift 源码"
        case "py": return "Python 脚本"
        case "ts", "tsx": return "TypeScript"
        case "js", "jsx": return "JavaScript"
        case "json": return "JSON"
        case "txt": return "纯文本文稿"
        case "docx", "doc": return "Word 文稿"
        case "xlsx", "xls": return "Excel 表格"
        case "pptx", "ppt": return "演示文稿"
        case "mp4", "mov": return "影片"
        case "mp3", "wav", "m4a", "flac": return "音频"
        default: return hit.file.kind.title
        }
    }
}
