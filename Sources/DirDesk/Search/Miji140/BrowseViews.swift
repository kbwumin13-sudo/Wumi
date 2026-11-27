import ImageIO
import SwiftUI

/// Spotlight-style circular Liquid Glass category buttons that emerge from the right of the search pill.
struct SearchEntryDock: View {
    let revealed: Bool
    @Binding var hoveredMode: SearchMode?
    let namespace: Namespace.ID
    let select: (SearchMode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PanelMetrics.entrySpacing) {
            ForEach(Array(SearchMode.categories.enumerated()), id: \.element) { index, mode in
                entryCircle(mode: mode, index: index)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func entryCircle(mode: SearchMode, index: Int) -> some View {
        let button = Button { select(mode) } label: {
            SearchModeGlyph(mode: mode, size: 21, weight: .regular)
                .frame(width: PanelMetrics.entryDiameter, height: PanelMetrics.entryDiameter)
        }
        .buttonStyle(CircularEntryButtonStyle(mode: mode, hoveredMode: $hoveredMode))
        .accessibilityLabel(mode.shortTitle)
        .help("\(mode.title) · ⌘\(mode.key)")

        let styled = Group {
            if #available(macOS 26.0, *) {
                button
                    .glassEffect(.regular.interactive(), in: Circle())
                    .glassEffectID(mode, in: namespace)
            } else {
                button
                    .background { SearchGlass(surface: .dock, interactive: true) }
            }
        }

        styled
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed || reduceMotion ? 1 : 0.72)
            .blur(radius: revealed || reduceMotion ? 0 : 2.5)
            .offset(x: revealed || reduceMotion ? 0 : -14)
            .animation(
                reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78)
                    .delay(revealed ? 0.028 * Double(index) : 0),
                value: revealed
            )
    }
}

private struct CircularEntryButtonStyle: ButtonStyle {
    let mode: SearchMode
    @Binding var hoveredMode: SearchMode?

    func makeBody(configuration: Configuration) -> some View {
        EntryButton(configuration: configuration, mode: mode, hoveredMode: $hoveredMode)
    }

    private struct EntryButton: View {
        let configuration: Configuration
        let mode: SearchMode
        @Binding var hoveredMode: SearchMode?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color.primary.opacity(hovering || configuration.isPressed ? 0.96 : 0.78))
                .background {
                    Circle()
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0))
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { inside in
                    hovering = inside
                    if inside {
                        hoveredMode = mode
                    } else if hoveredMode == mode {
                        hoveredMode = nil
                    }
                }
        }
    }
}

/// Seven-column applications grid with a separate row for running apps.
struct BrowseAppsView: View {
    @ObservedObject var browse: BrowseContent
    let query: String
    let width: CGFloat
    let open: (InstalledApp) -> Void
    let reveal: (InstalledApp) -> Void
    @Environment(\.colorScheme) private var scheme

