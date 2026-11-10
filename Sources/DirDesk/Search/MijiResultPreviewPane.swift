import SwiftUI
import MijiCore

/// Preview column: fixed header and actions, one content well, fixed path row. It shares the
/// panel's glass; a hairline in MainView separates it from the results.
struct MijiResultPreviewPane: View {
    @ObservedObject var model: MijiSearchModel
    @State private var indexedExpanded = false

    var body: some View {
        Group {
            if let hit = model.selected {
                let availability = model.resultAvailability(hit)
                let snapshot = model.displayedSnapshot
                VStack(alignment: .leading, spacing: 12) {
                    header(hit, availability: availability)
                    notices(availability)
                    matchLine(hit)
                    content(hit).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text(hit.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(hit.path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.performFileAction(.copyPath, hit: hit, snapshot: snapshot) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(MijiSearchIconButtonStyle()).foregroundStyle(.secondary).help("复制完整路径").accessibilityLabel("复制完整路径")
                    }.padding(.bottom, -4)
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("选择文件查看预览").font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .combine)
            }
        }
        .onChange(of: model.selectedID) { indexedExpanded = false }
    }

    // MARK: Header and actions

    private func header(_ hit: SearchHit, availability: MijiResultAvailability) -> some View {
        let snapshot = model.displayedSnapshot
        let originalUnavailable = availability.state == .diskOffline || availability.state == .fileUnavailable
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: MijiFileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 40, height: 40)
                    .opacity(originalUnavailable ? 0.6 : 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.file.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text(metadata(hit)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { model.performFileAction(.open, hit: hit, snapshot: snapshot) } label: { Text("打开").frame(minWidth: 44) }
                    .buttonStyle(.borderedProminent)
                Button { model.performFileAction(.reveal, hit: hit, snapshot: snapshot) } label: { Label("定位", systemImage: "folder") }
                    .help("在 Wumi 中定位")
                Button { model.performFileAction(.copyFile, hit: hit, snapshot: snapshot) } label: { Label("复制", systemImage: "doc.on.doc") }
                    .help("复制文件").accessibilityLabel("复制文件")
                Spacer(minLength: 0)
                Button { model.performFileAction(.quickLook, hit: hit, snapshot: snapshot) } label: { Image(systemName: "eye") }
                    .help("快速查看 · ⌘Y").accessibilityLabel("快速查看")
            }
            .buttonBorderShape(.capsule).controlSize(.regular)
            .disabled(originalUnavailable || !model.isCurrentResult(hit))
            .help(availability.message ?? "打开或定位原文件，也可复制文件")
        }
    }

    /// Kind, size and modification date. The kind uses the app's own Chinese titles: system
    /// type descriptions follow the bundle localization and would read in English here.
    private func metadata(_ hit: SearchHit) -> String {
        let kind = hit.file.kind.title
        let size = hit.file.kind == .folder ? nil : ByteCountFormatter.string(fromByteCount: hit.file.size, countStyle: .file)
        let date = Date(timeIntervalSince1970: hit.file.modified).formatted(.dateTime.year().month().day())
        return [kind, size, date].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Availability notices

    @ViewBuilder private func notices(_ availability: MijiResultAvailability) -> some View {
        if availability.message != nil || availability.contentMessage != nil {
            let style = MijiNoticeStyle(availability.state)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: style.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(style.tint)
                    .frame(width: 16).padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if let message = availability.message {
                        Text(message).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }
                    if availability.state == .fileUnavailable && !model.previewText.isEmpty {
                        Text("仍可阅读已索引内容，或复制原路径。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let warning = availability.contentMessage {
                        // Short warnings size to their text; long ones keep four lines and the full text in the tooltip.
                        Text(warning).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).help(warning)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.tint.opacity(0.13)))
            .accessibilityElement(children: .combine)
        }
    }

