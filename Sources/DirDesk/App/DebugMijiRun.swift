import AppKit
import DirDeskCore
import MijiCore
import PDFKit
import CoreText
import SwiftUI

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
                let early=MijiSearchModel();early.scope = .content;early.setSearchVisible(true);early.query="ORIGINAL_BODY_TOKEN"
                check("content query before host ready resumes without typing", await wait {early.hits.contains {$0.file.name=="Wumi-note.txt"} && !early.searching})
                early.setSearchVisible(false)
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
                let priorHit=model.hits.first!
                let priorSnapshot=model.displayedSnapshot
                model.query = "a different request"
                check("debounce retains dimmed rows but gates stale actions", model.searching && !model.isCurrentResult(priorHit,snapshot:priorSnapshot) && model.selectedID == nil)
                let staleBoard=NSPasteboard.withUniqueName()
                staleBoard.setString("unchanged",forType:.string)
                model.performFileAction(.copyPath,hit:priorHit,snapshot:priorSnapshot,pasteboard:staleBoard)
                check("stale context callback cannot copy a previous path",staleBoard.string(forType:.string)=="unchanged")
                staleBoard.releaseGlobally();model.message=nil
                check("pinyin", await search("shuxue").contains { $0.file.name == "数学分析笔记.md" })
                check("pinyin initials", await search("sxfx").contains { $0.file.name == "数学分析笔记.md" })
                var firstBatchActionable=false
                let phaseObserver=model.$searchPhase.sink { phase in
                    if phase == .supplementing, let hit=model.hits.first, model.isCurrentResult(hit) { firstBatchActionable=true }
                }
                _ = await search("数学分析")
                phaseObserver.cancel()
                check("current first batch remains actionable during body search",firstBatchActionable)
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
                check("complete results own current snapshot",model.currentSnapshot==model.displayedSnapshot && model.searchStatus.phase == .complete)
                check("first and completed timings are distinct and ordered",model.firstBatchMilliseconds != nil && model.completedMilliseconds != nil && model.completedMilliseconds! >= model.firstBatchMilliseconds!)
                let fresh=model.hits.first!
                let freshSnapshot=model.displayedSnapshot
                check("current readable file passes operation gate",model.fileOperationURL(for:fresh,action:.preview,snapshot:freshSnapshot)?.path==fresh.path)
                model.context=URL(fileURLWithPath:fresh.path).deletingLastPathComponent()
                model.currentFolderOnly=true
                check("current folder participates in snapshot and token",!model.isCurrentResult(fresh,snapshot:freshSnapshot) && model.currentSnapshot?.currentFolderOnly==true && model.activeFilters.contains {$0.id == .currentFolder})
                _ = await wait {!model.searching}
                model.kind = .document;model.scope = .name;model.sort = .size
                let savedQuery=model.query,savedPreview=model.previewMode,savedGrid=model.gridEnabled
                model.resetInterfaceFilters()
                check("reset keeps query and view preferences",model.query==savedQuery && model.previewMode==savedPreview && model.gridEnabled==savedGrid && model.activeFilters.isEmpty)
                _ = await wait {!model.searching}
                model.context=nil
                _ = await wait {!model.searching}
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
                if let offline=model.selected {
                    check("offline location names the volume",model.resultLocation(offline).short.contains("Wumi-Miji-Offline"))
                    check("offline availability is explicit",model.resultAvailability(offline).state == .diskOffline)
                    check("offline current path remains copyable",model.validateResult(offline,for:.copyPath))
                    check("offline media operation is denied",model.fileOperationURL(for:offline,action:.preview)==nil)
                }
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
                if let document=model.previewPDF,let page=document.page(at:1) {
                    let window=NSWindow(contentRect:NSRect(x:2000,y:100,width:440,height:190),styleMask:[.borderless],backing:.buffered,defer:false)
                    window.isReleasedWhenClosed=false
                    var hosted:NSHostingView<MijiPDFDocumentPreview>?=NSHostingView(rootView:MijiPDFDocumentPreview(document:document,page:2,terms:["PAGE_MATCH_723"]))
                    hosted?.sizingOptions=[];window.contentView=hosted;window.orderBack(nil)
                    func pdfView(in view:NSView)->PDFView? {
                        if let pdf=view as? PDFView {return pdf}
                        return view.subviews.compactMap {pdfView(in:$0)}.first
                    }
                    @MainActor func matchVisible()->Bool {
                        guard let hosted else {return false}
                        hosted.layoutSubtreeIfNeeded()
                        guard let pdf=pdfView(in:hosted),let selection=pdf.highlightedSelections?.first else {return false}
                        let rect=pdf.convert(selection.bounds(for:page),from:page)
                        return pdf.bounds.insetBy(dx:-1,dy:-1).contains(rect)
                    }
                    check("PDF match visible after initial compact viewport layout",await wait {matchVisible()})
                    window.setContentSize(NSSize(width:588,height:190))
                    check("PDF match stays visible after embedded viewport resize",await wait {matchVisible()})
                    weak var releasedPDF=hosted.flatMap {pdfView(in:$0)}
                    window.contentView=nil;hosted=nil;window.close()
                    check("detached PDF clears document target",await wait {releasedPDF?.document == nil})
                }
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
                let suiteName="Wumi.ReviewFixture."+UUID().uuidString
                let suite=UserDefaults(suiteName:suiteName)!
                defer {suite.removePersistentDomain(forName:suiteName)}
                check("absent legacy exclusions preserve migrated defaults", LightningSearchService.savedIgnoredFolders(defaults:suite,folders:["/legacy-default"]).isEmpty)
                suite.set(["/saved-exclusion"],forKey:LightningSearchService.ignoredFoldersKey)
                check("legacy exclusions apply before mapping marker exists", LightningSearchService.savedIgnoredFolders(defaults:suite,folders:["/saved-exclusion"])==["/saved-exclusion"])
                let deferred=LightningSearchService(defaults:suite)
                deferred.updateFolders(watched:["/fixture-next"],ignored:["/saved-exclusion"])
                check("pre-start folder save stays pending", deferred.foldersNeedApplication)
                let nextLaunch=LightningSearchService(defaults:suite)
                check("pending folder request survives next service", nextLaunch.foldersNeedApplication && nextLaunch.watchedFolders==["/fixture-next"])
                check("unacknowledged failed launch keeps request", suite.bool(forKey:LightningSearchService.pendingFoldersKey))
                nextLaunch.didApplyFolders(watched:["/stale"],ignored:[])
                check("stale launch cannot clear newer request", nextLaunch.foldersNeedApplication)
                nextLaunch.didApplyFolders(watched:nextLaunch.watchedFolders,ignored:nextLaunch.ignoredFolders)
                check("successful matching application clears pending", !nextLaunch.foldersNeedApplication)
                let failedLaunch=LightningSearchService(defaults:suite,hostFactory:{_,_,_,_ in throw SearchDatabaseError(message:"fixture launch failure")})
                failedLaunch.updateFolders(watched:["/fixture-failed"],ignored:[])
                failedLaunch.ensureStarted()
                check("failed host launch keeps persisted folder request", await wait {!failedLaunch.isStarted} && failedLaunch.foldersNeedApplication && failedLaunch.status.lastError=="fixture launch failure")
                let pendingDB=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("handoff.sqlite")
                _ = try SearchDatabase(url:pendingDB)
                let pending=PendingMijiHost();var originalOptions=IndexingPreferences();originalOptions.retainOffline=true
                pending.configure(originalOptions)
                var editedOptions=originalOptions;editedOptions.retainOffline=false
                pending.configure(editedOptions)
                let loadingHost=try MijiIndexHost(databaseURL:pendingDB,readOnly:true);pending.store(loadingHost)
                try loadingHost.start(watchedFolders:[],ignoredFolders:[],preferences:originalOptions)
                check("options edited during loading beat launch snapshot", !loadingHost.engine.retainsOffline)
                pending.configure(originalOptions)
                check("options edited before main handoff reach pending host", loadingHost.engine.retainsOffline)
                pending.take()?.shutdown()
                let replacementDB=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("replacement.sqlite")
                _ = try SearchDatabase(url:replacementDB)
                let replacementQueue=DispatchQueue(label:"wumi.fixture.host-replacement")
                let constructed=PendingMijiHost()
                let replacing=LightningSearchService(defaults:suite,setupQueue:replacementQueue,hostFactory:{_,_,_,_ in
                    let host=try MijiIndexHost(databaseURL:replacementDB,readOnly:true)
                    constructed.store(host);return host
                })
                replacing.ensureStarted()
                // Keep MainActor in this turn while the first setup enqueues its
                // installation. The next explicit save runs before that handoff.
                replacementQueue.sync {}
                let predecessor=constructed.take()
                replacing.updateFolders(watched:["/fixture-latest"],ignored:["/latest-exclusion"])
                var newestOptions=replacing.indexingPreferences;newestOptions.retainOffline=false
                replacing.updateIndexingPreferences(newestOptions)
                replacementQueue.sync {}
                let successor=constructed.take()
                check("pending predecessor exits before successor takes same lease", await wait {
                    successor != nil && replacing.engine === successor?.engine && replacing.status.lastError==nil
                    && replacing.watchedFolders==["/fixture-latest"] && replacing.engine?.retainsOffline==false
                })
                replacementQueue.sync {} // Includes the late canceled first MainActor task's cleanup.
                var successorKeepsLease=false
                do {let unexpected=try MijiIndexHost(databaseURL:replacementDB,readOnly:true);unexpected.shutdown()}
                catch {successorKeepsLease=true}
                check("late canceled handoff preserves live successor lease", predecessor != nil && successorKeepsLease && replacing.engine === successor?.engine)
                replacing.shutdown()
                let releasedSuccessor=try MijiIndexHost(databaseURL:replacementDB,readOnly:true)
                check("serial shutdown releases installed handoff lease", replacing.engine==nil)
                releasedSuccessor.shutdown()
                let writer=try SearchDatabase(url:URL(fileURLWithPath:path))
                // Review regressions use the actual model and explicit scratch catalog.
                let localRoot=try writer.roots().first {$0.id=="local"}!
                let pausedPath=URL(fileURLWithPath:localRoot.path).appendingPathComponent("paused-review")
                try FileManager.default.createDirectory(at:pausedPath,withIntermediateDirectories:true)
                let pausedRoot=IndexedRoot(id:"paused-review",path:pausedPath.path,enabled:false)
                try writer.saveRoot(pausedRoot)
                for name in ["paused-retained-a.txt","paused-retained-b.txt"] {
                    let url=pausedPath.appendingPathComponent(name)
                    try Data("PAUSED_BODY_TOKEN".utf8).write(to:url)
                    try writer.upsertFiles([FileRecord(rootID:pausedRoot.id,relativePath:name,name:name,fileExtension:"txt",kind:.document,size:17,modified:1)],generation:1)
                    let row=try writer.pendingFiles(rootID:pausedRoot.id).first!
                    _ = try writer.completeContent(file:row,content:ExtractedContent(text:"PAUSED_BODY_TOKEN"))
                }
                try service.engine?.names.refresh(rootID:pausedRoot.id,relativePaths:[""],fullRescan:true)
                service.catalogDidChange(contentChanged:true)
                _ = await wait {model.roots.contains {$0.id==pausedRoot.id}}
                model.rootID=pausedRoot.id;model.scope = .name;model.sort = .name;model.previewMode = .shown
                _ = await search("paused-retained")
                check("review paused root new query keeps retained rows",model.hits.count==2)
                if let first=model.hits.first {
                    check("review paused root current result is actionable",model.isCurrentResult(first) && model.validateResult(first,for:.open))
                    model.moveSelection(1)
                    check("review paused root keyboard selection moves",model.selectedID==model.hits.last?.id)
                    let board=NSPasteboard.withUniqueName()
                    model.performFileAction(.copyPath,pasteboard:board)
                    check("review paused root copies current path",board.string(forType:.string)==model.selected?.path)
                    board.releaseGlobally()
                    check("review paused root preview loads indexed text",await wait {model.previewText.contains("PAUSED_BODY_TOKEN")})
                } else {check("review paused root result fixture",false)}
                model.context=URL(fileURLWithPath:pausedRoot.path);model.currentFolderOnly=true
                let pausedScoped=await search("paused-retained")
                check("review paused root current-folder query keeps retained rows",pausedScoped.count==2 && pausedScoped.allSatisfy {model.isCurrentResult($0)})
                model.currentFolderOnly=false;model.context=nil
                model.message=nil;model.previewMode = .hidden;model.rootID=nil;model.sort = .relevance
                // A provider can expose a real metadata path while refusing local data,
                // as SF_DATALESS/not-downloaded iCloud items do. No live cloud item is changed.
                let cloud=MijiSearchModel(localPreviewURL:{_ in nil})
                cloud.previewMode = .hidden;cloud.scope = .name;cloud.rootID="local";cloud.setSearchVisible(true);cloud.query="Wumi-note"
                _ = await wait {!cloud.searching && !cloud.hits.isEmpty}
                if let hit=cloud.selected {
                    check("review placeholder fixture exists but has no local preview",FileManager.default.fileExists(atPath:hit.path) && cloud.resultAvailability(hit).state == .fileUnavailable)
                    check("review placeholder metadata reveal allowed",cloud.canPerformFileAction(.reveal,hit:hit))
                    check("review placeholder Finder reveal allowed",cloud.fileOperationURL(for:hit,action:.revealInFinder)?.path==hit.path)
                    check("review placeholder explicit open allowed",cloud.canPerformFileAction(.open,hit:hit))
                    var revealed:URL?
                    cloud.onReveal={revealed=$0};cloud.revealSelected()
                    check("review placeholder Command-R route reveals metadata",revealed?.path==hit.path)
                    check("review placeholder preview playback and Quick Look stay blocked",!cloud.canPerformFileAction(.preview,hit:hit) && !cloud.canPerformFileAction(.quickLook,hit:hit) && !cloud.canPerformFileAction(.copyFile,hit:hit))
                    do {
                        let original=URL(fileURLWithPath:hit.path),moved=URL(fileURLWithPath:hit.path+".metadata-test")
                        try FileManager.default.moveItem(at:original,to:moved)
                        defer {try? FileManager.default.moveItem(at:moved,to:original)}
                        check("review missing placeholder path blocks metadata actions",!cloud.canPerformFileAction(.reveal,hit:hit) && !cloud.canPerformFileAction(.open,hit:hit))
                    }
                    cloud.query="changed"
                    check("review placeholder stale snapshot remains blocked",!cloud.canPerformFileAction(.reveal,hit:hit))
                } else {check("review placeholder result fixture",false)}
                cloud.setSearchVisible(false)
                // The path: substring admits Other/Docs; only the absolute boundary
                // distinguishes it from Docs. Older target must survive top-K expansion.
                var scopedFiles:[FileRecord]=[]
                for i in 0..<650 {
                    scopedFiles.append(FileRecord(rootID:"local",relativePath:"Other/Docs/noise-\(i).txt",name:"noise-\(i).txt",fileExtension:"txt",kind:.document,size:1,modified:Double(1000+i)))
                }
                scopedFiles.append(FileRecord(rootID:"local",relativePath:"Docs/older-target.txt",name:"older-target.txt",fileExtension:"txt",kind:.document,size:1,modified:1))
                try writer.upsertFiles(scopedFiles,generation:1)
                for row in try writer.pendingFiles(rootID:"local",limit:1000) where row.name.hasPrefix("noise-") || row.name=="older-target.txt" {
                    _ = try writer.completeContent(file:row,content:ExtractedContent(text:"SCOPED_BODY_REVIEW_TOKEN"))
                }
                try service.engine?.names.refresh(rootID:"local",relativePaths:[""],fullRescan:true)
                service.catalogDidChange(contentChanged:true)
                model.context=URL(fileURLWithPath:localRoot.path).appendingPathComponent("Docs");model.currentFolderOnly=true;model.sort = .modified
                for queryScope in [SearchScope.content,.all] {
                    model.scope=queryScope
                    let scoped=await search("SCOPED_BODY_REVIEW_TOKEN")
                    check("review \(queryScope) folder expansion survives 650 newer substring distractors",scoped.map(\.file.relativePath)==["Docs/older-target.txt"])
                    check("review \(queryScope) expanded complete folder search is not budget-limited",!model.searchLimited)
                }
                model.currentFolderOnly=false;model.context=nil;model.sort = .relevance;model.scope = .all;model.message=nil
                try writer.removeRoot(id:pausedRoot.id);service.catalogDidChange(contentChanged:true)
                let refreshedFile=try writer.search("Wumi-note",options:SearchOptions(scope:.name)).first!.file
                model.previewMode = .automatic;model.scope = .content;model.currentFolderOnly=false;model.rootID=nil;model.kind=nil
                _ = await search("REFRESH_SEARCH_TOKEN")
                check("new body token begins absent", model.hits.isEmpty)
                _ = try writer.completeContent(file:refreshedFile,content:ExtractedContent(text:"REFRESH_SEARCH_TOKEN"))
                let generation=service.contentGeneration
                for _ in 0..<20 {service.catalogDidChange(contentChanged:true)}
                check("body completion refreshes unchanged query", await wait {model.hits.contains {$0.id==refreshedFile.id} && !model.searching})
                check("content notifications coalesce", service.contentGeneration==generation+1)
                _ = try writer.completeContent(file:refreshedFile,content:ExtractedContent(text:"removed keyword"));service.catalogDidChange(contentChanged:true)
                check("removed body keyword clears content results", await wait {model.hits.isEmpty && !model.searching})
                model.scope = .all
                _ = await search("REFRESH_SEARCH_TOKEN")
                _ = try writer.completeContent(file:refreshedFile,content:ExtractedContent(text:"REFRESH_SEARCH_TOKEN fresh snippet"));service.catalogDidChange(contentChanged:true)
                check("all scope refreshes new supplementary match", await wait {model.hits.contains {$0.id==refreshedFile.id} && !model.searching})
                _ = try writer.completeContent(file:refreshedFile,content:ExtractedContent(text:"removed keyword again"));service.catalogDidChange(contentChanged:true)
                check("all scope drops stale supplementary IDs and snippets", await wait {model.hits.isEmpty && !model.searching})
                model.setWindowVisible(false)
                _ = try writer.completeContent(file:refreshedFile,content:ExtractedContent(text:"REFRESH_SEARCH_TOKEN"));service.catalogDidChange(contentChanged:true)
                _ = await wait {service.contentGeneration>generation+4}
                check("hidden session does not query content notifications", !model.searching && model.hits.isEmpty)
                model.setWindowVisible(true)
                check("visible session catches changed body", await wait {model.hits.contains {$0.id==refreshedFile.id} && !model.searching})
                _ = try writer.completeContent(file:refreshedFile,content:ExtractedContent(text:"ORIGINAL_BODY_TOKEN"))
                var external=IndexedRoot(id:"mount-refresh",path:"/Volumes/OldFixture",name:"Mount fixture",isExternal:true,isOnline:true)
                try writer.saveRoot(external)
                try writer.upsertFiles([FileRecord(rootID:external.id,relativePath:"Folder/volume-scope.txt",name:"volume-scope.txt",fileExtension:"txt",kind:.document,size:1,modified:0)],generation:1)
                try service.engine?.names.refresh(rootID:external.id,relativePaths:[""],fullRescan:true)
                service.catalogDidChange()
                check("running root additions reach sessions", await wait {model.roots.contains {$0.id==external.id}})
                model.scope = .name;model.context=URL(fileURLWithPath:"/Volumes/NewFixture/Folder");model.currentFolderOnly=true
                _ = await search("volume-scope")
                check("new mount location initially excluded", model.hits.isEmpty)
                external.path="/Volumes/NewFixture";try writer.saveRoot(external);service.catalogDidChange()
                check("changed mount path replans current folder", await wait {model.hits.contains {$0.file.name=="volume-scope.txt"} && !model.searching})
                try writer.removeRoot(id:external.id);service.catalogDidChange()
                model.currentFolderOnly=false;model.context=nil;model.scope = .name
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
                let nativeOriginal=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("files/unindexed-false.txt")
                let scratchSessions=WorkspaceSessionStore(directory:output.deletingLastPathComponent().appendingPathComponent("preview-close-sessions"))
                func previewContainer(in view:NSView)->MijiQuickLookContainer? {
                    if let found=view as? MijiQuickLookContainer {return found}
                    return view.subviews.compactMap {previewContainer(in:$0)}.first
                }
                for cycle in 1...2 {
                    var controller:WorkspaceController?=WorkspaceController(model:WorkspaceModel(directory:nativeOriginal.deletingLastPathComponent(),store:scratchSessions))
                    weak var closedWindow=controller?.window
                    var hosted:NSHostingController<MijiSystemFilePreview>?=NSHostingController(rootView:MijiSystemFilePreview(url:nativeOriginal))
                    weak var closedHost=hosted
                    controller?.window?.contentViewController=hosted
                    controller?.window?.setFrameOrigin(NSPoint(x:2000,y:100));controller?.window?.orderBack(nil)
                    let mounted=await wait {hosted.map {previewContainer(in:$0.view)?.preview.previewItem != nil} ?? false}
                    weak var closedPreview=hosted.flatMap {previewContainer(in:$0.view)}
                    weak var closedNative=closedPreview?.preview
                    check("native original mounts after reopen \(cycle)", mounted && closedPreview != nil)
                    hosted=nil;controller?.close();controller=nil
                    check("workspace close releases native preview and host \(cycle)", await wait {closedHost==nil && closedPreview==nil && closedNative==nil && closedWindow==nil})
                }
                // Use the real scanner with extraction disabled; a signature change
                // detaches stored text even when no extractor will later notify us.
                let scannedRoot=try writer.roots().first(where:{$0.id=="local"})!
                let scannedURL=URL(fileURLWithPath:scannedRoot.path).appendingPathComponent("Wumi-note.txt")
                for queryScope in [SearchScope.content,.all] {
                    _ = try FileScanner(database:writer).scan(root:scannedRoot,relativePath:"Wumi-note.txt")
                    let scannedFile=try writer.search("Wumi-note",options:SearchOptions(scope:.name)).first!.file
                    _ = try writer.completeContent(file:scannedFile,content:ExtractedContent(text:"SCAN_REMOVED_BODY_TOKEN"))
                    service.catalogDidChange(contentChanged:true)
                    model.scope=queryScope;model.rootID=nil;model.currentFolderOnly=false
                    _ = await search("SCAN_REMOVED_BODY_TOKEN")
                    check("\(queryScope) scan fixture starts with stored body", await wait {model.hits.contains {$0.id==scannedFile.id} && !model.searching})
                    try Data("changed original without the prior token \(queryScope)".utf8).write(to:scannedURL)
                    let runtime=IndexService(database:writer)
                    runtime.onContentChange={Task { @MainActor in service.catalogDidChange(contentChanged:true)}}
                    runtime.onIndexChange={_ in Task { @MainActor in service.catalogDidChange()}}
                    var noExtraction=IndexingPreferences();noExtraction.autoAddExternal=false;noExtraction.documents=false;noExtraction.images=false
                    runtime.configure(noExtraction);runtime.requestScan()
                    let cleared=await wait {model.hits.isEmpty && !model.searching}
                    runtime.stopAndWait()
                    let storedAfterScan=try writer.storedContent(fileID:scannedFile.id)
                    check("\(queryScope) unchanged query drops body cleared by scan", cleared && storedAfterScan==nil)
                    check("\(queryScope) cleared body stays pending with extraction disabled", try writer.search("Wumi-note",options:SearchOptions(scope:.name)).first?.file.contentState=="pending")
                }
                model.setSearchVisible(false)
                let closedGeneration=service.contentGeneration
                for _ in 0..<20 {service.catalogDidChange(contentChanged:true)}
                _ = await wait {service.contentGeneration>closedGeneration}
                check("closed model stays idle after merged content invalidation", model.hits.isEmpty && !model.searching && model.previewText.isEmpty && model.previewPDF==nil)
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
