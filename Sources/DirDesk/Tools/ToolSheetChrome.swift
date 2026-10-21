import AppKit
import DirDeskCore
import SwiftUI

/// Size of every tool options sheet (the reference shows one fixed size for all tools).
enum ToolSheetMetrics {
    static let size = NSSize(width: 760, height: 680)
    static let horizontalPadding: CGFloat = 28
    /// Width of each of the two side-by-side preview boxes.
    static let previewWidth: CGFloat = 330
}

/// Header, content area and footer shared by every tool sheet: the tool's icon, title and the selected
/// file names, a round close button, then the options, then Cancel on the left and the primary action on
/// the right. Escape cancels, Return runs.
struct ToolSheetScaffold<Content: View>: View {
    let tool: BuiltInToolID
    let subtitle: String
    let problem: String?
    let primaryTitle: String
    let canRun: Bool
    let secondaryTitle: String?
    let canRunSecondary: Bool
    let onCancel: () -> Void
    let onSecondary: () -> Void
    let onRun: () -> Void
    let content: Content

    init(tool: BuiltInToolID, subtitle: String, problem: String? = nil, primaryTitle: String? = nil, canRun: Bool = true,
         secondaryTitle: String? = nil, canRunSecondary: Bool = true, onSecondary: @escaping () -> Void = {},
         onCancel: @escaping () -> Void, onRun: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.tool = tool
        self.subtitle = subtitle
        self.problem = problem
        self.primaryTitle = primaryTitle ?? L("Run Tool")
        self.canRun = canRun
        self.secondaryTitle = secondaryTitle
        self.canRunSecondary = canRunSecondary
        self.onSecondary = onSecondary
        self.onCancel = onCancel
        self.onRun = onRun
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolSheetHeader(tool: tool, subtitle: subtitle, onClose: onCancel)
            Divider()
            content
                .font(.system(size: 13))
                .padding(.horizontal, ToolSheetMetrics.horizontalPadding)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack(alignment: .center, spacing: 8) {
                Button(L("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("BuiltInTool.Cancel")
                Spacer(minLength: 12)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("BuiltInTool.Problem")
                }
                if let secondaryTitle {
                    Button(secondaryTitle, action: onSecondary)
                        .disabled(!canRunSecondary)
                        .accessibilityIdentifier("BuiltInTool.Secondary")
                }
                Button(primaryTitle, action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
                    .accessibilityIdentifier("BuiltInTool.Run")
            }
            .padding(.horizontal, ToolSheetMetrics.horizontalPadding)
            .frame(height: 52)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BuiltInTool.\(tool.rawValue)")
    }
}

/// Icon tile, tool title, the selected file names and the round close button.
struct ToolSheetHeader: View {
    let tool: BuiltInToolID
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: BuiltInToolSupport.symbol(tool))
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(BuiltInToolSupport.title(tool))
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("BuiltInTool.Subtitle")
            }
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.035)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.11), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("Close"))
            .accessibilityLabel(L("Close"))
            .accessibilityIdentifier("BuiltInTool.Close")
        }
        .padding(.horizontal, ToolSheetMetrics.horizontalPadding)
        .padding(.top, 22)
        .padding(.bottom, 22)
    }

    /// "a.png, b.png, c.png": the selected file names in selection order.
    static func names(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: ", ")
    }
}

/// "Title [control]" on one line, the control at its natural width.
struct ToolFormRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).lineLimit(1).fixedSize()
            control
            Spacer(minLength: 0)
        }
    }
}

/// Small secondary help text under the options.
struct ToolCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small bold title above a preview box or a list ("Original", "Live Preview").
struct ToolSectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .lineLimit(1)
    }
}

/// "Title ——slider—— value" row; the slider takes the remaining width.
struct ToolSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let valueText: String
    var valueWidth: CGFloat = 48

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).fixedSize()
            if let step {
                Slider(value: $value, in: range, step: step).labelsHidden()
            } else {
                Slider(value: $value, in: range).labelsHidden()
            }
            Text(valueText)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: valueWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A rounded preview box. `.native` shows the source edge to edge on the sheet background; `.result`
/// draws a faint fill and keeps a small margin around the image, like the reference.
struct ToolPreviewBox<Content: View>: View {
    enum Style {
        case native, result
    }

    let style: Style
    let content: Content

    init(_ style: Style, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(style == .result ? Color.primary.opacity(0.035) : Color.clear)
            content
                .padding(style == .result ? 6 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.11), lineWidth: 1))
    }
}

/// A bitmap aspect-fit inside its box, or a spinner / message while there is none.
struct ToolImagePreview: View {
    let image: CGImage?
    var isLoading = false
    var message: String?
    var accessibilityLabel: String?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(CGSize(width: image.width, height: image.height), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel(accessibilityLabel ?? "")
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Estimated output: …" line with its loading and failure states.
enum ToolEstimate: Equatable {
    case idle
    case estimating
    case ready(String)
    case unavailable(String)
}

struct ToolEstimateLabel: View {
    let estimate: ToolEstimate

    var body: some View {
        HStack(spacing: 6) {
            switch estimate {
            case .idle:
                EmptyView()
            case .estimating:
                ProgressView().controlSize(.mini)
                Text(L("Estimating output size…")).foregroundStyle(.secondary)
            case .ready(let text):
                Text(text).fontWeight(.semibold)
            case .unavailable(let reason):
                Text(LF("Estimate unavailable: %@", reason)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BuiltInTool.Estimate")
    }
}

/// An integer text field that commits as you type and shows grouping separators ("1,600").
struct ToolIntegerField: View {
    @Binding var value: Int
    var width: CGFloat = 70
    @State private var text = ""
    @FocusState private var focused: Bool

    static func format(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Localizer.shared.locale))
    }

    /// Digits with grouping separators (comma, period, spaces, apostrophe) removed; nil when not an integer.
    static func parse(_ text: String) -> Int? {
        let ignored: Set<Character> = [",", ".", "'", "\u{00A0}", "\u{202F}", "，"]
        return Int(String(text.filter { !$0.isWhitespace && !ignored.contains($0) }))
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: width)
            .focused($focused)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { _, newValue in
                if Self.parse(text) != newValue { text = Self.format(newValue) }
            }
            .onChange(of: text) { _, newText in
                if let parsed = Self.parse(newText), parsed != value { value = parsed }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = Self.format(value) }
            }
    }
}
