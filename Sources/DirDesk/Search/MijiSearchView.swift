import SwiftUI
import AppKit
import DirDeskCore
import UniformTypeIdentifiers
import MijiCore

struct MijiSearchView:View {
    @ObservedObject var model:MijiSearchModel
    let onDismiss: () -> Void
    let onAdvanced: () -> Void
    let onSettings: () -> Void
    let embedded: Bool
    @StateObject private var keyScope = MijiSearchKeyScope()
    @FocusState private var searchFocused:Bool
    @State private var showHelp=false
    private var expanded:Bool {!model.query.isEmpty}
    private let tabs:[FileKind?]=[nil,.folder,.application,.document,.image,.video,.audio,.code,.archive]
    init(model: MijiSearchModel, onDismiss: @escaping () -> Void, onAdvanced: @escaping () -> Void,
         onSettings: @escaping () -> Void, embedded: Bool = false) {
        self.model = model
        self.onDismiss = onDismiss
        self.onAdvanced = onAdvanced
        self.onSettings = onSettings
        self.embedded = embedded
    }

    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:15) {
                Image(systemName:"magnifyingglass").font(.system(size:23,weight:.regular)).foregroundStyle(.secondary)
                TextField("搜索这台 Mac",text:$model.query).font(.system(size:25,weight:.regular)).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索文件").accessibilityIdentifier("Wumi.MijiSearch.Field")
                if model.searching {ProgressView().controlSize(.small)}
                if expanded {Button {model.query=""} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.tertiary)}.buttonStyle(.plain).help("清空搜索").accessibilityIdentifier("Wumi.MijiSearch.Clear")}
                Button {onSettings()} label:{Image(systemName:"gearshape").font(.system(size:15)).foregroundStyle(.secondary)}.buttonStyle(.plain).help("索引与设置").accessibilityIdentifier("Wumi.MijiSearch.Settings")
            }.padding(.horizontal,24).frame(height:72)
            if expanded {
                Divider().padding(.horizontal,16)
                HStack(spacing:3) {
                    ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing:3) {
                    ForEach(tabs,id:\.self) {kind in
                        Button {model.kind=kind} label: {Text(kind?.title ?? "全部").font(.system(size:12,weight:.medium)).padding(.horizontal,10).padding(.vertical,6).foregroundStyle(model.kind == kind ? Color.accentColor : .secondary).background(model.kind == kind ? Color.accentColor.opacity(0.15) : .clear,in:Capsule())}.buttonStyle(.plain).accessibilityIdentifier("Wumi.MijiSearch.Kind." + (kind?.rawValue ?? "all"))
                    }
                    }.fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength:2)
                    Menu {
                        if model.context != nil {
                            Picker("查找位置", selection: $model.currentFolderOnly) {
                                Text("这台 Mac").tag(false)
                                Text("当前目录").tag(true)
                            }.accessibilityIdentifier("Wumi.MijiSearch.CurrentFolder")
                            Divider()
                        }
                        Picker("搜索范围",selection:$model.scope) {Text("全部").tag(SearchScope.all);Text("文件名").tag(SearchScope.name);Text("内容").tag(SearchScope.content)}
                        Picker("索引位置",selection:$model.rootID) {Text("所有位置").tag(String?.none);ForEach(model.roots){Text($0.name + ($0.isOnline ? "" : " · 未连接")).tag(Optional($0.id))}}
                        Divider()
                        Picker("排序",selection:$model.sort) {Text("相关度").tag(SearchSort.relevance);Text("最近修改").tag(SearchSort.modified);Text("名称").tag(SearchSort.name);Text("大小").tag(SearchSort.size)}
                        Divider()
                        Button("高级搜索", action: onAdvanced).accessibilityIdentifier("Wumi.MijiSearch.Advanced")
                    } label:{Label(model.scope == .content ? "内容" : model.scope == .name ? "文件名" : "筛选",systemImage:"line.3.horizontal.decrease")}.menuStyle(.borderlessButton).fixedSize().font(.system(size:11)).foregroundStyle(.secondary).accessibilityIdentifier("Wumi.MijiSearch.Filters")
                }.padding(.horizontal,16).frame(height:44)
                GeometryReader {geometry in
                    if embedded && geometry.size.width < 680 && model.previewVisible {
                        VStack(spacing:0) {
                            visibleResults.frame(height:max(100,geometry.size.height*0.35))
                            Divider()
                            if model.searchPresented {MijiResultPreviewPane(model:model)}
                        }
                    } else {
                        HStack(spacing:0) {
                            visibleResults.frame(maxWidth:.infinity,maxHeight:.infinity)
                            if model.previewVisible {
                                Divider()
                                MijiResultPreviewPane(model:model).frame(width:min(MijiSearchModel.previewWidth,geometry.size.width*0.42))
                            }
                        }.frame(width:geometry.size.width,height:geometry.size.height)
                    }
                }
            }
            footer
        }
        .frame(width: embedded ? nil : model.panelWidth, height: embedded ? nil : model.panelHeight)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .top)
        .background(MijiGlassBackground().overlay(Color.black.opacity(0.48)))
        .environment(\.colorScheme,.dark)
        .clipShape(RoundedRectangle(cornerRadius:20))
        .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(.white.opacity(0.13),lineWidth:0.7))
        .background {
            if !embedded { MijiSearchWindowConfiguration() }
        }
        .background(MijiSearchKeyRegion(scope: keyScope, embedded: embedded, model: model,
                                        focusSearch: { searchFocused = true },
                                        onDismiss: onDismiss, onSettings: onSettings))
        .background(MijiWindowVisibilityReader { [weak model] in model?.setWindowVisible($0) })
        .ignoresSafeArea()
        .onAppear { model.setSearchVisible(true); searchFocused = true }
        .onDisappear {model.setSearchVisible(false)}
        .onChange(of: model.query.isEmpty) { _, empty in
            if empty { searchFocused = true }
        }
        .onChange(of:model.focusSearch) {searchFocused=true}
        .alert("觅迹",isPresented:Binding(get:{model.message != nil},set:{if !$0{model.message=nil}})) {Button("好"){model.message=nil}} message:{Text(model.message ?? "")}
    }
    @ViewBuilder private var visibleResults:some View {
        if model.searchPresented {
            results.background(GeometryReader {g in
                Color.clear.onAppear {model.resultAreaWidth=g.size.width}.onChange(of:g.size.width){_,value in model.resultAreaWidth=value}
            })
        } else {Color.clear}
    }
    @ViewBuilder private var results:some View {
        if model.hits.isEmpty {
            VStack(spacing:10) {Image(systemName:"magnifyingglass").font(.system(size:28,weight:.light));Text(model.statistics.files==0 ? "正在建立文件目录…" : "没有找到匹配项").font(.system(size:14));Text("可搜索文件名、文档文字和图片内容").font(.system(size:12)).foregroundStyle(.tertiary)}.foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            ScrollViewReader {proxy in
                ScrollView {
                    LazyVGrid(columns:model.gridEnabled ? Array(repeating:GridItem(.flexible(),spacing:10),count:model.gridColumns) : [GridItem(.flexible())],spacing:model.gridEnabled ? 10 : 2) {
                        ForEach(model.hits) {hit in
                            Group {
                                if model.gridEnabled {MijiResultGridCell(hit:hit,query:model.query,selected:model.selectedID==hit.id)}
                                else {MijiCompactResultRow(hit:hit,query:model.query,selected:model.selectedID==hit.id)}
                            }
                                .contentShape(Rectangle()).onTapGesture(count:2){model.selectedID=hit.id;model.openSelected()}
                                .onTapGesture{model.selectedID=hit.id;searchFocused=false; keyScope.focusResults()}
                                .contextMenu {
                                    Button("打开"){model.selectedID=hit.id;model.openSelected()}.disabled(!hit.root.isOnline)
                                    Button("在 Finder 中显示"){model.selectedID=hit.id;model.revealSelectedInFinder()}.disabled(!hit.root.isOnline)
                                    Button("快速查看"){model.selectedID=hit.id;model.previewSelected()}.disabled(!hit.root.isOnline)
                                    Button("查看已索引内容"){model.selectedID=hit.id;model.previewEnabled=true}
                                    Button("复制路径"){model.selectedID=hit.id;model.copySelectedPath()}
                                    Divider()
                                    Group {
                                        Button("在 Wumi 中定位") { model.selectedID=hit.id; model.revealSelected() }
                                        Button(L("Copy")) { LightningSearchActions.copy([URL(fileURLWithPath: hit.path)]) }
                                        Button(L("Cut")) { LightningSearchActions.cut([URL(fileURLWithPath: hit.path)]) }
                                        Button(L("Copy To")) { FileOpenRouter.chooseDestination(for: [URL(fileURLWithPath: hit.path)], move: false) }
                                        Button(L("Send To")) { FileOpenRouter.chooseDestination(for: [URL(fileURLWithPath: hit.path)], move: true) }
                                        Button(L("Add to File Transit")) { FileTransitStore.shared.add([URL(fileURLWithPath: hit.path)]) }
                                    }.disabled(!hit.root.isOnline)
                                }.accessibilityIdentifier("Wumi.MijiSearch.Result.\(hit.id)").id(hit.id)
                        }
                    }.padding(.horizontal,10).padding(.bottom,5)
                }.onChange(of:model.selectedID){if let id=model.selectedID {proxy.scrollTo(id)}}
            }
        }
    }
    private var footer:some View {
        VStack(spacing:0) {
            if expanded {Divider()}
            HStack(spacing:8) {
                if expanded {Text("\(model.hits.count == 500 ? "前 " : "共 ")\(model.hits.count) 项 · \(model.searchMilliseconds,specifier:"%.1f") ms")}
                else {Text(model.progress.busy ? "\(model.progress.phase) · \(max(model.statistics.files,model.progress.processed).formatted()) 项" : "觅迹 · \(model.statistics.files.formatted()) 个文件")}
                if model.progress.busy && expanded {Circle().fill(Color.accentColor).frame(width:4,height:4).help(model.progress.phase)}
                Spacer(minLength:5)
                if expanded {
                    Text("↩ 打开    ⌘↩ 定位")
                    Button("⌘Y 预览"){model.previewSelected()}.buttonStyle(.plain)
                    Button {model.gridEnabled.toggle();searchFocused=false;keyScope.focusResults()} label:{Image(systemName:model.gridEnabled ? "list.bullet" : "square.grid.2x2")}.buttonStyle(.plain).help("切换列表／网格").accessibilityLabel("切换列表／网格")
                    Menu {
                        Picker("预览栏",selection:$model.previewMode) {
                            ForEach(MijiSearchPreviewMode.allCases) {mode in Text(mode.title).tag(mode)}
                        }
                    } label:{Image(systemName:"sidebar.right").foregroundStyle(model.previewVisible ? Color.accentColor : .secondary)}
                    .menuStyle(.borderlessButton).fixedSize().help("预览栏：\(model.previewMode.title)").accessibilityLabel("预览栏：\(model.previewMode.title)")
                } else {Text("⌃⌥Space 唤起")}
                Button {showHelp.toggle()} label:{Image(systemName:"questionmark.circle")}.buttonStyle(.plain).popover(isPresented:$showHelp) {
                    VStack(alignment:.leading,spacing:10) {Text("搜索语法").font(.headline);Text("多个词：全部匹配\n\"完整短语\"：连续匹配\next:pdf：限定格式\npath:课程：限定路径\n-草稿：排除词\n支持中文、拼音与首字母");Divider();Text("↑ ↓ 选择 · Return 打开\n⌘Return / ⌘R 定位 · ⌘Y / 空格预览\n⌘C 复制文件 · ⌘⇧C 复制路径 · Esc 收起").font(.caption)}.padding(20)
                }
            }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,22).frame(height:28)
        }
    }
}
private struct MijiCompactResultRow:View {
    let hit:SearchHit
    let query:String
    let selected:Bool
    private var parentPath:String {
        let path=URL(fileURLWithPath:hit.path).deletingLastPathComponent().path
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        return path==home ? "~" : (path.hasPrefix(home+"/") ? "~"+path.dropFirst(home.count) : path)
    }
    private var title:AttributedString {
        var text=AttributedString(hit.file.name)
        for term in QueryParser.parse(query).terms where term.field == .text && !term.isExcluded {
            if let range=text.range(of:term.value,options:.caseInsensitive) {text[range].foregroundColor = .accentColor}
        }
        return text
    }
    var body:some View {
        HStack(spacing:13) {
            Image(nsImage:MijiFileIconCache.icon(hit)).resizable().scaledToFit().frame(width:32,height:32)
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.system(size:14,weight:.medium)).lineLimit(1)
                if (hit.matchedIn.contains("正文") || hit.matchedIn.contains("标签")),!hit.snippet.isEmpty {
                    Text(mijiHighlightedPreview(hit.snippet,query:query)).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                } else {Text(parentPath).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)}
            }
            Spacer(minLength:10)
            VStack(alignment:.trailing,spacing:3) {
                if !hit.root.isOnline {Text("未连接").foregroundStyle(.orange)}
                else {Text(Date(timeIntervalSince1970:hit.file.modified).formatted(.dateTime.month().day()))}
                Text(hit.file.kind == .folder ? "文件夹" : ByteCountFormatter.string(fromByteCount:hit.file.size,countStyle:.file)).foregroundStyle(.tertiary)
            }.font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(.horizontal,15).frame(height:57)
        .background(selected ? Color.accentColor.opacity(0.27) : .clear,in:RoundedRectangle(cornerRadius:10))
        .accessibilityElement(children:.combine).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
