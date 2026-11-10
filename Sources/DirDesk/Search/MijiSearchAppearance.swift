import AppKit
import SwiftUI
import MijiCore

/// Panel appearance. Follows the system by default; the earlier dark glass stays selectable.
enum MijiSearchAppearance: String, CaseIterable, Identifiable {
    case system, darkGlass
    var id: Self { self }
    var title: String { self == .darkGlass ? "深色毛玻璃" : "跟随系统" }
    static let storageKey = "dirdesk-miji-search-appearance-v1"
    var windowAppearance: NSAppearance? { self == .darkGlass ? NSAppearance(named: .darkAqua) : nil }
}

/// Layout tokens. One alignment line (`content`) runs through the magnifier, scope labels,
/// row icons and footer text; fills and highlights sit on the `edge` line, so their corners
/// stay concentric with the panel.
enum MijiPanelMetrics {
    static let radius: CGFloat = 22
    static let edge: CGFloat = 10
    static let content: CGFloat = 20
    /// Empty panel: search + footer = MijiSearchModel's 100 pt.
    static let searchHeight: CGFloat = 66
    static let footerHeight: CGFloat = 34
    /// Expanded list: search + scope + footer + two hairlines + 8 + 59n = MijiSearchModel's 150 + 59n.
    static let scopeHeight: CGFloat = 40
    static let rowHeight: CGFloat = 57
    static let rowSpacing: CGFloat = 2
    static let listInset: CGFloat = 5
    static let rowRadius: CGFloat = radius - edge
    static let pillHeight: CGFloat = 26
    static let metaWidth: CGFloat = 84
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

/// The search panel surface: Liquid Glass on macOS 26+, the system popover material on
/// earlier versions, and an opaque window background when transparency is reduced.
struct MijiPanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// QA can preview the macOS 14–15 material on a newer system; release builds never set this.
    static let usesGlass: Bool = {
        let env = ProcessInfo.processInfo.environment
        guard #available(macOS 26, *) else { return false }
        return !(env["MIJI_UI_TESTING"] == "1" && env["MIJI_UI_LEGACY_MATERIAL"] == "1")
    }()

    func body(content: Content) -> some View {
        let shape = MijiPanelMetrics.shape
        if reduceTransparency {
            content.clipShape(shape).background(Color(nsColor: .windowBackgroundColor), in: shape).overlay(rim(shape, strong: true))
        } else if Self.usesGlass, #available(macOS 26, *) {
            content.clipShape(shape).glassEffect(.regular, in: shape)
                .overlay { if contrast == .increased { rim(shape, strong: true) } }
        } else {
            content.clipShape(shape).background { MijiSearchMaterial() }.overlay(rim(shape, strong: contrast == .increased))
        }
    }

    private func rim(_ shape: RoundedRectangle, strong: Bool) -> some View {
        shape.strokeBorder((scheme == .dark ? Color.white : Color.black).opacity(strong ? 0.38 : (scheme == .dark ? 0.14 : 0.08)),
                           lineWidth: strong ? 1 : 0.5)
    }
}

/// Behind-window popover material for macOS 14–15. Its appearance follows the window, so the
/// dark-glass option and the system appearance render through the same native material.
struct MijiSearchMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .popover
        view.state = .active
        view.maskImage = Self.mask
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded mask keeps the window-server blur inside the panel corners.
    private static let mask: NSImage = {
        let r = MijiPanelMetrics.radius, edge = r * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }()
}

/// Quiet icon button: secondary glyph in a 26 pt hit area with a hover and press fill.
struct MijiSearchIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconButton(configuration: configuration) }
    private struct IconButton: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Filename emphasis in the style of Xcode's Open Quickly: matched characters turn semibold
/// and keep the label colour, so the highlight stays legible on glass and on a selected row.
func mijiHighlightedFilename(_ name: String, query: String, selected: Bool, size: CGFloat = 14) -> AttributedString {
    emphasized(name, terms: MijiPreviewResolver.terms(in: query), size: size, limit: 40, matchColor: nil)
}

/// Snippet emphasis for result rows: matched terms take the primary label colour and a
/// semibold weight against secondary text.
func mijiHighlightedSnippet(_ text: String, query: String, selected: Bool, size: CGFloat = 11) -> AttributedString {
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

enum MijiResultFormat {
    /// Finder-style relative dates: time today, 昨天, month and day this year, numeric date before.
    static func date(_ seconds: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: seconds), calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return date.formatted(.dateTime.month().day()) }
        return date.formatted(.dateTime.year().month(.defaultDigits).day(.defaultDigits))
    }
    static func size(_ hit: SearchHit) -> String {
        switch hit.file.kind {
        case .folder: return "文件夹"
        case .application where hit.file.size == 0: return "应用"
        default: return ByteCountFormatter.string(fromByteCount: hit.file.size, countStyle: .file)
        }
    }
}