    /// One symbol and tint per state, so offline, unavailable, failed and partial content read
    /// differently before the text is read.
    private struct MijiNoticeStyle {
        let symbol: String
        let tint: Color
        init(_ state: MijiResultAvailabilityState) {
            switch state {
            case .diskOffline: symbol = "externaldrive.badge.xmark"; tint = .orange
            case .fileUnavailable: symbol = "questionmark.folder"; tint = .orange
            case .extractionFailed: symbol = "exclamationmark.triangle"; tint = .orange
            case .indexedOnly: symbol = "doc.text"; tint = .accentColor
            case .partial: symbol = "doc.badge.ellipsis"; tint = .yellow
            case .available: symbol = "info.circle"; tint = .secondary
            }
        }
    }

    // MARK: Match line and content

    private func matchLine(_ hit: SearchHit) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.tertiary).accessibilityHidden(true)
            Text("匹配：\(hit.matchedIn)")
            Spacer(minLength: 0)
            if let page = model.previewPage {
                Button { model.showPDFMatch() } label: { Label("第 \(page) 页", systemImage: "arrow.up.forward").labelStyle(MijiTrailingIconLabel()) }
                    .buttonStyle(.plain).foregroundStyle(model.previewPDF == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    .disabled(model.previewPDF == nil).help("打开匹配页")
            } else if let line = model.previewLine { Text("第 \(line) 行").monospacedDigit() }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }

    @ViewBuilder private func content(_ hit: SearchHit) -> some View {
        let snapshot=model.displayedSnapshot
        if model.previewLoading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在载入预览…").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !MijiSearchPreviewPolicy.hasContent(hit) {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                Image(nsImage: MijiFileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 88, height: 88)
                    .opacity(hit.root.isOnline ? 1 : 0.6).accessibilityHidden(true)
                Text(metadataHint(hit)).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !hit.snippet.isEmpty {
                    Text(mijiHighlightedPreview(hit.snippet, query: model.query)).font(.system(size: 12)).textSelection(.enabled)
                        .multilineTextAlignment(.center).lineLimit(4)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if MijiSearchPreviewPolicy.usesTextReader(hit) && !model.previewText.isEmpty {
            textContent(hit)
        } else if let document = model.previewPDF {
            VStack(spacing: 8) {
                MijiPDFDocumentPreview(document: document, page: model.previewPage, terms: MijiPreviewResolver.terms(in: model.query))
                    .contentWell()
                indexedDisclosure(hit)
            }
        } else if let url = model.previewLocalURL, hit.file.kind == .image || hit.file.kind == .audio || hit.file.kind == .video || MijiSearchPreviewPolicy.usesSystemPreview(hit, hasIndexedText: !model.previewText.isEmpty) {
            VStack(spacing: 8) {
                Group {
                    if hit.file.kind == .image { MijiFileThumbnail(hit: hit, pixels: 800, showsStatus: true).padding(10) }
                    else if hit.file.kind == .audio || hit.file.kind == .video { MijiMediaFilePreview(hit: hit, authorize: { model.fileOperationURL(for:hit,action:.preview,snapshot:snapshot) }).id(hit.path) }
                    else { MijiSystemFilePreview(url: url) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentWell()
                indexedDisclosure(hit)
            }
        } else if !model.previewText.isEmpty {
            textContent(hit)
        } else {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                Image(nsImage: MijiFileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 64, height: 64).opacity(0.8).accessibilityHidden(true)
                Text("暂无可显示的预览").font(.system(size: 13, weight: .medium))
                Text(hit.root.isOnline ? "可使用快速查看，或打开原文件。" : "重新连接磁盘后可查看原文件。").font(.system(size: 11)).foregroundStyle(.secondary)
                if !hit.labels.isEmpty { Text(hit.labels).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.center) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func textContent(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已索引内容").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ScrollView(hit.file.kind == .code ? [.horizontal, .vertical] : .vertical) {
                Text(mijiHighlightedPreview(model.previewText, query: model.query))
                    .font(hit.file.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }.contentWell()
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
        case .application: return "应用可直接打开，或在 Finder 中查看。"
        case .folder: return "在 Finder 中浏览此文件夹。"
        case .archive: return "打开原文件查看压缩包或磁盘映像内容。"
        default: return "可打开原文件，或使用快速查看。"
        }
    }
}

/// Text first, symbol after, for the "第 N 页 ↗" link.
private struct MijiTrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

private extension View {
    /// The single reading surface of the preview: a faint, rounded well on the panel material.
    func contentWell() -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