private struct MijiResultGridCell:View {
    let hit:SearchHit
    let query:String
    let selected:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            if hit.root.isOnline && MijiSearchPreviewPolicy.hasContent(hit) {
                MijiFileThumbnail(hit:hit).frame(maxWidth:.infinity).frame(height:108)
            } else {Image(nsImage:MijiFileIconCache.icon(hit)).resizable().scaledToFit().frame(width:40,height:40).frame(maxWidth:.infinity).frame(height:108)}
            Text(mijiHighlightedPreview(hit.file.name,query:query)).font(.system(size:12,weight:.medium)).lineLimit(1)
            Text(hit.root.isOnline ? hit.file.kind.title : "未连接").font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
        .background(selected ? Color.accentColor.opacity(0.27) : Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
        .accessibilityElement(children:.combine).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum MijiFileIconCache {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    static func icon(_ hit:SearchHit)->NSImage {
        let key=(hit.file.kind == .application ? hit.path : hit.file.kind.rawValue+":"+hit.file.fileExtension) as NSString
        if let icon=cache.object(forKey:key){return icon}
        let icon:NSImage
        if hit.file.kind == .folder {icon=NSWorkspace.shared.icon(for:.folder)}
        else if hit.file.kind == .application && hit.root.isOnline {icon=NSWorkspace.shared.icon(forFile:hit.path)}
        else {icon=NSWorkspace.shared.icon(for:UTType(filenameExtension:hit.file.fileExtension) ?? .data)}
        icon.size=NSSize(width:32,height:32);cache.setObject(icon,forKey:key);return icon
    }
}
private struct MijiGlassBackground:NSViewRepresentable {
    func makeNSView(context:Context)->NSVisualEffectView {let view=NSVisualEffectView();view.appearance=NSAppearance(named:.darkAqua);view.material = .hudWindow;view.blendingMode = .behindWindow;view.state = .active;return view}
    func updateNSView(_ view:NSVisualEffectView,context:Context){}
}
private struct MijiSearchWindowConfiguration:NSViewRepresentable {
    func makeNSView(context:Context)->NSView {NSView()}
    func updateNSView(_ view:NSView,context:Context) {
        DispatchQueue.main.async {guard let window=view.window else{return};window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.isOpaque=false;window.backgroundColor = .clear;window.isMovableByWindowBackground=true;window.level = .floating;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];for button in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton]{window.standardWindowButton(button)?.isHidden=true}}
    }
}

