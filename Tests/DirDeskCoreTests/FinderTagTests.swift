import XCTest
@testable import DirDeskCore

final class FinderTagTests: XCTestCase {
    private let favorites = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "灰色"]

    /// The original's sidebar with red, blue and 项目A in use: used tags first, then the other favorites.
    func testTagsInUseComeFirstInFavoriteOrder() {
        let order = FinderTagOrdering.order(inUse: ["项目A", "蓝色", "红色"], created: [], favorites: favorites, hidden: [])
        XCTAssertEqual(order, ["红色", "蓝色", "项目A", "橙色", "黄色", "绿色", "紫色", "灰色"])
    }

    func testCreatedTagsFollowUsedTagsAndHiddenTagsAreLeftOut() {
        let order = FinderTagOrdering.order(inUse: ["Beta", "Alpha"], created: ["New", "Alpha"], favorites: favorites, hidden: ["灰色", "Beta"])
        XCTAssertEqual(order, ["Alpha", "New", "红色", "橙色", "黄色", "绿色", "蓝色", "紫色"])
    }

    /// The original records deleted tags lowercased ("ddtesttag") and hides them whatever their case.
    func testHiddenTagsMatchCaseInsensitively() {
        let order = FinderTagOrdering.order(inUse: ["DDTestTag", "AATag"], created: [], favorites: [], hidden: ["ddtesttag"])
        XCTAssertEqual(order, ["AATag"])
    }

    /// Non-favorite tags in use sort by name the way the current locale does; the original (zh_CN) listed
    /// 项目A, AATag, B, BBBBBBBBBBBB, DDTestTag, Zz.
    func testTagsInUseFollowLocalizedNameOrder() {
        let names = ["DDTestTag", "AATag", "项目A", "B", "Zz", "BBBBBBBBBBBB"]
        let expected = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(FinderTagOrdering.order(inUse: names, created: [], favorites: [], hidden: []), expected)
    }

    func testTagQueryMatchesNameAndColorSuffixAndEscapesWildcards() {
        XCTAssertEqual(SpotlightQuery.tagQuery(name: "a*b?\"c", legacyLabel: nil),
                       #"(kMDItemUserTags == "a\*b\?\"c"cd || kMDItemUserTags == "a\*b\?\"c\n*"cd)"#)
        XCTAssertEqual(SpotlightQuery.tagQuery(name: "Red", legacyLabel: 6),
                       #"(kMDItemFSLabel == 6 || kMDItemUserTags == "Red"cd || kMDItemUserTags == "Red\n*"cd)"#)
    }
}