    private let gridInset: CGFloat = 22
    private let columnSpacing: CGFloat = 12
    private var iconSize: CGFloat {
        let columns = CGFloat(InstalledApp.gridColumns)
        let cellWidth = (width - 2 * gridInset - (columns - 1) * columnSpacing) / columns
        return min(74, max(36, cellWidth - 6))
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryBar
            let sections = browse.appSections(query: query)
            if sections.running.isEmpty && sections.others.isEmpty {
                ContentUnavailableView(browse.loadingApps ? "正在读取应用程序…" : "没有匹配的应用程序",
                                       systemImage: SearchMode.apps.symbol)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if !sections.running.isEmpty {
                                appSection(sections.running)
                                    .accessibilityLabel("最近使用")
                                if !sections.others.isEmpty {
                                    Rectangle()
                                        .fill(SearchPalette.hairline(scheme))
                                        .frame(height: 1)
                                        .padding(.horizontal, 4)
                                }
                            }
                            if !sections.others.isEmpty {
                                appSection(sections.others)
                            }
                        }
                        .padding(.horizontal, gridInset)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                    }
                    .onChange(of: browse.appSelection) { if let id = browse.appSelection { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private var categoryBar: some View {
        HStack(spacing: 7) {
            ForEach(browse.appCategories) { category in
                let selected = browse.appCategory == category
                Button {
                    browse.appCategory = selected ? nil : category
                } label: {
                    Text(category.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SpotlightChipStyle(selected: selected, height: 26, fontSize: 12, horizontalPadding: 8))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, gridInset)
        .frame(height: PanelMetrics.scopeHeight)
    }

    private func appSection(_ apps: [InstalledApp]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: InstalledApp.gridColumns), spacing: 14) {
            ForEach(apps) { app in
                let selected = browse.appSelection == app.id
                AppIconTile(app: app, selected: selected, iconSize: iconSize)
                    .onTapGesture {
                        browse.appSelection = app.id
                        open(app)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { browse.appSelection = app.id; open(app) }
                    .contextMenu {
                        Button("打开") { open(app) }
                        Button("在 Finder 中显示") { reveal(app) }
                    }
                    .help(app.title)
                    .id(app.id)
            }
        }
    }

    private struct AppIconTile: View {
        let app: InstalledApp
        let selected: Bool
        let iconSize: CGFloat
        @State private var hovering = false
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            VStack(spacing: 6) {
                let outline = RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                Image(nsImage: BrowseAppIcon.icon(for: app.url))
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .padding(3)
                    .background {
                        if hovering && !selected {
                            outline.fill(Color.primary.opacity(0.08))
                        }
                    }
                    .overlay {
                        if selected {
                            outline.strokeBorder(SearchPalette.accent(scheme), lineWidth: 2.5)
                        }
                    }
                    .accessibilityHidden(true)

                Text(app.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(selected || hovering ? 0.98 : 0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }
}

/// Spotlight-matched Clipboard view: clean empty state ("无项目"), subtle controls, blue row selection.
struct BrowseClipboardView: View {
    @ObservedObject var browse: BrowseContent
    let query: String
    let copy: (ClipboardEntry) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let entries = browse.visibleClipboard(query: query)
        VStack(spacing: 0) {
            if browse.recordingClipboard || !browse.history.isEmpty {
                HStack(spacing: 10) {
                    Toggle("记录复制历史", isOn: Binding(get: { browse.recordingClipboard }, set: { browse.setClipboardRecording($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("记录复制历史")
                    Spacer()
                    if !browse.history.isEmpty {
                        Button("清空历史") { browse.clearClipboardHistory() }
                            .buttonStyle(SpotlightChipStyle(selected: false, height: 24, fontSize: 11.5, horizontalPadding: 10))
                    }
                }
                .padding(.horizontal, PanelMetrics.content)
                .frame(height: 36)
                Rectangle().fill(SearchPalette.hairline(scheme)).frame(height: 0.5).padding(.horizontal, PanelMetrics.content)
            }

            if entries.isEmpty {
                VStack(spacing: 12) {
                    Text(query.isEmpty ? "无项目" : "没有匹配的记录")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.76))
                    if query.isEmpty && !browse.recordingClipboard {
                        Button("开启剪贴板历史") { browse.setClipboardRecording(true) }
                            .buttonStyle(SpotlightChipStyle(selected: false, height: 28, fontSize: 12.5, horizontalPadding: 14))
                        Text("开启后记录新复制的文字、图片和文件，退出觅迹时自动清除")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else if query.isEmpty {
                        Text("复制的文字、图片和文件会显示在这里")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(entries) { entry in
                                clipboardRow(entry).id(entry.id)
                            }
                        }
                        .padding(.horizontal, PanelMetrics.edge)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: browse.clipboardSelection) { if let id = browse.clipboardSelection { proxy.scrollTo(id) } }
                }

                if let selected = entries.first(where: { $0.id == browse.clipboardSelection }),
                   case .image(let data, _) = selected.payload {
                    ClipboardImagePreview(data: data)
                        .id(selected.id)
                        .padding(.horizontal, PanelMetrics.edge)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func clipboardRow(_ entry: ClipboardEntry) -> some View {
        let selected = browse.clipboardSelection == entry.id
        return HStack(spacing: 12) {
            Image(systemName: entry.payload.symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(entry.payload.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Color.white.opacity(0.82) : Color.secondary)
                .monospacedDigit()
            Button { copy(entry) } label: {
                Image(systemName: "document.on.document")
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            }
            .buttonStyle(SearchIconButtonStyle())
            .help("重新复制")
            .accessibilityLabel("重新复制")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous)
                .fill(selected ? SearchPalette.selectedRow(scheme) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { copy(entry) }
        .onTapGesture { browse.clipboardSelection = entry.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { copy(entry) }
        .accessibilityActions {
            if case .image = entry.payload {
                Button("预览图片") { browse.clipboardSelection = entry.id }
            }
        }
    }
}

struct ClipboardImagePreview: View {
    let data: Data
    @State private var state = State.loading

    private enum State {
        case loading, ready(CGImage), unavailable
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PanelMetrics.rowRadius)
                .fill(Color.primary.opacity(0.055))
                .accessibilityHidden(true)
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .ready(let image):
                Image(image, scale: 1, label: Text("剪贴板图片预览"))
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            case .unavailable:
                Text("无法预览这张图片")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 246)
        .task {
            let image = await Task.detached(priority: .userInitiated) { Self.makeImage(from: data) }.value
            guard !Task.isCancelled else { return }
            state = image.map(State.ready) ?? .unavailable
        }
    }

    nonisolated static func makeImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
