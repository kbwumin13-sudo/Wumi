import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MijiCore

struct Miji140SearchView: View {
    @ObservedObject var model: MijiSearchModel
    var onSettings: () -> Void
    var onAdvanced: () -> Void
    var onApplication: (InstalledApp) -> Void
    var onClipboardEntry: (ClipboardEntry) -> Void
    var shortcutLabel: String
    @FocusState private var searchFocused: Bool
    @Namespace private var glassNamespace
    @State private var showHelp = false
    @State private var dockVisible = false
    @State private var hoveredEntryMode: SearchMode?
    @State private var appHeaderSelection: URL?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SearchAppearance.storageKey) private var appearance = SearchAppearance.system

    private var expanded: Bool { model.mode != .all || !model.query.isEmpty }
    private var currentResults: Bool { model.displayedSnapshot != nil && model.displayedSnapshot == model.currentSnapshot }
    private let browseKinds: [FileKind] = [.folder, .document, .image, .video, .audio, .archive, .code]
    private let fileKinds: [FileKind] = [.folder, .application, .document, .image, .video, .audio, .code, .archive]

    private struct DockPresentation: Equatable {
        let activation: UUID
        let visible: Bool
        let compact: Bool
        let reduceMotion: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            panelContents(in: geometry.size)
        }
        .tint(SearchPalette.accent(scheme))
        .background(SearchWindowConfiguration(appearance: appearance))
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearch) {
            restoreQueryDisplay()
            searchFocused = true
        }
        .onChange(of: expanded) {
            if expanded {
                dockVisible = false
                hoveredEntryMode = nil
            }
        }
        .onReceive(model.browse.$appSelection) { appHeaderSelection = $0 }
        .task(id: DockPresentation(activation: model.panelActivation, visible: model.searchPresented,
                                   compact: !expanded, reduceMotion: reduceMotion)) {
            await evolveCompactDock()
        }
        .alert("觅迹", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    /// Spotlight's progressive evolution: opens as a lone search pill, then smoothly
    /// evolves into the shorter pill + three circular Liquid Glass category buttons.
    private func evolveCompactDock() async {
        guard model.searchPresented && !expanded else {
            dockVisible = false
            return
        }
        if reduceMotion {
            dockVisible = true
            return
        }
        dockVisible = false
        do { try await Task.sleep(for: .milliseconds(260)) }
        catch { return }
        guard !Task.isCancelled, model.searchPresented, !expanded else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            dockVisible = true
        }
    }

    private func revealDockImmediately() {
        guard model.searchPresented, !expanded, !dockVisible else { return }
        if reduceMotion {
            dockVisible = true
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                dockVisible = true
            }
        }
    }

    private func panelContents(in size: CGSize) -> some View {
        let opening = reveal(size.height, from: PanelMetrics.searchHeight + 4, to: 132)
        let bodyOpacity = expanded ? reveal(size.height, from: PanelMetrics.searchHeight + 10, to: 150) : 0
        let cornerRadius = PanelMetrics.capsuleRadius
            + CGFloat(opening) * (PanelMetrics.panelRadius - PanelMetrics.capsuleRadius)

        return ZStack(alignment: .topLeading) {
            if opening > 0.01 {
                SearchGlass(surface: .panel, tintedBackdrop: model.mode == .apps)
                    .opacity(opening)
            }

            VStack(spacing: 0) {
                searchHeader(width: size.width, opening: opening)

                if expanded {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(SearchPalette.hairline(scheme))
                            .frame(height: 0.5)
                            .padding(.horizontal, PanelMetrics.content)
                        modeContent(in: size)
                        if model.mode.searchesIndex && !model.browsingRecent {
                            Rectangle()
                                .fill(SearchPalette.hairline(scheme))
                                .frame(height: 0.5)
                                .padding(.horizontal, PanelMetrics.content)
                            footer
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .opacity(bodyOpacity)
                    .transition(.opacity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: opening >= 0.01 ? cornerRadius : 0, style: .continuous))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func modeContent(in size: CGSize) -> some View {
        switch model.mode {
        case .apps:
            BrowseAppsView(browse: model.browse, query: model.query, width: size.width,
                           open: { onApplication($0) },
                           reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) })
        case .clipboard:
            BrowseClipboardView(browse: model.browse, query: model.query,
                                copy: { onClipboardEntry($0) })
        case .all, .files:
            fileResults(in: size)
        }
    }

    private func fileResults(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            scopeBar
            if !model.browsingRecent && model.mode != .files {
                Rectangle()
                    .fill(SearchPalette.hairline(scheme))
                    .frame(height: 0.5)
                    .padding(.horizontal, PanelMetrics.content)
            }
            HStack(spacing: 0) {
                if model.searchPresented {
                    results.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.previewVisible {
                    Rectangle()
                        .fill(SearchPalette.hairline(scheme))
                        .frame(width: 0.5)
                        .padding(.vertical, 10)
                    ResultPreviewPane(model: model)
                        .frame(width: model.browsingRecent ? min(MijiSearchModel.previewWidth, size.width * 0.42) : MijiSearchModel.previewWidth)
                        .opacity(model.browsingRecent ? 1 : reveal(size.width, from: 820, to: 1010))
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipped()
        }
    }

    private func reveal(_ size: CGFloat, from start: CGFloat, to end: CGFloat) -> Double {
        let t = Double(min(1, max(0, (size - start) / (end - start))))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Search Header & Morphing Liquid Glass Dock

    @ViewBuilder
    private func searchHeader(width: CGFloat, opening: Double) -> some View {
        let showDock = !expanded && dockVisible && opening < 0.05
        let dockSpace = showDock ? PanelMetrics.dockWidth + PanelMetrics.dockGap : 0
        let headerHeight = expanded ? PanelMetrics.expandedHeaderHeight : PanelMetrics.searchHeight

        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 18) {
                headerRow(width: width, height: headerHeight, opening: opening, showDock: showDock, dockSpace: dockSpace)
            }
        } else {
            headerRow(width: width, height: headerHeight, opening: opening, showDock: showDock, dockSpace: dockSpace)
        }
    }

    private func headerRow(width: CGFloat, height: CGFloat, opening: Double, showDock: Bool, dockSpace: CGFloat) -> some View {
        let fieldWidth = max(0, width - dockSpace)
        return HStack(spacing: showDock ? PanelMetrics.dockGap : 0) {
            searchFieldSurface(width: fieldWidth, height: height, opening: opening, showDock: showDock)

            if !expanded && showDock {
                SearchEntryDock(revealed: true, hoveredMode: $hoveredEntryMode, namespace: glassNamespace, select: model.selectMode)
                    .transition(.scale(scale: 0.76, anchor: .leading).combined(with: .opacity))
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside && !expanded { revealDockImmediately() }
        }
    }

    @ViewBuilder
    private func searchFieldSurface(width: CGFloat, height: CGFloat, opening: Double, showDock: Bool) -> some View {
        let content = searchField(showDock: showDock)
            .frame(width: width, height: height)
        if !expanded && opening < 0.05 {
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular, in: Capsule())
                    .glassEffectID("search-pill", in: glassNamespace)
                    .contextMenu { compactContextMenu }
            } else {
                content
                    .background { SearchGlass(surface: .field) }
                    .contextMenu { compactContextMenu }
            }
        } else {
            content
                .background {
                    if opening < 0.98 {
                        SearchGlass(surface: .field).opacity(1 - opening)
                    }
                }
        }
    }

    private func restoreQueryDisplay() {
        appHeaderSelection = nil
        model.clearSelectionFeedback()
    }

    private struct HeaderSelection {
        let title: String
        let action: String
        let icon: NSImage?
    }

    private var selectionFeedback: HeaderSelection? {
        if model.mode == .apps, let selected = appHeaderSelection,
           let app = model.browse.apps.first(where: { $0.id == selected }) {
            return HeaderSelection(title: app.title, action: "打开", icon: BrowseAppIcon.icon(for: app.url))
        }
        if model.mode.searchesIndex, model.showsFileSelectionFeedback,
           currentResults, let hit = model.selected {
            return HeaderSelection(title: hit.file.name,
                                   action: hit.root.isOnline ? "打开" : "磁盘未连接",
                                   icon: FileIconCache.icon(hit))
        }
        return nil
    }

    // The same TextField remains first responder while the surrounding window changes shape.
    private func searchField(showDock: Bool) -> some View {
        let placeholder: String = {
            switch model.mode {
            case .all: return "觅迹搜索"
            case .apps: return "应用程序"
            case .files: return "文件"
            case .clipboard: return "剪贴板"
            }
        }()
        let selection = selectionFeedback

        return HStack(spacing: 12) {
            SearchModeGlyph(mode: model.mode, weight: .medium)
                .foregroundStyle(Color.primary.opacity(0.62))
                .frame(width: 24)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                TextField("", text: $model.query,
                          prompt: Text(placeholder).foregroundStyle(Color.primary.opacity(0.46)))
                    .accessibilityIdentifier("Wumi.MijiSearch.Field")
                    .font(.system(size: 24, weight: .regular))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .opacity(selection == nil ? 1 : 0.02)
                    .accessibilityLabel(model.mode == .all ? "搜索文件" : "搜索\(model.mode.title)")
                    .simultaneousGesture(TapGesture().onEnded { restoreQueryDisplay() })

                if let selection {
                    HStack(spacing: 0) {
                        Text(selection.title)
                            .font(.system(size: 23, weight: .regular))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(" — \(selection.action)")
                            .font(.system(size: 23, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.48))
                            .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !expanded && showDock {
                spotlightKeycapHint
                    .transition(.opacity)
            } else {
                if let icon = selection?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityHidden(true)
                }
                if !model.query.isEmpty {
                    Button { model.query = ""; model.focusSearch = UUID() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(SearchIconButtonStyle())
                    .help("清空搜索")
                    .accessibilityLabel("清空搜索")
                }
                if expanded {
                    settingsMenu
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, expanded ? 14 : 16)
    }

    /// Spotlight's subtle trailing keycap indicator (`⌘` + keycap) inside the compact pill.
    private var spotlightKeycapHint: some View {
        let dark = scheme == .dark
        let capFill = dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
        return HStack(spacing: 4) {
            Text("⌘")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.62))
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(capFill))

            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(capFill)
                if let hovered = hoveredEntryMode {
                    Text(hovered.key)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .monospacedDigit()
                }
            }
            .frame(width: 21, height: 21)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var compactContextMenu: some View {
        ForEach(SearchMode.categories) { mode in
            Button { model.selectMode(mode) } label: {
                Label("\(mode.title)  ⌘\(mode.key)", systemImage: mode.symbol)
            }
        }
        Divider()
        Button("索引与设置…") { onSettings() }
        Button("高级搜索…") { onAdvanced() }
        Button("搜索语法与快捷键") { showHelp = true }
        Divider()
        Picker("浮窗外观", selection: $appearance) {
            ForEach(SearchAppearance.allCases) { Text($0.title).tag($0) }
        }
    }

    private var settingsMenu: some View {
        Menu {
            if model.mode != .all {
                Button("返回全部搜索") { model.selectMode(.all) }
            }
            ForEach(SearchMode.categories) { mode in
                Button { model.selectMode(mode) } label: {
                    Label(mode.title, systemImage: mode == model.mode ? "checkmark" : mode.symbol)
                }
            }
            if model.mode.searchesIndex {
                Divider()
                if !model.browsingRecent {
                    Picker("搜索范围", selection: $model.scope) {
                        Text("全部").tag(SearchScope.all)
                        Text("仅文件名").tag(SearchScope.name)
                        Text("仅正文内容").tag(SearchScope.content)
                    }
                    Picker("排序方式", selection: $model.sort) {
                        Text("相关度").tag(SearchSort.relevance)
                        Text("最近修改").tag(SearchSort.modified)
                        Text("名称").tag(SearchSort.name)
                        Text("大小").tag(SearchSort.size)
                    }
                }
                Picker("预览栏", selection: $model.previewMode) {
                    ForEach(MijiSearchPreviewMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("索引位置", selection: $model.rootID) {
                    Text("所有位置").tag(String?.none)
                    ForEach(model.roots) { Text($0.name + ($0.isOnline ? "" : " · 未连接")).tag(Optional($0.id)) }
                }
                if !model.activeFilters.isEmpty {
                    Button("重置界面筛选") { model.resetInterfaceFilters() }
                }
            }
            if model.mode == .clipboard {
                Divider()
                Button(model.browse.recordingClipboard ? "暂停记录剪贴板" : "开启剪贴板历史") {
                    model.browse.setClipboardRecording(!model.browse.recordingClipboard)
                }
                Button("清空剪贴板历史") { model.browse.clearClipboardHistory() }
                    .disabled(model.browse.history.isEmpty)
            }
            Divider()
            Button("索引与设置…") { onSettings() }
            Button("高级搜索…") { onAdvanced() }
                .help(indexText)
            Button("搜索语法与快捷键") { showHelp = true }
            Divider()
            Picker("浮窗外观", selection: $appearance) {
                ForEach(SearchAppearance.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.58))
        }
        .menuStyle(.button)
        .buttonStyle(SearchIconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多选项与设置")
        .accessibilityLabel("搜索分类与设置")
        .popover(isPresented: $showHelp) { searchHelp }
    }

    // MARK: - Search Filters (Spotlight Capsules in Files Mode)

    private var scopeBar: some View {
        let extraFilters = model.activeFilters.filter { $0.id != .kind }
        return VStack(spacing: 0) {
            if model.mode == .files {
                // User-requested Miji file categories styled 1:1 as Spotlight capsules.
                HStack(spacing: 7) {
                    ForEach(browseKinds, id: \.self) { kind in
                        let selected = model.fileKind == kind
                        Button { model.fileKind = selected ? nil : kind } label: {
                            Text(kind.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SpotlightChipStyle(selected: selected, height: 26, fontSize: 12, horizontalPadding: 6))
                        .accessibilityLabel(kind.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: PanelMetrics.scopeHeight)

                if !extraFilters.isEmpty {
                    activeFilterRow(extraFilters)
                }
            } else {
                HStack(spacing: 7) {
                    kindMenu
                    filterMenu
                    if !extraFilters.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(extraFilters) { filter in
                                    FilterToken(label: filter.label, symbol: symbol(for: filter)) { model.removeFilter(filter.id) }
                                        .frame(maxWidth: filter.id == .root ? 132 : nil)
                                }
                            }
                        }.scrollIndicators(.hidden)
                        Button { model.resetInterfaceFilters() } label: {
                            Text("重置").padding(.horizontal, 4).frame(height: PanelMetrics.controlHeight)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("重置界面筛选，保留搜索词与视图偏好")
                        .accessibilityLabel("重置界面筛选")
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, PanelMetrics.content)
                .frame(height: PanelMetrics.scopeHeight)
            }
        }
    }

    private func activeFilterRow(_ filters: [MijiSearchFilter]) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(filters) { filter in
                        FilterToken(label: filter.label, symbol: symbol(for: filter)) { model.removeFilter(filter.id) }
                            .frame(maxWidth: filter.id == .root ? 132 : nil)
                    }
                }
            }.scrollIndicators(.hidden)
            Button { model.resetInterfaceFilters() } label: {
                Text("重置").padding(.horizontal, 4).frame(height: 24)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("重置界面筛选")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private var kindMenu: some View {
        let selected = model.kind
        return Menu {
            ForEach([FileKind?.none] + fileKinds.map(Optional.some), id: \.self) { kind in
                Button {
                    model.kind = kind
                } label: {
                    Label(kind?.title ?? "全部类型", systemImage: kind == selected ? "checkmark" : kind?.symbol ?? "square.stack")
                }
                .accessibilityAddTraits(kind == selected ? .isSelected : [])
            }
        } label: {
            filterLabel(selected?.title ?? "全部类型", symbol: selected?.symbol ?? "square.stack", active: selected != nil)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SpotlightChipStyle(selected: selected != nil)).fixedSize()
        .accessibilityLabel("文件类型：\(selected?.title ?? "全部")")
    }

    private func symbol(for filter: MijiSearchFilter) -> String {
        switch filter.id {
        case .root: return model.roots.first { $0.id == model.rootID }?.isExternal == true ? "externaldrive" : "internaldrive"
        case .scope: return model.scope == .content ? "doc.text.magnifyingglass" : "doc"
        case .sort: return "arrow.up.arrow.down"
        case .onlineOnly: return "externaldrive.badge.checkmark"
        case .kind: return model.kind?.symbol ?? "doc"
        case .currentFolder: return "folder"
        }
    }

    private var filterMenu: some View {
        let active = model.activeFilters.contains { $0.id != .kind }
        return Menu {
            if !model.browsingRecent {
                Picker("搜索范围", selection: $model.scope) {
                    Text("全部").tag(SearchScope.all); Text("文件名").tag(SearchScope.name); Text("内容").tag(SearchScope.content)
                }
            }
            Picker("索引位置", selection: $model.rootID) {
                Text("所有位置").tag(String?.none)
                ForEach(model.roots) { Text($0.name + ($0.isOnline ? "" : " · 未连接")).tag(Optional($0.id)) }
            }
            if !model.browsingRecent {
                Picker("排序", selection: $model.sort) {
                    Text("相关度").tag(SearchSort.relevance); Text("最近修改").tag(SearchSort.modified)
                    Text("名称").tag(SearchSort.name); Text("大小").tag(SearchSort.size)
                }
            }
            Divider()
            Button("重置界面筛选") { model.resetInterfaceFilters() }.disabled(model.activeFilters.isEmpty)
        } label: {
            filterLabel("筛选", symbol: "line.3.horizontal.decrease", active: active)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SpotlightChipStyle(selected: active)).fixedSize()
        .help("搜索范围、位置与排序")
        .accessibilityLabel(active ? "筛选：\(model.activeFilters.map(\.label).joined(separator: "、"))" : "筛选")
    }

    private func filterLabel(_ title: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if model.hits.isEmpty { emptyState }
        else {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.browsingRecent {
                        recentFiles
                    } else if model.showsFileGrid {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: model.floatingGridColumns), spacing: 12) {
                            ForEach(model.hits) { hit in
                                resultActions(ResultGridCell(hit: hit, query: model.query, location: model.resultLocation(hit).short, selected: model.selectedID == hit.id), hit: hit)
                            }
                        }.padding(12)
                    } else {
                        LazyVStack(spacing: PanelMetrics.rowSpacing) {
                            ForEach(model.hits) { hit in
                                resultActions(CompactResultRow(hit: hit, query: model.query,
                                                               folderName: parentFolderName(hit),
                                                               selected: model.selectedID == hit.id), hit: hit)
                            }
                        }
                        .padding(.horizontal, PanelMetrics.edge)
                        .padding(.vertical, PanelMetrics.listInset)
                    }
                }
                .opacity(currentResults ? 1 : 0.55)
                .onChange(of: model.selectedID) { if let id = model.selectedID { proxy.scrollTo(id) } }
            }
        }
    }

    /// Spotlight Files view: 5 floating preview thumbnails on top, "最近使用" header below, then compact list.
    private var recentFiles: some View {
        let featured = Array(model.hits.prefix(5))
        let remaining = Array(model.hits.dropFirst(featured.count))
        return LazyVStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(featured) { hit in
                    resultActions(RecentFileTile(hit: hit, selected: model.selectedID == hit.id && model.showsFileSelectionFeedback), hit: hit)
                }
                if featured.count < 5 {
                    ForEach(0..<(5 - featured.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if !remaining.isEmpty {
                Text("最近使用")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)

                ForEach(remaining) { hit in
                    resultActions(CompactResultRow(hit: hit, query: "",
                                                   folderName: parentFolderName(hit),
                                                   selected: model.selectedID == hit.id && model.showsFileSelectionFeedback), hit: hit)
                        .padding(.horizontal, PanelMetrics.edge)
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func parentFolderName(_ hit: SearchHit) -> String {
        let parent = URL(fileURLWithPath: hit.path).deletingLastPathComponent()
        let folder = parent.path == "/" ? "/" : parent.lastPathComponent
        if hit.root.isExternal {
            return "\(folder) · \(hit.root.name)"
        }
        return folder
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if model.searchStatus.phase == .searching || model.searchStatus.phase == .supplementing {
                ProgressView().controlSize(.small).frame(height: 24).accessibilityHidden(true)
            } else {
                Image(systemName: model.searchStatus.phase == .failed ? "exclamationmark.triangle" : "magnifyingglass")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary).frame(height: 24).accessibilityHidden(true)
            }
            Text(emptyTitle).font(.system(size: 13, weight: .semibold))
            Text(emptyDetail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            if model.searchStatus.phase == .complete && !model.activeFilters.isEmpty {
                Button("重置界面筛选") { model.resetInterfaceFilters() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var emptyTitle: String {
        switch model.searchStatus.phase {
        case .searching, .supplementing: return "正在搜索…"
        case .failed: return "未能完成搜索"
        case .complete: return model.browsingRecent ? "没有已索引的文件" : model.searchStatus.isLimited ? "暂未找到匹配项" : "当前条件下没有匹配项"
        case .idle: return "搜索文件与内容"
        }
    }

    private var emptyDetail: String {
        switch model.searchStatus.phase {
        case .searching, .supplementing: return model.browsingRecent ? "正在读取最近使用的文件" : "正在查找文件名与已索引内容"
        case .failed: return model.searchStatus.error ?? "请稍后重试。"
        default:
            if model.searchStatus.isLimited { return "仅检索了部分内容，可缩小范围" }
            if model.paused { return "索引已暂停，仍可搜索已保存的内容" }
            if model.progress.busy { return "索引仍在\(model.progress.phase)，可搜索已完成的内容" }
            return model.activeFilters.isEmpty ? "换个关键词，或输入文件名、文档文字" : "调整筛选条件，或更换关键词"
        }
    }

    private func resultActions<V: View>(_ view: V, hit: SearchHit) -> some View {
        let snapshot = model.displayedSnapshot
        return view.contentShape(Rectangle())
            .onTapGesture(count: 2) { model.selectedID = hit.id; model.performFileAction(.open, hit: hit, snapshot: snapshot) }
            .onTapGesture {
                guard model.isCurrentResult(hit, snapshot: snapshot) else { return }
                model.selectFile(hit.id); searchFocused = false
            }
            .accessibilityAction {
                guard model.isCurrentResult(hit, snapshot: snapshot) else { return }
                model.selectFile(hit.id); searchFocused = false
            }
            .accessibilityAction(named: Text("打开文件")) { model.performFileAction(.open, hit: hit, snapshot: snapshot) }
            .contextMenu {
                Button("打开") { model.selectedID = hit.id; model.performFileAction(.open, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("在 Finder 中显示") { model.selectedID = hit.id; model.performFileAction(.revealInFinder, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("快速查看") { model.selectedID = hit.id; model.performFileAction(.quickLook, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Divider()
                Button("复制文件") { model.selectedID = hit.id; model.performFileAction(.copyReference, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("复制路径") { model.selectedID = hit.id; model.performFileAction(.copyPath, hit: hit, snapshot: snapshot) }
                Divider()
                Menu("Wumi") {
                    Button("在 Wumi 中定位") { model.performFileAction(.reveal, hit: hit, snapshot: snapshot) }
                    Button("查看已索引内容") {
                        guard model.isCurrentResult(hit, snapshot: snapshot) else { return }
                        model.selectFile(hit.id)
                        model.previewEnabled = true
                    }
                    Button(L("Cut")) { model.performFileAction(.cutReference, hit: hit, snapshot: snapshot) }
                    Button(L("Copy To")) { model.performFileAction(.copyTo, hit: hit, snapshot: snapshot) }
                    Button(L("Send To")) { model.performFileAction(.sendTo, hit: hit, snapshot: snapshot) }
                    Button(L("Add to File Transit")) { model.performFileAction(.stageFile, hit: hit, snapshot: snapshot) }
                }
                .disabled(!model.isCurrentResult(hit, snapshot: snapshot))
            }
            .accessibilityIdentifier("Wumi.MijiSearch.Result.\(hit.id)")
            .id(hit.id)
    }

    // MARK: - Status Bar (Active Search Only)

    private var statusText: String {
        let status = model.searchStatus
        switch status.phase {
        case .searching: return "正在搜索…"
        case .supplementing: return "已找到 \(status.count) 项 · 正文检索中"
        case .failed: return "搜索未完成 · \(status.count) 项"
        case .complete:
            if status.isLimited { return "\(status.count) 项 · 仅检索了部分内容，可缩小范围" }
            return status.count == 500 ? "显示前 500 项" : "共 \(status.count) 项"
        case .idle: return "准备搜索"
        }
    }

    private var timingText: String? {
        guard let time = model.searchStatus.milliseconds, let timing = model.searchStatus.timing else { return nil }
        return "\(timing == .firstBatch ? "首批" : "完成") \(Int(time.rounded())) ms"
    }

    private var indexText: String {
        if model.paused { return "索引已暂停" }
        if model.progress.busy { return "\(model.progress.phase) · \(max(model.statistics.files, model.progress.processed).formatted()) 项" }
        return "已索引 \(model.statistics.files.formatted()) 个文件"
    }

    private var indexSymbol: String? {
        model.paused ? "pause.circle" : model.progress.busy ? "arrow.triangle.2.circlepath" : nil
    }

    private var footer: some View {
        HStack(spacing: 8) {
            statusLabel
            Spacer(minLength: 8)
            if let symbol = indexSymbol {
                Image(systemName: symbol).foregroundStyle(.tertiary).help(indexText).accessibilityLabel(indexText)
            }
            HStack(spacing: 3) {
                Button { model.gridEnabled.toggle(); searchFocused = false } label: {
                    Image(systemName: model.gridEnabled ? "list.bullet" : "square.grid.2x2")
                }
                .buttonStyle(SearchIconButtonStyle()).help("切换列表／网格").accessibilityLabel("切换列表／网格")
                previewMenu
                Button { model.performFileAction(.quickLook) } label: { Image(systemName: "eye") }
                    .buttonStyle(SearchIconButtonStyle()).help("快速查看 · ⌘Y").accessibilityLabel("快速查看")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.leading, PanelMetrics.content).padding(.trailing, 13)
        .frame(height: PanelMetrics.footerHeight)
    }

    private var statusLabel: some View {
        let status = model.searchStatus
        let spoken = [statusText, timingText].compactMap { $0 }.joined(separator: "，")
        return HStack(spacing: 6) {
            if status.phase == .searching || status.phase == .supplementing {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            } else if status.phase == .failed || status.isLimited {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
            Text(statusText).lineLimit(1)
        }
        .help(status.error ?? spoken)
        .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
    }

    private var previewMenu: some View {
        Menu {
            Picker("预览栏", selection: $model.previewMode) {
                ForEach(MijiSearchPreviewMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
        } label: {
            Image(systemName: "sidebar.right").font(.system(size: 13))
                .foregroundStyle(model.previewVisible ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button).buttonStyle(SearchIconButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("预览栏：\(model.previewMode.title)").accessibilityLabel("预览栏：\(model.previewMode.title)")
    }

    private var searchHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索语法").font(.headline)
            Text("多个词：全部匹配\n\"完整短语\"：连续匹配\next:pdf：限定格式\npath:课程：限定路径\n-草稿：排除词\n支持中文、拼音与首字母")
            Divider()
            Text("\(shortcutLabel) 唤起 · Esc 返回／收起\n⌘1 应用程序 · ⌘2 文件 · ⌘3 剪贴板 · ⌘0 全部\n↑ ↓ ← → 选择 · Return 打开\n⌘Return / ⌘R 定位 · ⌘Y / 空格预览\n⌘C 复制文件 · ⌘⇧C 复制路径").font(.caption)
        }.padding(20)
    }
}

/// Removable filter token pill.
private struct FilterToken: View {
    let label: String
    let symbol: String
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 10).padding(.trailing, 9).frame(height: PanelMetrics.controlHeight)
            .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.22 : 0.14)))
            .overlay { if contrast == .increased { Capsule().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(.primary).onHover { hovering = $0 }
        .help("移除条件：\(label)").accessibilityLabel("移除筛选：\(label)")
    }
}

// MARK: - Spotlight-Matched Result Row

private struct CompactResultRow: View {
    let hit: SearchHit
    let query: String
    let folderName: String
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var hasSnippet: Bool { (hit.matchedIn.contains("正文") || hit.matchedIn.contains("标签")) && !hit.snippet.isEmpty }
    private var offline: Bool { !hit.root.isOnline }
    private var secondaryStyle: AnyShapeStyle {
        selected ? AnyShapeStyle(Color.white.opacity(0.84)) : AnyShapeStyle(Color.primary.opacity(0.50))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIconCache.icon(hit))
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .opacity(offline ? 0.55 : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2.5) {
                Text(highlightedFilename(hit.file.name, query: query, selected: selected, size: 13.5))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                metadata
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(secondaryStyle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: PanelMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous).fill(fill))
        .onHover { hovering = $0 }
        .help(hit.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(offline ? "磁盘未连接" : "")
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            if hasSnippet {
                Text(highlightedSnippet(hit.snippet, query: query, selected: selected, size: 11.5))
                    .lineLimit(1)
            } else {
                Text(ResultFormat.kindLabel(hit)).fixedSize()
                if hit.file.kind != .folder {
                    Text("·").accessibilityHidden(true)
                    Text(ResultFormat.size(hit)).fixedSize()
                }
                Text("·").accessibilityHidden(true)
                Text(ResultFormat.date(hit.file.modified)).lineLimit(1).fixedSize()
            }
            Text("·").accessibilityHidden(true)
            Image(systemName: offline ? "externaldrive.badge.xmark" : "folder")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(offline ? AnyShapeStyle(selected ? Color.white : Color.orange) : secondaryStyle)
                .accessibilityHidden(true)
            Text(folderName).lineLimit(1).truncationMode(.middle)
        }
    }

    private var fill: Color {
        if selected { return SearchPalette.selectedRow(scheme) }
        return Color.primary.opacity(hovering ? (contrast == .increased ? 0.12 : 0.065) : 0)
    }
}

/// Spotlight Files top thumbnail tile: floats cleanly on glass with mini default-app badge, zero unselected card box.
private struct RecentFileTile: View {
    let hit: SearchHit
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if hit.root.isOnline && MijiSearchPreviewPolicy.hasContent(hit) {
                        MijiFileThumbnail(hit: hit, pixels: 240, decorated: true)
                    } else {
                        Image(nsImage: FileIconCache.icon(hit))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 76)

                if hit.file.kind != .folder,
                   let badge = BrowseAppIcon.defaultAppBadge(forFilePath: hit.path, fileExtension: hit.file.fileExtension) {
                    Image(nsImage: badge)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.32), radius: 2, y: 1)
                        .offset(x: -4, y: 2)
                        .accessibilityHidden(true)
                }
            }
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? SearchPalette.accent(scheme).opacity(0.24) : Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(SearchPalette.accent(scheme), lineWidth: 2)
                }
            }

            Text(hit.file.name)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.90))
                .frame(height: 30, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .help(hit.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(hit.root.isOnline ? "" : "磁盘未连接")
    }
}

/// Finder icon-view cell used when grid mode is enabled during active search.
private struct ResultGridCell: View {
    let hit: SearchHit
    let query: String
    let location: String
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    private var offline: Bool { !hit.root.isOnline }

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if !offline && MijiSearchPreviewPolicy.hasContent(hit) { MijiFileThumbnail(hit: hit, decorated: true).padding(10) }
                else {
                    Image(nsImage: FileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 64, height: 64)
                        .opacity(offline ? 0.55 : 1).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 112)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(selected ? (contrast == .increased ? 0.2 : 0.12) : hovering ? 0.06 : 0)))
            VStack(spacing: 3) {
                Text(highlightedFilename(hit.file.name, query: query, selected: selected, size: 12))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(selected ? SearchPalette.selectedRow(scheme) : Color.clear))
                HStack(spacing: 3) {
                    Image(systemName: offline ? "externaldrive.badge.xmark" : "folder").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(offline ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    Text(location).lineLimit(1).truncationMode(.middle)
                    if offline { Text("未连接").fontWeight(.medium).foregroundStyle(.orange).fixedSize() }
                }.font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 6).frame(maxWidth: .infinity)
        .onHover { hovering = $0 }.help(hit.path)
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(offline ? "磁盘未连接" : "")
    }
}

enum FileIconCache {
    static let cache = NSCache<NSString, NSImage>()
    static func icon(_ hit: SearchHit) -> NSImage {
        let key = (hit.file.kind == .application ? hit.path : hit.file.kind.rawValue + ":" + hit.file.fileExtension) as NSString
        if let icon = cache.object(forKey: key) { return icon }
        let icon: NSImage
        if hit.file.kind == .folder { icon = NSWorkspace.shared.icon(for: .folder) }
        else if hit.file.kind == .application && hit.root.isOnline { icon = NSWorkspace.shared.icon(forFile: hit.path) }
        else { icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: hit.file.fileExtension) ?? .data) }
        icon.size = NSSize(width: 32, height: 32); cache.setObject(icon, forKey: key); return icon
    }
}

/// Keeps the borderless panel transparent and applies the chosen appearance to the window.
private struct SearchWindowConfiguration: NSViewRepresentable {
    let appearance: SearchAppearance
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let target = appearance.windowAppearance
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            if window.appearance?.name != target?.name { window.appearance = target }
        }
    }
}
