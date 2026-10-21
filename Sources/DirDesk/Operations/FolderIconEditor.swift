import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// "Change Folder Icon": tint the folder, put a symbol on it, use an image (smaller than 20 MB) or restore the default.
struct FolderIconEditor: View {
    let folder: URL
    let onFinish: (String?) -> Void
    @State private var colorIndex: Int?
    @State private var symbol: String?

    static let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemGray]
    static let symbols = [
        "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "doc.fill", "photo.fill", "music.note", "film.fill", "book.fill", "briefcase.fill",
        "hammer.fill", "gearshape.fill", "cloud.fill", "lock.fill", "archivebox.fill", "camera.fill", "gamecontroller.fill", "globe", "graduationcap.fill", "terminal.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Change Folder Icon")).font(.headline)
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: FolderIconRenderer.render(color: colorIndex.map { Self.colors[$0] }, symbol: symbol))
                    .resizable().frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Folder Color")).font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach(Self.colors.indices, id: \.self) { index in
                            Button { colorIndex = colorIndex == index ? nil : index } label: {
                                Circle().fill(Color(nsColor: Self.colors[index])).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: colorIndex == index ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(LF("Color %lld", Int64(index + 1)))
                        }
                    }
                    Text(L("Folder Icon")).font(.system(size: 12, weight: .semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 10), spacing: 4) {
                        ForEach(Self.symbols, id: \.self) { name in
                            Button { symbol = symbol == name ? nil : name } label: {
                                Image(systemName: name).font(.system(size: 14)).frame(width: 28, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(symbol == name ? Color.accentColor.opacity(0.25) : Color.clear))
                            }
                            .buttonStyle(.plain)
                            .help(LF("Folder icon %@", name))
                        }
                    }
                }
            }
            HStack {
                Button(L("Choose Image…")) { chooseImage() }
                Button(L("Restore Default Icon")) { finish(FolderIconRenderer.apply(nil, to: folder)) }
                Spacer()
                Button(L("Cancel")) { onFinish(nil) }.keyboardShortcut(.cancelAction)
                Button(L("Apply")) {
                    finish(FolderIconRenderer.apply(FolderIconRenderer.render(color: colorIndex.map { Self.colors[$0] }, symbol: symbol), to: folder))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(colorIndex == nil && symbol == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func finish(_ succeeded: Bool) {
        onFinish(succeeded ? nil : L("Couldn’t change the folder icon. Make sure you can write to this folder."))
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = L("Pick an image file under 20 MB.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size < 20 * 1024 * 1024, let image = NSImage(contentsOf: url) else {
            onFinish(L("Pick an image file under 20 MB."))
            return
        }
        finish(FolderIconRenderer.apply(image, to: folder))
    }
}

enum FolderIconRenderer {
    /// The system folder icon tinted with `color`, with `symbol` embossed on its front.
    static func render(color: NSColor?, symbol: String?) -> NSImage {
        let base = NSWorkspace.shared.icon(for: .folder)
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            base.draw(in: rect)
            if let color {
                color.withAlphaComponent(0.55).set()
                rect.fill(using: .sourceAtop)
            }
            if let symbol {
                let shade = (color ?? .systemBlue).blended(withFraction: 0.45, of: .black) ?? .darkGray
                let configuration = NSImage.SymbolConfiguration(pointSize: 150, weight: .semibold).applying(.init(paletteColors: [shade.withAlphaComponent(0.85)]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    let glyphSize = glyph.size
                    let origin = NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2 - 34)
                    glyph.draw(in: NSRect(origin: origin, size: glyphSize))
                }
            }
            return true
        }
    }

    /// Sets (or with nil removes) the custom icon; false when the folder cannot be modified.
    @MainActor
    static func apply(_ image: NSImage?, to folder: URL) -> Bool {
        NSWorkspace.shared.setIcon(image, forFile: folder.path, options: [])
    }
}

extension WorkspaceController {
    func showFolderIconEditor(_ folder: URL) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = NSHostingView(rootView: FolderIconEditor(folder: folder) { [weak self, weak sheet] error in
            if let sheet { window.endSheet(sheet) }
            if let error {
                self?.presentError(error)
            } else {
                self?.refreshPanes(showing: [folder.deletingLastPathComponent()])
            }
        })
        window.beginSheet(sheet)
    }
}
