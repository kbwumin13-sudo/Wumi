import SwiftUI
import MijiCore

struct MijiResultPreviewPane: View {
    @ObservedObject var model: MijiSearchModel
    @State private var indexedExpanded = false

    var body: some View {
        Group {
            if let hit = model.selected {
                VStack(alignment: .leading, spacing: 12) {
                    header(hit)
                    Divider()
                    HStack {
                        Label("匹配：\(hit.matchedIn)", systemImage: "magnifyingglass")
                        Spacer()
                        if let page = model.previewPage {
                            Button("第 \(page) 页 ↗") { model.showPDFMatch() }
                                .disabled(model.previewPDF == nil).buttonStyle(.plain).help("打开匹配页")
                        } else if let line = model.previewLine { Text("第 \(line) 行") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    notices(hit)
                    content(hit).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(hit.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(hit.path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.copySelectedPath() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).help("复制完整路径").accessibilityLabel("复制完整路径")
                    }
                }.padding(16)
            } else {
                Text("选择文件查看预览").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.selectedID) { indexedExpanded = false }
    }

    private func header(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: MijiFileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.file.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text("\(hit.file.kind.title) · \(hit.file.kind == .folder ? "文件夹" : ByteCountFormatter.string(fromByteCount: hit.file.size, countStyle: .file)) · \(Date(timeIntervalSince1970: hit.file.modified).formatted(.dateTime.year().month().day()))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("打开") { model.openSelected() }.disabled(!hit.root.isOnline)
                Button("定位") { model.revealSelected() }.disabled(!hit.root.isOnline).help("在 Wumi 中定位")
                Button("复制文件") { model.copySelectedFile() }
                    .disabled(!hit.root.isOnline || (MijiSearchPreviewPolicy.hasContent(hit) && !model.previewLoading && model.previewLocalURL == nil))
                Spacer(minLength: 0)
                Button { model.previewSelected() } label: { Image(systemName: "eye") }
                    .disabled(!hit.root.isOnline).help("快速查看 · ⌘Y").accessibilityLabel("快速查看")
            }.controlSize(.small)
        }
    }

    @ViewBuilder private func notices(_ hit: SearchHit) -> some View {
        if !hit.root.isOnline {
            Label("磁盘未连接 · 显示已索引内容", systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
        } else if MijiSearchPreviewPolicy.hasContent(hit) && !model.previewLoading && model.previewLocalURL == nil {
            Text("文件未下载或无法读取 · 显示已索引内容").font(.caption).foregroundStyle(.secondary)
        }
        if let warning = model.previewWarning ?? hit.file.contentError {
            ScrollView { Text(warning).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 44)
        }
    }

    @ViewBuilder private func content(_ hit: SearchHit) -> some View {
        if model.previewLoading {
            ProgressView("正在载入预览…").controlSize(.small).font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !MijiSearchPreviewPolicy.hasContent(hit) {
            VStack(alignment: .leading, spacing: 8) {
                Text(metadataHint(hit)).font(.callout).foregroundStyle(.secondary)
                if !hit.snippet.isEmpty { Text(mijiHighlightedPreview(hit.snippet, query: model.query)).font(.callout).textSelection(.enabled) }
            }
        } else if MijiSearchPreviewPolicy.usesTextReader(hit) && !model.previewText.isEmpty {
            textContent(hit)
        } else if let document = model.previewPDF {
            VStack(spacing: 8) {
                MijiPDFDocumentPreview(document: document, page: model.previewPage, terms: MijiPreviewResolver.terms(in: model.query))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                indexedDisclosure(hit)
            }
        } else if let url = model.previewLocalURL, hit.file.kind == .image || hit.file.kind == .audio || hit.file.kind == .video || MijiSearchPreviewPolicy.usesSystemPreview(hit, hasIndexedText: !model.previewText.isEmpty) {
            VStack(spacing: 8) {
                Group {
                    if hit.file.kind == .image { MijiFileThumbnail(hit: hit, pixels: 800, showsStatus: true) }
                    else if hit.file.kind == .audio || hit.file.kind == .video { MijiMediaFilePreview(hit: hit).id(hit.path) }
                    else { MijiSystemFilePreview(url: url) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                indexedDisclosure(hit)
            }
        } else if !model.previewText.isEmpty {
            textContent(hit)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("暂无可显示的预览").font(.callout)
                Text(hit.root.isOnline ? "可使用快速查看，或打开原文件。" : "重新连接磁盘后可查看原文件。").font(.caption).foregroundStyle(.secondary)
                if !hit.labels.isEmpty { Text(hit.labels).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
    }

    private func textContent(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已索引内容").font(.system(size: 10)).foregroundStyle(.secondary)
            ScrollView(hit.file.kind == .code ? [.horizontal, .vertical] : .vertical) {
                Text(mijiHighlightedPreview(model.previewText, query: model.query))
                    .font(hit.file.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private func indexedDisclosure(_ hit: SearchHit) -> some View {
        if !model.previewText.isEmpty || !hit.labels.isEmpty {
            DisclosureGroup("已索引文字与标签", isExpanded: $indexedExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(mijiHighlightedPreview(model.previewText, query: model.query)).textSelection(.enabled)
                        if !hit.labels.isEmpty { Text(hit.labels).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.frame(maxHeight: 110)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func metadataHint(_ hit: SearchHit) -> String {
        switch hit.file.kind {
        case .application: return "应用可直接打开，或在 Wumi 中定位。"
        case .folder: return "在 Wumi 中浏览此文件夹。"
        case .archive: return "打开原文件查看压缩包或磁盘映像内容。"
        default: return "可打开原文件，或使用快速查看。"
        }
    }
}
