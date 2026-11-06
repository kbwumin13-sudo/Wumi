import AppKit
import DirDeskCore
import MijiCore
import PDFKit
import CoreText

/// Opt-in acceptance for the actual embedded Miji model, using an explicit scratch catalog.
@MainActor
enum DebugMijiRun {
    static func run(output: URL) {
        guard let path = UserDefaults.standard.string(forKey: "WumiSearchDatabase"),
              path.hasPrefix(output.deletingLastPathComponent().path + "/"),
              LightningSearchService.isReadOnly else { return }
        Task { @MainActor in
            var checks: [[String: Any]] = []
            func check(_ name: String, _ value: Bool, _ detail: String = "") { checks.append(["name": name, "passed": value, "detail": detail]) }
            @MainActor func wait(_ condition: () -> Bool) async -> Bool {
                let until = ProcessInfo.processInfo.systemUptime + 15
                while !condition(), ProcessInfo.processInfo.systemUptime < until {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return condition()
            }
            do {
                try fixture(databaseURL: URL(fileURLWithPath: path))
                let service = LightningSearchService.shared
                service.ensureStarted()
                check("shared index loaded", await wait { service.engine != nil })
                let model = MijiSearchModel()
                model.setSearchVisible(true)
                @MainActor func search(_ text: String) async -> [SearchHit] {
                    model.query = ""
                    model.query = text
                    _ = await wait { !model.searching }
                    return model.hits
                }
                check("Chinese filename", await search("数学分析").contains { $0.file.name == "数学分析笔记.md" })
                model.query = "a different request"
                check("debounce clears stale result actions", model.searching && model.hits.isEmpty && model.selectedID == nil)
                check("pinyin", await search("shuxue").contains { $0.file.name == "数学分析笔记.md" })
                check("pinyin initials", await search("sxfx").contains { $0.file.name == "数学分析笔记.md" })
                model.scope = .name
                check("name-only excludes body", await search("ORIGINAL_BODY_TOKEN").isEmpty)
                model.scope = .content
                check("document body", await search("ORIGINAL_BODY_TOKEN").map(\.file.name) == ["Wumi-note.txt"])
                model.scope = .all
                _ = await search("ORIGINAL_BODY_TOKEN")
                let contentSelection = model.selectedID
                model.refresh()
                check("catalog refresh keeps content selection pending", model.selectedID == contentSelection && !model.hits.isEmpty)
                _ = await wait { !model.searching }
                check("catalog refresh commits complete content results", model.selectedID == contentSelection && model.hits.map(\.file.name) == ["Wumi-note.txt"])
                // A window that goes away keeps results and selection, and pauses work until it returns.
                model.setWindowVisible(false)
                check("window away keeps results", model.selectedID == contentSelection && model.hits.map(\.file.name) == ["Wumi-note.txt"] && !model.searching)
                model.setWindowVisible(true)
                check("window back keeps selection", model.selectedID == contentSelection && model.hits.map(\.file.name) == ["Wumi-note.txt"])
                model.query = "shuxue"
                model.setWindowVisible(false)
                check("window away pauses a pending search", !model.searching)
                model.setWindowVisible(true)
                check("window back finishes the search", await wait { !model.searching } && model.hits.contains { $0.file.name == "数学分析笔记.md" })
                model.scope = .content
                check("image OCR", await search("ORIGINAL_OCR_TOKEN").map(\.file.name) == ["ocr-proof.png"])
                model.scope = .all
                model.kind = .image
                check("kind filter", await search("proof").map(\.file.name) == ["ocr-proof.png"])
                model.kind = nil
                check("extension syntax", Set(await search("ext:pdf proof").map(\.file.name)) == ["pdf-proof.pdf", "offline-proof.pdf"])
                check("excluded words", await search("proof -pdf").map(\.file.name) == ["ocr-proof.png"])
                check("no results", await search("no-such-file-27913").isEmpty)
                for text in ["proof", "数学", "no-such-file-27913", "Wumi-note"] { model.query = text }
                _ = await wait { !model.searching }
                check("latest query owns results", model.hits.map(\.file.name) == ["Wumi-note.txt"])
                var revealed: URL?
                model.onReveal = { revealed = $0 }
                model.revealSelected()
                check("Wumi reveal callback", revealed?.lastPathComponent == "Wumi-note.txt")
                model.setPreviewVisible(true)
                check("stored content preview", await wait { model.previewText.contains("ORIGINAL_BODY_TOKEN") })
                let retainedPreview=model.previewText
                model.setPreviewVisible(true)
                check("same preview request does not reload", !model.previewLoading && model.previewText==retainedPreview)
                model.setWindowVisible(false)
                check("hidden preview releases text and PDF", model.previewText.isEmpty && model.previewPDF==nil && !model.searchPresented)
                model.setWindowVisible(true)
                check("preview resumes with visible window", await wait {model.previewText.contains("ORIGINAL_BODY_TOKEN")})
                model.setPreviewVisible(false)
                model.rootID = "offline"
                check("offline results retained", await search("proof").map(\.file.name) == ["offline-proof.pdf"])
                revealed = nil
                model.revealSelected()
                check("offline reveal disabled", revealed == nil)
                model.rootID = nil
                model.scope = .name
                model.sort = .size
                check("size sorting", await search("proof").map(\.file.size) == [400, 300, 200])
                model.context = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("files/Folder")
                model.currentFolderOnly = true
                let scoped = await search("scope")
                check("folder boundary excludes sibling paths", scoped.map(\.file.name) == ["scope-inside.txt"],
                      "paths=\(scoped.map(\.path)); roots=\(model.roots.map(\.path)); error=\(model.message ?? "")")
                model.currentFolderOnly=false;model.context=nil;model.sort = .relevance;model.scope = .all
                model.setPreviewVisible(true)
                _ = await search("MATCH_LINE_42")
                check("code preview locates indexed source line", await wait {model.previewLine==2})
                check("code context has line numbers", model.previewText.contains("2  MATCH_LINE_42"))
                let clipboard=NSPasteboard.withUniqueName()
                model.copySelectedFile(to:clipboard)
                check("copy file writes file URL", (clipboard.readObjects(forClasses:[NSURL.self]) as? [URL])?.first?.lastPathComponent=="location-demo.swift")
                clipboard.releaseGlobally()
                if let selected=model.selected {
                    try Data("File changed after indexing".utf8).write(to:URL(fileURLWithPath:selected.path))
                    model.setPreviewVisible(false);model.setPreviewVisible(true)
                    check("changed file does not expose old line", await wait {model.previewWarning?.contains("文件已变化")==true} && model.previewLine==nil)
                }
                _ = await search("PAGE_MATCH_723")
                check("PDF preview uses saved page map", await wait {model.previewPage==2} && model.previewPDF?.pageCount==2)
                let offlineRoot=IndexedRoot(id:"preview-offline",path:"/Volumes/Offline",isOnline:false)
                let offlineFile=FileRecord(id:9999,rootID:offlineRoot.id,relativePath:"pages.pdf",name:"pages.pdf",fileExtension:"pdf",kind:.document,size:1,modified:0)
                let offlineResolution=MijiPreviewResolver.resolve(hit:SearchHit(file:offlineFile,root:offlineRoot),content:ExtractedContent(text:"前😀\n\nPAGE_MATCH_723",pages:4,pageRanges:[ContentPageRange(page:4,utf8Offset:"前😀\n\n".utf8.count,utf8Length:14)]),query:"PAGE_MATCH_723 -unrelated ext:pdf",cancelled:{false})
                check("offline PDF keeps original page number", offlineResolution.page==4)
                check("preview excludes filters and negative terms", MijiPreviewResolver.terms(in:"PAGE_MATCH_723 -unrelated ext:pdf")==["page_match_723"])
                model.previewMode = .automatic
                model.scope = .name; model.kind = .application
                _ = await search("preview-contract")
                check("automatic applications use compact list", !model.previewVisible && model.panelWidth == 800)
                check("metadata skips content and file probes", !model.previewLoading && model.previewText.isEmpty && model.previewLocalURL == nil)
                model.previewMode = .shown
                check("manual shown displays metadata without loading", model.previewVisible && model.panelWidth == 1060 && !model.previewLoading && model.previewLocalURL == nil)
                model.previewMode = .hidden
                model.kind = .document
                _ = await search("preview-contract")
                check("manual hidden survives content search", !model.previewVisible && !model.previewLoading && model.previewText.isEmpty && model.panelWidth == 800)
                model.previewMode = .automatic
                check("automatic text preview resumes", await wait {model.previewText.contains("PREVIEW_CONTRACT_BODY")})
                model.kind = nil
                _ = await search("preview-contract")
                let mixedWidth=model.panelWidth, mixedHeight=model.panelHeight
                if let metadata=model.hits.first(where:{$0.file.kind == .application}),
                   let document=model.hits.first(where:{$0.file.kind == .document}) {
                    model.selectedID=metadata.id
                    check("mixed metadata retains pane dimensions", model.previewVisible && model.panelWidth==mixedWidth && model.panelHeight==mixedHeight && !model.previewLoading)
                    model.selectedID=document.id
                    _ = await wait {model.previewText.contains("PREVIEW_CONTRACT_BODY")}
                    check("mixed content retains pane dimensions", model.panelWidth==mixedWidth && model.panelHeight==mixedHeight)
                } else {check("mixed preview fixture", false)}
                model.previewMode = .hidden
                check("hidden cancels and releases preview", model.previewText.isEmpty && model.previewPDF==nil && model.previewLocalURL==nil && !model.previewLoading)
                let previewRoot=IndexedRoot(id:"policy",path:"/preview-policy")
                func policyHit(_ kind:FileKind,_ ext:String="",_ matched:String="文件名",_ snippet:String="")->SearchHit {
                    SearchHit(file:FileRecord(id:1,rootID:previewRoot.id,relativePath:"sample",name:"sample",fileExtension:ext,kind:kind,size:1,modified:0),root:previewRoot,snippet:snippet,matchedIn:matched)
                }
                check("empty results never reserve pane", !MijiSearchPreviewPolicy.showsPane(mode:.shown,hits:[]))
                check("metadata kinds remain compact", [.application,.folder,.archive,.other].allSatisfy {!MijiSearchPreviewPolicy.hasContent(policyHit($0))})
                check("valuable formats preserve pane", [.image,.document,.code,.audio,.video].allSatisfy {MijiSearchPreviewPolicy.hasContent(policyHit($0))})
                check("other body match can show text", MijiSearchPreviewPolicy.hasContent(policyHit(.other,"bin","正文","saved text")))
                check("plain text uses native text reader", MijiSearchPreviewPolicy.usesTextReader(policyHit(.document,"md")) && !MijiSearchPreviewPolicy.usesTextReader(policyHit(.document,"pdf")))
                let previewVerification=try SearchDatabase(url:URL(fileURLWithPath:path),readOnly:true)
                model.previewMode = .automatic;model.scope = .name;model.kind=nil
                for ext in ["txt","md"] {
                    for failed in [false,true] {
                        let name="unindexed-\(failed).\(ext)"
                        let before=try previewVerification.search(name,options:SearchOptions(scope:.name)).first!
                        let original=try Data(contentsOf:URL(fileURLWithPath:before.path))
                        _ = await search(name)
                        _ = await wait {!model.previewLoading && model.previewLocalURL != nil}
                        check("unindexed \(ext) \(failed) keeps original preview", model.previewVisible && model.previewText.isEmpty && model.previewLocalURL?.path==before.path && MijiSearchPreviewPolicy.usesSystemPreview(before,hasIndexedText:!model.previewText.isEmpty))
                        check("unindexed \(ext) \(failed) state stays unchanged", try previewVerification.storedContent(fileID:before.id)==nil && previewVerification.search(name,options:SearchOptions(scope:.name)).first?.file.contentState==before.file.contentState)
                        check("unindexed \(ext) \(failed) original stays unchanged", try Data(contentsOf:URL(fileURLWithPath:before.path))==original)
                    }
                }
                model.setSearchVisible(false)
                model.query = "数学"
                check("hidden model cancels search", !model.searching)
                check("collapsed panel height", MijiSearchModel.panelHeight(query: "", resultCount: 0) == 100)
                check("expanded panel height", MijiSearchModel.panelHeight(query: "a", resultCount: 9) == 563)
                let editor = NSTextView()
                editor.setMarkedText("shuxue", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                check("IME Return belongs to composition", MijiSearchKeyAction.action(for: enter, firstResponder: editor) == nil)
                editor.unmarkText()
                check("Return opens", MijiSearchKeyAction.action(for: enter, firstResponder: editor) == .open)
                let reveal = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                check("Command Return reveals", MijiSearchKeyAction.action(for: reveal, firstResponder: editor) == .reveal)
                let copy=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:0,windowNumber:0,context:nil,characters:"c",charactersIgnoringModifiers:"c",isARepeat:false,keyCode:8)!
                let pdfView=PDFView(),pdfChild=NSView();pdfView.addSubview(pdfChild)
                check("PDF text copy stays native", MijiSearchKeyAction.action(for:copy,firstResponder:pdfChild)==nil)
                check("input copy stays native", MijiSearchKeyAction.action(for:copy,firstResponder:editor)==nil)
                check("result copy copies file", MijiSearchKeyAction.action(for:copy,firstResponder:NSView()) == .copyFile)
            } catch { checks.append(["name": "fixture and model acceptance", "passed": false, "error": error.localizedDescription]) }
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let result: [String: Any] = ["checks": checks, "passed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("miji-acceptance.json"), options: .atomic)
            }
            try? Data().write(to: output.appendingPathComponent("miji-acceptance-done"))
            NSApp.terminate(nil)
        }
    }

    private static func fixture(databaseURL: URL) throws {
        let db = try SearchDatabase(url: databaseURL)
        let folder = databaseURL.deletingLastPathComponent().appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try db.saveRoot(IndexedRoot(id: "local", path: folder.path, name: "本地测试"))
        try db.saveRoot(IndexedRoot(id: "offline", path: "/Volumes/Wumi-Miji-Offline", name: "离线测试", isExternal: true, isOnline: false))
        for (name, root, kind, size, text) in [
            ("数学分析笔记.md", "local", FileKind.document, 100, "连续函数与极限"),
            ("Wumi-note.txt", "local", .document, 150, "ORIGINAL_BODY_TOKEN"),
            ("ocr-proof.png", "local", .image, 200, "ORIGINAL_OCR_TOKEN"),
            ("pdf-proof.pdf", "local", .document, 300, "PDF 提取正文"),
            ("Folder/scope-inside.txt", "local", .document, 20, "inside"),
            ("FolderSibling/scope-outside.txt", "local", .document, 20, "outside"),
            ("preview-contract.app", "local", .application, 100, ""),
            ("preview-contract-note.txt", "local", .document, 120, "PREVIEW_CONTRACT_BODY 原生预览正文"),
            ("offline-proof.pdf", "offline", .document, 400, "离线保存的正文")
        ] {
            let file = FileRecord(rootID: root, relativePath: name, name: (name as NSString).lastPathComponent,
                fileExtension: (name as NSString).pathExtension, kind: kind, size: Int64(size), modified: 1_792_598_400)
            try db.upsertFiles([file], generation: 1)
            if let saved = try db.catalogBatch(afterID: 0, limit: 100).first(where: { $0.file.rootID == root && $0.file.relativePath == name })?.file {
                _ = try db.completeContent(file: saved, content: ExtractedContent(text: text))
            }
            if root == "local" {
                let url = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }

        for ext in ["txt","md"] {
            for failed in [false,true] {
                let name="unindexed-\(failed).\(ext)",url=folder.appendingPathComponent("unindexed-\(failed).\(ext)")
                try Data("# Local original\nNot yet in the content index.".utf8).write(to:url)
                let signature=try FileSignature.read(url)
                try db.upsertFiles([FileRecord(rootID:"local",relativePath:name,name:name,fileExtension:ext,kind:.document,size:signature.size,modified:signature.modified,inode:signature.inode)],generation:1)
                if failed,let pending=try db.pendingFiles(rootID:"local").first(where:{$0.name==name}) {try db.failContent(file:pending,message:"fixture extraction failed")}
            }
        }
        let code=folder.appendingPathComponent("location-demo.swift")
        try Data("first\nMATCH_LINE_42 😀\nlast".utf8).write(to:code)
        let data=NSMutableData()
        let pdfConsumer=CGDataConsumer(data:data)!
        var box=CGRect(x:0,y:0,width:600,height:800)
        let drawing=CGContext(consumer:pdfConsumer,mediaBox:&box,nil)!
        for text in ["Cover", "PAGE_MATCH_723 on second page"] {
            drawing.beginPDFPage(nil);drawing.textMatrix = .identity;drawing.textPosition=CGPoint(x:40,y:600)
            let font=CTFontCreateWithName("Helvetica" as CFString,24,nil)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])),drawing)
            drawing.endPDFPage()
        }
        drawing.closePDF()
        let pdf=folder.appendingPathComponent("location-demo.pdf");try (data as Data).write(to:pdf)
        for url in [code,pdf] {
            let signature=try FileSignature.read(url)
            let file=FileRecord(rootID:"local",relativePath:url.lastPathComponent,name:url.lastPathComponent,fileExtension:url.pathExtension,kind:url.pathExtension=="swift" ? .code : .document,size:signature.size,modified:signature.modified,inode:signature.inode)
            try db.upsertFiles([file],generation:1)
            if let saved=try db.catalogBatch(afterID:0,limit:100).first(where:{$0.file.relativePath==url.lastPathComponent})?.file {
                let content=try ContentExtractor.extract(url:url,options:ExtractionOptions(ocrPDF:false))
                _ = try db.completeContent(file:saved,content:content)
            }
        }
    }
}
