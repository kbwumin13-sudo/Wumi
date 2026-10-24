import XCTest
@testable import DirDeskCore

final class FolderHandlerPreferencesTests: XCTestCase {
    private let app = "com.fixture.wumi"
    private let folder: [String: Any] = ["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": "com.apple.finder",
                                         "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"]]
    private let text: [String: Any] = ["LSHandlerContentType": "public.plain-text", "LSHandlerRoleAll": "com.fixture.editor"]
    func testRequestReplacesFolderEntriesWithoutChangingOtherTypes() {
        let rows = FolderHandlerPreferences.requesting(app, in: [folder, text, folder])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0] as NSDictionary, text as NSDictionary)
        XCTAssertEqual(rows[1]["LSHandlerRoleAll"] as? String, app)
        XCTAssertEqual(FolderHandlerPreferences.requesting(app, in: rows) as NSArray, rows as NSArray)
    }
    func testRestorePreservesExactPriorFolderPayloadAndNewUnrelatedPreferences() {
        let prior = FolderHandlerPreferences.folderEntries(in: [folder, text])
        let image: [String: Any] = ["LSHandlerContentType": "public.png", "LSHandlerRoleAll": "com.fixture.image"]
        let configured = FolderHandlerPreferences.requesting(app, in: [folder, text]) + [image]
        let restored = FolderHandlerPreferences.restoring(prior, replacing: app, in: configured)
        XCTAssertEqual(restored as NSArray, [text, image, folder] as NSArray)
    }
    func testRestoreDoesNotOverrideAChangedFolderChoice() {
        let other: [String: Any] = ["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": "com.fixture.other"]
        XCTAssertEqual(FolderHandlerPreferences.restoring([folder], replacing: app, in: [text, other]) as NSArray,
                       [text, other] as NSArray)
    }
    func testAbsentPriorFolderSettingIsRemovedAgain() {
        let configured = FolderHandlerPreferences.requesting(app, in: [text])
        XCTAssertEqual(FolderHandlerPreferences.restoring([], replacing: app, in: configured) as NSArray, [text] as NSArray)
    }
}
