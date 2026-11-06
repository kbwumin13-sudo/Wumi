import SwiftUI
import MijiCore

struct MijiResultPreviewPane: View {
    @ObservedObject var model: MijiSearchModel
    var body: some View {
        ScrollView {
            if let hit = model.selected {
                VStack(alignment: .leading, spacing: 12) {
                    if model.previewLoading {
                        ProgressView("正在载入预览…").frame(maxWidth: .infinity).frame(height: 190)
                    } else { picture(hit).frame(height: 210).frame(maxWidth: .infinity) }
                    Text(hit.file.name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    Text(hit.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                    Text("\(hit.file.kind.title) · \(ByteCountFormatter.string(fromByteCount: hit.file.size, countStyle: .file)) · \(Date(timeIntervalSince1970: hit.file.modified).formatted(.dateTime.year().month().day()))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !hit.root.isOnline { Label("磁盘未连接 · 显示已索引内容", systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                    if hit.root.isOnline && !model.previewLoading && model.previewLocalURL == nil {
                        Text("文件尚未下载或无法读取，显示已索引内容").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("打开") { model.openSelected() }.disabled(!hit.root.isOnline)
                        Button("定位") { model.revealSelected() }.disabled(!hit.root.isOnline).help("在 Wumi 中定位")
                        Button("复制文件") { model.copySelectedFile() }.disabled(model.previewLocalURL == nil)
                    }.controlSize(.small)
                    if let page = model.previewPage {
                        Button("查看匹配页 · 第 \(page) 页") { model.showPDFMatch() }
                            .disabled(model.previewPDF == nil).font(.caption)
                    }
                    if let line = model.previewLine { Label("正文命中 · 第 \(line) 行", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary) }
                    if let warning = model.previewWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    Label("匹配位置：\(hit.matchedIn)", systemImage: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    if !hit.snippet.isEmpty {
                        Text(mijiHighlightedPreview(hit.snippet, query: model.query)).font(.system(size: 12)).textSelection(.enabled)
                    }
                    if !hit.labels.isEmpty { Text(hit.labels).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if !model.previewText.isEmpty && hit.file.kind != .code {
                        Divider()
                        Text("已索引内容").font(.caption).foregroundStyle(.secondary)
                        Text(mijiHighlightedPreview(model.previewText, query: model.query))
                            .font(hit.file.kind == .code ? .system(size: 11, design: .monospaced) : .system(size: 12))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = hit.file.contentError { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(18)
            } else {
                Text("选择文件查看预览").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 120)
            }
        }
    }
    @ViewBuilder private func picture(_ hit: SearchHit) -> some View {
        if hit.file.kind == .code, !model.previewText.isEmpty {
            ScrollView([.horizontal,.vertical]) {
                Text(mijiHighlightedPreview(model.previewText,query:model.query)).font(.system(size:11,design:.monospaced)).textSelection(.enabled).padding(10).frame(maxWidth:.infinity,alignment:.leading)
            }.background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
        } else if let document = model.previewPDF {
            MijiPDFDocumentPreview(document: document, page: model.previewPage, terms: MijiPreviewResolver.terms(in: model.query))
        } else if model.previewLocalURL == nil {
            Image(systemName: hit.root.isOnline ? hit.file.kind.mijiPreviewSymbol : "externaldrive.badge.exclamationmark").font(.system(size: 50, weight: .light)).foregroundStyle(.secondary)
        } else if hit.file.kind == .video || hit.file.kind == .audio {
            MijiMediaFilePreview(hit: hit).id(hit.path)
        } else if hit.file.kind == .image {
            MijiFileThumbnail(hit: hit, pixels: 800)
        } else if hit.file.kind == .document, let url = model.previewLocalURL, hit.file.fileExtension.lowercased() != "pdf" {
            MijiSystemFilePreview(url: url)
        } else { MijiFileThumbnail(hit: hit, pixels: 600) }
    }
}
