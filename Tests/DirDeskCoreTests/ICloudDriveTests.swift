@testable import DirDeskCore
import XCTest

final class ICloudDriveTests: XCTestCase {
    func testDriveCombinesVisibleContainersAndRetainsRealURLs() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: scratch) }
        let mobile = scratch.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let root = mobile.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        let real = root.appendingPathComponent("Downloads", isDirectory: true)
        let app = mobile.appendingPathComponent("test~Visible/Documents", isDirectory: true)
        let hidden = mobile.appendingPathComponent(".test~Private/Documents", isDirectory: true)
        for folder in [real, app, hidden] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        // The Drive's own Documents symlink must not get re-added as an application container.
        try fm.createSymbolicLink(at: root.appendingPathComponent("Documents"), withDestinationURL: app)
        try Data("fixture".utf8).write(to: app.appendingPathComponent("example.txt"))

        let result = try DirectoryLoader.load(directory: URL(fileURLWithPath: root.path))
        let aliases = result.items.filter { $0.presentationRole == .navigationAlias }
        XCTAssertEqual(aliases.count, 1)
        XCTAssertEqual(aliases.first?.url.standardizedFileURL.path, app.standardizedFileURL.path)
        XCTAssertTrue(aliases.first?.isBrowsableFolder == true)
        XCTAssertFalse(aliases[0].allowsRenaming)
        XCTAssertTrue(result.items.first(where: { $0.name == "Downloads" })?.allowsRenaming == true)
        XCTAssertEqual(try DirectoryLoader.load(directory: aliases[0].url).items.map(\.name), ["example.txt"])
        XCTAssertTrue(result.items.contains { $0.url.standardizedFileURL.path == real.standardizedFileURL.path })
        XCTAssertFalse(result.items.contains { $0.url.standardizedFileURL.path == hidden.standardizedFileURL.path })
        XCTAssertEqual(DirectoryLoader.subfolders(of: root, includeHidden: false).folders.count, 2)
        XCTAssertTrue(try DirectoryLoader.load(directory: root, policy: .init(maximumItems: 1, batchSize: 1)).truncated)
        XCTAssertTrue(try DirectoryLoader.load(directory: root, isCancelled: { true }).items.isEmpty)
    }

    func testApplicationFolderParentAndBreadcrumbsFollowDrive() {
        let root = URL(fileURLWithPath: "/Users/test/Library/Mobile Documents/com~apple~CloudDocs")
        let app = URL(fileURLWithPath: "/Users/test/Library/Mobile Documents/iCloud~md~obsidian/Documents")
        XCTAssertEqual(ICloudDriveDirectory.browsingParent(of: app).path, root.path)
        let ancestors = PathUtilities.ancestors(of: app.appendingPathComponent("Vault"))
        XCTAssertEqual(Array(ancestors.suffix(3)).map(\.path), [root.path, app.path, app.appendingPathComponent("Vault").path])
        XCTAssertNil(ICloudDriveDirectory.root(forApplicationDocuments: root.appendingPathComponent("Documents")))
        XCTAssertFalse(ICloudDriveDirectory.isRoot(URL(fileURLWithPath: "/tmp/com~apple~CloudDocs")))
        XCTAssertFalse(DirectoryLoader.isCloudLocation(URL(fileURLWithPath: "/Users/test/Library/Mobile Documents Backup")))
    }

    func testCloudStateRequiresUploadAndCurrentCopyForGreenCheck() {
        func state(_ download: URLUbiquitousItemDownloadingStatus? = .current, uploaded: Bool? = true,
                   downloading: Bool = false, uploading: Bool = false, error: Bool = false,
                   ubiquitous: Bool? = true) -> FileCloudStatus? {
            FileCloudStatus.resolve(isUbiquitous: ubiquitous, downloadingStatus: download,
                                    isDownloading: downloading, isUploading: uploading,
                                    isUploaded: uploaded, hasError: error)
        }
        XCTAssertEqual(state(), .synchronized)
        XCTAssertEqual(state(.notDownloaded), .cloudOnly)
        XCTAssertEqual(state(.downloaded), .local, "A stale local copy must not show a green check")
        XCTAssertEqual(state(uploaded: false), .local)
        XCTAssertEqual(state(uploaded: nil), .local)
        XCTAssertEqual(state(downloading: true), .downloading)
        XCTAssertEqual(state(uploading: true), .uploading)
        XCTAssertEqual(state(uploading: true, error: true), .uploading, "iCloud retains previous errors during an active retry")
        XCTAssertEqual(state(downloading: true, error: true), .downloading)
        XCTAssertEqual(state(error: true), .failed, "A stopped transfer still reports its error")
        XCTAssertNil(state(ubiquitous: false))
        XCTAssertNil(state(ubiquitous: nil))

        XCTAssertTrue(FileCloudStatus.local.needsStatusRefresh)
        XCTAssertTrue(FileCloudStatus.downloading.needsStatusRefresh)
        XCTAssertTrue(FileCloudStatus.uploading.needsStatusRefresh)
        XCTAssertFalse(FileCloudStatus.synchronized.needsStatusRefresh)
        XCTAssertFalse(FileCloudStatus.failed.needsStatusRefresh)
        XCTAssertFalse(FileCloudStatus.cloudOnly.needsStatusRefresh)
    }

    func testStateOnlyChangesInvalidateFileEquality() {
        let original = FileItem(id: .init(fallbackPath: "/tmp/cloud"), url: URL(fileURLWithPath: "/tmp/cloud"),
                                name: "cloud", isDirectory: false, cloudStatus: .uploading)
        var updated = original
        updated.cloudStatus = .synchronized
        XCTAssertNotEqual(original, updated)
        XCTAssertNotEqual([original], [updated])
    }

    func testCloudStatusesOmitLocalFiles() throws {
        let file = try makeLocalMetadataFixture()
        XCTAssertTrue(DirectoryLoader.cloudStatuses(for: [file]).isEmpty)
    }

    func testCloudStatusesCancelledBeforeReadingAnyCandidate() {
        let urls = ["/tmp/first", "/tmp/second"].map { URL(fileURLWithPath: $0, isDirectory: false) }
        let statuses = DirectoryLoader.cloudStatuses(for: urls, isCancelled: { true }, resourceValuesReader: { _, _ in
            XCTFail("Cancellation must prevent every metadata read")
            return URLResourceValues()
        })
        XCTAssertTrue(statuses.isEmpty)
    }

    func testCloudStatusesCancellationStopsBetweenPaths() throws {
        let file = try makeLocalMetadataFixture()
        let next = file.appendingPathExtension("unread")
        var cancelled = false
        var readPaths: [String] = []
        let statuses = DirectoryLoader.cloudStatuses(for: [file, next], isCancelled: { cancelled }, resourceValuesReader: { url, _ in
            readPaths.append(url.path)
            cancelled = true
            return URLResourceValues()
        })
        XCTAssertEqual(readPaths, [file.standardizedFileURL.path])
        XCTAssertTrue(statuses.isEmpty)
    }

    func testCloudStatusesRequestOnlyCloudKeysAtStandardizedPaths() throws {
        let file = try makeLocalMetadataFixture()
        let candidate = URL(fileURLWithPath: file.deletingLastPathComponent().path + "/unused/../" + file.lastPathComponent,
                            isDirectory: false)
        var reads = 0
        let statuses = DirectoryLoader.cloudStatuses(for: [candidate], resourceValuesReader: { url, keys in
            reads += 1
            XCTAssertEqual(keys, Set(DirectoryLoader.cloudKeys))
            XCTAssertEqual(url.path, candidate.standardizedFileURL.path)
            return URLResourceValues()
        })
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(statuses.isEmpty)
    }

    func testCloudStatusesReadFreshCanonicalURLsOnEveryCall() throws {
        let file = try makeLocalMetadataFixture()
        // Exercise the same prefetched URL across refreshes, without injecting read-only cloud flags.
        let prefetched = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: DirectoryLoader.localKeys
        ).first { $0.standardizedFileURL.path == file.standardizedFileURL.path })
        let inputURL = prefetched as NSURL
        var receivedURLs: [NSURL] = []
        for _ in 0..<2 {
            let statuses = DirectoryLoader.cloudStatuses(for: [prefetched], resourceValuesReader: { url, keys in
                XCTAssertEqual(url.path, prefetched.standardizedFileURL.path)
                XCTAssertEqual(keys, Set(DirectoryLoader.cloudKeys))
                XCTAssertTrue(keys.isDisjoint(with: DirectoryLoader.localKeys), "Refreshes must not request the prefetched local keys")
                let received = url as NSURL
                XCTAssertFalse(received === inputURL, "The reader must not receive the prefetched URL instance")
                receivedURLs.append(received)
                return URLResourceValues()
            })
            XCTAssertTrue(statuses.isEmpty)
        }
        XCTAssertEqual(receivedURLs.count, 2, "Every refresh must call the reader")
        XCTAssertEqual(Set(receivedURLs.map { ObjectIdentifier($0) }).count, 2,
                       "Refreshes must supply independent URL instances")
    }

    func testCloudStatusesContinueAfterReadFailureAndOmitMissingStatus() throws {
        let file = try makeLocalMetadataFixture()
        let urls = [file.appendingPathExtension("failed"), file.appendingPathExtension("unknown"), file]
        var readPaths: [String] = []
        let statuses = DirectoryLoader.cloudStatuses(for: urls, resourceValuesReader: { url, _ in
            readPaths.append(url.path)
            if url == urls[0] { throw CocoaError(.fileReadNoPermission) }
            return URLResourceValues()
        })
        XCTAssertEqual(readPaths, urls.map { $0.standardizedFileURL.path })
        XCTAssertTrue(statuses.isEmpty)
    }

    private func makeLocalMetadataFixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dirdesk-cloud-metadata-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture", isDirectory: false)
        try Data().write(to: file)
        return file
    }

    /// Opt-in, metadata-only check against the signed-in user's real iCloud Drive.
    func testLiveDriveReadOnlyWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["DIRDESK_VERIFY_ICLOUD"] == "1" else {
            throw XCTSkip("Set DIRDESK_VERIFY_ICLOUD=1 for a read-only check of the real Drive")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let items = try DirectoryLoader.load(directory: root).items.filter { !$0.isHidden }
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.contains { $0.presentationRole == .navigationAlias })
        for item in items.sorted(by: { $0.name < $1.name }) {
            print("ICLOUD \(item.name) | \(item.cloudStatus?.rawValue ?? "unknown") | \(item.presentationRole.rawValue)")
            XCTAssertNotNil(item.cloudStatus, item.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path), item.name)
        }
        print("ICLOUD_VISIBLE_COUNT=\(items.count)")
    }
}