/// Embedded surfaces own only keys whose first responder is inside their bounds.
/// Field editors live outside the SwiftUI hierarchy, so use their NSTextField
/// delegate to test the actual input location. Other windows/surfaces pass through.
@MainActor
private final class MijiSearchKeyScope: ObservableObject {
    weak var view: NSView?
    func focusResults() { if let view { view.window?.makeFirstResponder(view) } }
}

private struct MijiSearchKeyRegion: NSViewRepresentable {
    let scope: MijiSearchKeyScope
    let embedded: Bool
    let model: MijiSearchModel
    let focusSearch: () -> Void
    let onDismiss: () -> Void
    let onSettings: () -> Void

    func makeNSView(context: Context) -> MijiSearchKeyView {
        let view = MijiSearchKeyView()
        scope.view = view
        configure(view)
        return view
    }
    func updateNSView(_ view: MijiSearchKeyView, context: Context) { configure(view) }
    private func configure(_ view: MijiSearchKeyView) {
        view.enabled = embedded
        view.handle = { action in
            switch action {
            case .focusSearch: focusSearch()
            case .reveal: model.revealSelected()
            case .preview: model.previewSelected()
            case .copyPath: model.copySelectedPath()
            case .copyFile: model.copySelectedFile()
            case .moveLeft: if model.gridEnabled {scope.focusResults();model.moveSelection(-1)}
            case .moveRight: if model.gridEnabled {scope.focusResults();model.moveSelection(1)}
            case .hide: onDismiss()
            case .settings: onSettings()
            case .moveDown: scope.focusResults(); model.moveSelection(model.gridEnabled ? model.gridColumns : 1)
            case .moveUp: scope.focusResults(); model.moveSelection(model.gridEnabled ? -model.gridColumns : -1)
            case .open: model.openSelected()
            }
        }
    }
    static func dismantleNSView(_ view: MijiSearchKeyView, coordinator: ()) { view.removeMonitor() }
}

private final class MijiSearchKeyView: NSView {
    var enabled = false
    var handle: ((MijiSearchKeyAction) -> Void)?
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    // A background region must never eat mouse events for the SwiftUI controls.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.enabled, let window = self.window, event.window === window,
                  self.owns(window.firstResponder),
                  let action = MijiSearchKeyAction.action(for: event, firstResponder: window.firstResponder) else { return event }
            self.handle?(action)
            return nil
        }
    }
    private func owns(_ responder: NSResponder?) -> Bool {
        if responder === self { return true }
        var responderView = responder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            responderView = editor.delegate as? NSView
        }
        guard let responderView, responderView.window === window else { return false }
        let rect = convert(responderView.bounds, from: responderView)
        return bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
    }
    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// Reports whether the hosting window is really on screen. An ordered-out panel keeps
/// its SwiftUI views (and their onAppear state), so the search session asks the window.
private struct MijiWindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var reported: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                let center = NotificationCenter.default
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.report() })
                }
                for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.report() })
                }
            }
            report()
        }

        private func report() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden } ?? false
            guard visible != reported else { return }
            reported = visible
            onChange(visible)
        }
    }
}
