import XCTest
@testable import DirDeskCore

final class LightningVisualTests: XCTestCase {
    private func expression(_ configure: (inout LightningVisualQuery) -> Void, home: String = "/Users/test") -> LightningVisualCompilation {
        var query = LightningVisualQuery()
        configure(&query)
        return query.compile(homeDirectory: home)
    }

    private func conditions(matchesAll: Bool = true, _ items: [LightningConditionNode]) -> LightningConditionGroup {
        LightningConditionGroup(matchesAll: matchesAll, items: items)
    }

    private func condition(_ field: LightningConditionField, _ comparison: LightningConditionComparison? = nil, _ value: String = "",
                           second: String = "", unit: LightningVisualSizeUnit = .megabytes, day: LightningVisualDay? = nil,
                           secondDay: LightningVisualDay? = nil, enabled: Bool = true, excluded: Bool = false) -> LightningConditionNode {
        .condition(LightningCondition(isEnabled: enabled, isExcluded: excluded, field: field, comparison: comparison, value: value,
                                      secondValue: second, unit: unit, day: day, secondDay: secondDay))
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> LightningVisualDay {
        LightningVisualDay(year: year, month: month, day: day)
    }

    // MARK: Compilation

    func testEmptyQueryCompilesToNothing() {
        let compiled = LightningVisualQuery().compile()
        XCTAssertEqual(compiled.expression, "")
        XCTAssertEqual(compiled.issues, [])
        XCTAssertFalse(LightningVisualQuery(text: "report").hasFilters)
        // Match Case alone does not turn an empty search into "everything".
        XCTAssertEqual(expression { $0.matchCase = true }.expression, "")
    }

    func testSearchWordsAreLiteral() throws {
        XCTAssertEqual(expression { $0.text = "  report 2026 " }.expression, "report 2026")
        XCTAssertEqual(expression { $0.text = "\"annual report\" draft" }.expression, "\"annual report\" draft")
        XCTAssertEqual(expression { $0.text = "a*b" }.expression, #"regex:"a\*b""#)
        XCTAssertEqual(expression { $0.text = "IMG_????" }.expression, #"regex:"IMG_\?\?\?\?""#)
        XCTAssertEqual(expression { $0.text = "AND" }.expression, "\"AND\"")
        XCTAssertEqual(expression { $0.text = "a:b x|y (tmp) !draft" }.expression, "\"a:b\" \"x|y\" \"(tmp)\" \"!draft\"")
        XCTAssertEqual(expression { $0.text = "photos/2026" }.expression, "photos/2026")
        XCTAssertEqual(expression { $0.text = "报告 Café" }.expression, "报告 Café")
        XCTAssertEqual(try LightningQueryParser.parse(expression { $0.text = "a:b x|y" }.expression),
                       .and([.term(LightningTerm("a:b")), .term(LightningTerm("x|y"))]))
        XCTAssertEqual(try LightningQueryParser.parse(expression { $0.text = "a*b" }.expression), .filter(.regex(#"a\*b"#)))
    }

    func testFilterBar() throws {
        let compiled = expression {
            $0.text = "report"
            $0.kinds = [.video, .image, .folder]
            $0.date = .pastWeek
            $0.tags = ["Red", "Work Stuff"]
            $0.matchCase = true
        }
        // Match Case is passed to the engine separately, so it is not part of the expression.
        XCTAssertEqual(compiled.expression, "report type:picture;video;folder dm:pastweek tagexact:Red;\"Work Stuff\"")
        XCTAssertEqual(try LightningQueryParser.parse(compiled.expression), .and([
            .term(LightningTerm("report")),
            .filter(.type([.picture, .video, .folder])),
            .filter(.dateModified([.compare(.equal, .pastWeek)])),
            .filter(.tagExact(["Red", "Work Stuff"])),
        ]))
        XCTAssertEqual(expression { $0.kinds = [.application, .document] }.expression, "type:doc OR ext:app")
        XCTAssertEqual(expression { $0.text = "x"; $0.kinds = [.application, .code] }.expression, "x (type:code OR ext:app)")
        XCTAssertEqual(expression { $0.kinds = [.application] }.expression, "ext:app")
        XCTAssertEqual(expression { $0.kinds = [.folder, .file] }.expression, "type:file;folder")
        XCTAssertEqual(expression { $0.kinds = [.pdf]; $0.date = .today }.expression, "type:pdf dm:today")
        XCTAssertEqual(expression { $0.date = .thisYear }.expression, "dm:thisyear")
        for kind in LightningVisualKind.allCases {
            XCTAssertNoThrow(try LightningQueryParser.parse(expression { $0.kinds = [kind] }.expression))
        }
    }

    func testTextCanMatchFileContents() throws {
        XCTAssertEqual(expression { $0.text = "budget 2026"; $0.textTarget = .contents }.expression, "content:budget content:2026")
        let phrase = expression { $0.text = "\"to do\" a;b"; $0.textTarget = .contents }
        XCTAssertEqual(phrase.expression, "content:\"to do\" content:\"a;b\"")
        XCTAssertEqual(try LightningQueryParser.parse(phrase.expression),
                       .and([.filter(.content(["to do"])), .filter(.content(["a;b"]))]))
        var query = LightningVisualQuery(text: "x")
        XCTAssertFalse(query.hasFilters)
        query.textTarget = .contents
        XCTAssertTrue(query.hasFilters)
        query.resetFilters()
        XCTAssertEqual(query.textTarget, .name)
        XCTAssertEqual(query.text, "x")
    }

    func testCustomDates() {
        let range = expression {
            $0.date = .custom
            $0.customStart = day(2026, 1, 1)
            $0.customEnd = day(2026, 3, 31)
        }
        XCTAssertEqual(range.expression, "dm:2026-01-01..2026-03-31")
        XCTAssertEqual(expression { $0.date = .custom; $0.customStart = day(2026, 2, 3) }.expression, "dm:>=2026-02-03")
        XCTAssertEqual(expression { $0.date = .custom; $0.customEnd = day(2026, 2, 3) }.expression, "dm:<=2026-02-03")
        XCTAssertEqual(expression { $0.date = .custom }.expression, "")
        let reversed = expression {
            $0.date = .custom
            $0.customStart = day(2026, 3, 1)
            $0.customEnd = day(2026, 2, 1)
        }
        XCTAssertEqual(reversed.expression, "")
        XCTAssertEqual(reversed.issues, [LightningVisualIssue(.reversedRange)])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let picked = LightningVisualDay(Date(timeIntervalSince1970: 1_773_835_200), calendar: utc)
        XCTAssertEqual(picked, day(2026, 3, 18))
        XCTAssertEqual(picked.date(in: utc), Date(timeIntervalSince1970: 1_773_792_000))
    }

    func testNameAndTextConditions() {
        XCTAssertEqual(expression {
            $0.conditions = conditions([condition(.name, .starts, "Report"), condition(.name, .ends, "2026")])
        }.expression, "/Report 2026/")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.name, .equals, "notes.md")]) }.expression, "/notes.md/")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.name, .equals, "my notes.md")]) }.expression, "\"/my notes.md/\"")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.name, .equals, "a*b.txt")]) }.expression, #"regex:"^a\*b\.txt$""#)
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.name, .starts, "say \"hi\"")]) }.expression,
                       #"regex:"^say \x22hi\x22""#)
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.name, .equals, "/src/app/")]) }.expression, "/src/app/")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.contents, nil, "TODO: fix; later")]) }.expression,
                       "content:\"TODO: fix; later\"")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.tag, nil, "Work; Home")]) }.expression, "tag:Work;Home")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.extension, nil, ".JPG, png ;;")]) }.expression, "ext:jpg;png")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.regex, nil, #"^IMG_\d+\.(jpe?g|png)$"#)]) }.expression,
                       #"regex:"^IMG_\d+\.(jpe?g|png)$""#)
        let invalid = expression { $0.conditions = conditions([condition(.regex, nil, "(")]) }
        XCTAssertEqual(invalid.expression, "")
        XCTAssertEqual(invalid.issues.map(\.kind), [.invalidRegularExpression])
    }

    func testSizeDateAndFolderConditions() {
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.size, .greater, "1.5")]) }.expression, "size:>1.5MB")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.size, .atMost, "1,25", unit: .gigabytes)]) }.expression,
                       "size:<=1.25GB")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.size, .equals, "0", unit: .bytes)]) }.expression, "size:0B")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.size, .between, "10", second: "200", unit: .kilobytes)]) }.expression,
                       "size:10KB..200KB")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.size, .between, "2", second: "1")]) }.issues.map(\.kind),
                       [.reversedRange])
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.size, .less, "-1")]) }.issues.map(\.kind), [.invalidSize])
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.size, .less, "1e3")]) }.issues.map(\.kind), [.invalidSize])
        let march = day(2026, 3, 1), end = day(2026, 3, 31)
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.modified, .less, day: march)]) }.expression, "dm:<2026-03-01")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.created, .atLeast, day: march)]) }.expression, "dc:>=2026-03-01")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.modified, .between, day: march, secondDay: end)]) }.expression,
                       "dm:2026-03-01..2026-03-31")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.modified, .between, day: end, secondDay: march)]) }.issues.map(\.kind),
                       [.reversedRange])
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.modified, .equals, day: day(2026, 2, 30))]) }.issues.map(\.kind),
                       [.invalidDate])
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.folder, .descendants, "~/Documents/")]) }.expression,
                       "infolder:~/Documents")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.folder, .children, "/tmp/My Files/")]) }.expression,
                       "nosubfolders:\"/tmp/My Files\"")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.folder, .directFiles, "~/Desktop")]) }.expression,
                       "/Users/test/Desktop/ OR (nosubfolders:~/Desktop file:)")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.folder, .directFiles, "/")]) }.expression, "nosubfolders:/ file:")
        XCTAssertEqual(expression { $0.conditions = conditions([condition(.folder, .descendants, "Documents")]) }.issues.map(\.kind),
                       [.invalidFolder])
    }

    func testGroupsAndExclusion() throws {
        XCTAssertEqual(expression {
            $0.text = "report"
            $0.conditions = conditions(matchesAll: false, [condition(.extension, nil, "pdf"), condition(.extension, nil, "docx")])
        }.expression, "report (ext:pdf OR ext:docx)")
        let excluded = LightningConditionGroup(matchesAll: false, isExcluded: true,
                                               items: [condition(.extension, nil, "zip"), condition(.extension, nil, "rar")])
        let nested = expression {
            $0.conditions = conditions([condition(.contents, nil, "TODO"), .group(excluded)])
        }
        XCTAssertEqual(nested.expression, "content:TODO NOT (ext:zip OR ext:rar)")
        XCTAssertEqual(try LightningQueryParser.parse(nested.expression), .and([
            .filter(.content(["TODO"])),
            .not(.or([.filter(.extension(["zip"])), .filter(.extension(["rar"]))])),
        ]))
        let single = LightningConditionGroup(isExcluded: true, items: [condition(.extension, nil, "zip")])
        XCTAssertEqual(expression { $0.conditions = conditions([.group(single)]) }.expression, "NOT ext:zip")
        // Exclude on one condition, and on the top-level group itself.
        XCTAssertEqual(expression {
            $0.conditions = conditions([condition(.extension, nil, "zip", excluded: true), condition(.name, .contains, "a")])
        }.expression, "NOT ext:zip a")
        let excludedRoot = expression {
            $0.text = "x"
            $0.conditions = LightningConditionGroup(isExcluded: true, items: [condition(.extension, nil, "pdf"), condition(.name, .contains, "b")])
        }
        XCTAssertEqual(excludedRoot.expression, "x NOT (ext:pdf b)")
        XCTAssertEqual(try LightningQueryParser.parse(excludedRoot.expression),
                       .and([.term(LightningTerm("x")), .not(.and([.filter(.extension(["pdf"])), .term(LightningTerm("b"))]))]))
        // An AND group inside an OR group needs parentheses: OR binds tighter than AND.
        let both = LightningConditionGroup(items: [condition(.name, .contains, "a"), condition(.name, .contains, "b")])
        let anyRoot = expression { $0.conditions = conditions(matchesAll: false, [.group(both), condition(.name, .contains, "c")]) }
        XCTAssertEqual(anyRoot.expression, "(a b) OR c")
        XCTAssertEqual(try LightningQueryParser.parse(anyRoot.expression),
                       .or([.and([.term(LightningTerm("a")), .term(LightningTerm("b"))]), .term(LightningTerm("c"))]))
        // Empty and disabled conditions are left out; only the enabled empty one is reported.
        let partial = expression {
            $0.conditions = conditions([condition(.name, .contains, ""), condition(.size, .greater, "", enabled: false),
                                        condition(.extension, nil, "md"), .group(LightningConditionGroup())])
        }
        XCTAssertEqual(partial.expression, "ext:md")
        XCTAssertEqual(partial.issues.map(\.kind), [.emptyCondition])
        XCTAssertNotNil(partial.issues.first?.conditionID)
    }

    // MARK: Editing and limits

    func testEditingLimits() throws {
        var root = LightningConditionGroup()
        for _ in 0..<LightningConditionGroup.maximumConditions { XCTAssertTrue(root.addCondition(to: root.id)) }
        XCTAssertFalse(root.addCondition(to: root.id))
        XCTAssertNil(root.addGroup(to: root.id))
        XCTAssertEqual(root.conditionCount, 32)
        var query = LightningVisualQuery()
        query.conditions = root
        query.conditions.items.append(condition(.name, .contains, "extra"))
        XCTAssertEqual(query.compile().issues.filter { $0.kind == .tooManyConditions }.count, 1)

        var tree = LightningConditionGroup()
        let level2 = try XCTUnwrap(tree.addGroup(to: tree.id))
        let level3 = try XCTUnwrap(tree.addGroup(to: level2))
        let level4 = try XCTUnwrap(tree.addGroup(to: level3))
        XCTAssertNil(tree.addGroup(to: level4))
        XCTAssertEqual(tree.level(ofGroup: level4), 4)
        XCTAssertEqual(tree.depth, 4)
        XCTAssertEqual(tree.conditionCount, 3)
        XCTAssertFalse(tree.exceedsLimits)
        let deepCondition = try XCTUnwrap(tree.group(id: level4)?.items.first?.id)
        XCTAssertTrue(tree.updateCondition(id: deepCondition) { $0.value = "deep"; $0.id = UUID() })
        XCTAssertEqual(tree.condition(id: deepCondition)?.value, "deep")
        XCTAssertTrue(tree.updateGroup(id: level3) { $0.matchesAll = false })
        XCTAssertEqual(tree.group(id: level3)?.matchesAll, false)
        XCTAssertEqual(tree.activeConditionCount, 1)
        XCTAssertTrue(tree.removeItem(id: level3))
        XCTAssertNil(tree.group(id: level4))
        XCTAssertEqual(tree.depth, 2)
        XCTAssertFalse(tree.removeItem(id: UUID()))

        var edited = LightningCondition(field: .name, comparison: .starts, value: "abc")
        edited.setField(.contents, today: day(2026, 1, 2))
        XCTAssertEqual(edited.comparison, .contains)
        XCTAssertEqual(edited.value, "abc")
        edited.setField(.modified, today: day(2026, 1, 2))
        XCTAssertEqual(edited.value, "")
        XCTAssertEqual(edited.day, day(2026, 1, 2))
        XCTAssertEqual(edited.comparison, .atLeast)
        edited.setField(.folder, today: day(2026, 1, 2))
        XCTAssertEqual(edited.comparison, .descendants)
        XCTAssertEqual(LightningCondition(field: .size, comparison: .contains).comparison, .greater)

        var filters = LightningVisualQuery(text: "keep")
        filters.kinds = [.pdf]
        filters.conditions = conditions([condition(.name, .contains, "x")])
        XCTAssertTrue(filters.hasFilters)
        filters.resetFilters()
        XCTAssertFalse(filters.hasFilters)
        XCTAssertEqual(filters.text, "keep")
        XCTAssertTrue(filters.kinds.isEmpty)
        XCTAssertTrue(filters.conditions.items.isEmpty)
        filters.conditions.matchesAll = false
        XCTAssertTrue(filters.hasFilters)
    }

    func testGeneratedExpressionsAlwaysParse() {
        let texts = ["", "report", "a*b \"x y\"", "AND OR NOT", "(x) | !y", "tag:fake", "~/Docs/**", "\"", "报告;2026"]
        let fields = LightningConditionField.allCases
        var checked = 0
        for (index, text) in texts.enumerated() {
            for field in fields {
                for comparison in field.comparisons {
                    var query = LightningVisualQuery(text: text)
                    query.textTarget = LightningVisualTextTarget.allCases[index % 2]
                    query.kinds = Set(LightningVisualKind.allCases.enumerated().filter { ($0.offset + index) % 3 == 0 }.map(\.element))
                    query.date = LightningVisualDatePreset.allCases[index % LightningVisualDatePreset.allCases.count]
                    query.customStart = day(2025, 12, 31)
                    query.tags = index.isMultiple(of: 2) ? ["Red", "with space", "semi;colon"] : []
                    query.matchCase = index.isMultiple(of: 3)
                    let values = [text, "1.5", "~/Documents", "/tmp/a b", "jpg;png", "^a(b|c)$", "*?\"(|)!:"]
                    var nested = LightningConditionGroup(matchesAll: index.isMultiple(of: 2), isExcluded: true)
                    for (offset, value) in values.enumerated() {
                        nested.items.append(.condition(LightningCondition(isExcluded: offset.isMultiple(of: 2), field: field,
                                                                          comparison: comparison, value: value, secondValue: "3",
                                                                          day: day(2026, 1, 1), secondDay: day(2026, 2, 1))))
                    }
                    query.conditions = LightningConditionGroup(matchesAll: !index.isMultiple(of: 2),
                                                               items: [.group(nested), condition(.name, .contains, "z")])
                    let compiled = query.compile(homeDirectory: "/Users/test")
                    XCTAssertNoThrow(try LightningQueryParser.parse(compiled.expression),
                                     "\(field) \(comparison) \(text): \(compiled.expression)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    // MARK: Semantics against a real index

    func testCompiledConditionsMatchFiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-visual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = LightningIndex.canonicalPath(temporary.path)
        for (relative, size) in [("Docs/Report 2026.pdf", 2_000), ("Docs/Report draft.pdf", 10), ("Docs/old Report.txt", 10),
                                 ("Docs/a*b.txt", 1), ("Docs/axb.txt", 1), ("Docs/Sub/inner.pdf", 5_000_000), ("Other/Report 2026.pdf", 3)] {
            let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: size).write(to: url)
        }
        let index = LightningIndex(configuration: LightningIndexConfiguration(roots: [URL(fileURLWithPath: root)], autosaveInterval: nil))
        XCTAssertEqual(index.rebuild().stage, .ready)
        let engine = LightningSearchEngine(index: index, homeDirectory: root)

        func names(_ configure: (inout LightningVisualQuery) -> Void, file: StaticString = #filePath, line: UInt = #line) -> [String] {
            var query = LightningVisualQuery()
            configure(&query)
            let compiled = query.compile(homeDirectory: root)
            XCTAssertEqual(compiled.issues, [], file: file, line: line)
            do {
                return try engine.search(compiled.expression, caseSensitive: query.matchCase, sort: .path, limit: 100).rows.map {
                    String($0.path.dropFirst(root.count + 1))
                }
            } catch {
                XCTFail("\(compiled.expression): \(error)", file: file, line: line)
                return []
            }
        }

        XCTAssertEqual(names { $0.text = "a*b" }, ["Docs/a*b.txt"])
        XCTAssertEqual(names { $0.conditions = conditions([condition(.name, .starts, "report"), condition(.name, .ends, ".pdf")]) },
                       ["Docs/Report 2026.pdf", "Docs/Report draft.pdf", "Other/Report 2026.pdf"])
        XCTAssertEqual(names { $0.conditions = conditions([condition(.name, .equals, "axb.txt")]) }, ["Docs/axb.txt"])
        XCTAssertEqual(names { $0.conditions = conditions([condition(.folder, .directFiles, "~/Docs")]) },
                       ["Docs", "Docs/a*b.txt", "Docs/axb.txt", "Docs/old Report.txt", "Docs/Report 2026.pdf", "Docs/Report draft.pdf"])
        XCTAssertEqual(names { $0.conditions = conditions([condition(.folder, .children, root + "/Docs")]) },
                       ["Docs/a*b.txt", "Docs/axb.txt", "Docs/old Report.txt", "Docs/Report 2026.pdf", "Docs/Report draft.pdf", "Docs/Sub"])
        XCTAssertEqual(names {
            $0.text = "report"
            $0.conditions = conditions([condition(.folder, .descendants, "~"),
                                        .group(LightningConditionGroup(isExcluded: true, items: [condition(.extension, nil, "txt")]))])
        }, ["Docs/Report 2026.pdf", "Docs/Report draft.pdf", "Other/Report 2026.pdf"])
        XCTAssertEqual(names { $0.kinds = [.file]; $0.conditions = conditions([condition(.size, .between, "1", second: "100")]) },
                       ["Docs/Sub/inner.pdf"])
        XCTAssertEqual(names { $0.conditions = conditions([condition(.size, .between, "1", second: "3", unit: .kilobytes)]) },
                       ["Docs/Report 2026.pdf"])
        XCTAssertEqual(names { $0.text = "REPORT 2026"; $0.matchCase = true }, [])
        XCTAssertEqual(names { $0.text = "Report 2026"; $0.matchCase = true }, ["Docs/Report 2026.pdf", "Other/Report 2026.pdf"])
        XCTAssertEqual(names { $0.kinds = [.document]; $0.text = "draft" }, ["Docs/Report draft.pdf"])
        // Kinds are alternatives: folders or PDF files.
        XCTAssertEqual(names { $0.kinds = [.folder, .pdf]; $0.text = "o" },
                       ["Docs", "Other", "Docs/Report 2026.pdf", "Docs/Report draft.pdf", "Other/Report 2026.pdf"])
        XCTAssertEqual(names {
            $0.conditions = conditions([condition(.name, .contains, "report"), condition(.extension, nil, "pdf", excluded: true)])
        }, ["Docs/old Report.txt"])
    }
}
