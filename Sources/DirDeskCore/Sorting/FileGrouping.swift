import Foundation

/// One section of a grouped view. `title` is an English key that the UI localizes,
/// or a literal value (kind, tag, extension, month) when `isLiteral` is true.
public struct FileGroup: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var isLiteral: Bool
    public var items: [FileItem]
}

public enum FileGrouping {
    enum DateBucket: Comparable {
        case future, today, yesterday, previous7, previous30, month(Int, Int), year(Int), unknown

        var rank: (Int, Int) {
            switch self {
            case .future: (0, 0)
            case .today: (1, 0)
            case .yesterday: (2, 0)
            case .previous7: (3, 0)
            case .previous30: (4, 0)
            case .month(let y, let m): (5, -(y * 12 + m))
            case .year(let y): (6, -y)
            case .unknown: (7, 0)
            }
        }

        static func < (lhs: DateBucket, rhs: DateBucket) -> Bool { lhs.rank < rhs.rank }
    }

    static func dateBucket(_ date: Date?, now: Date, calendar: Calendar) -> DateBucket {
        guard let date else { return .unknown }
        if date > now { return .future }
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -7, to: today), date >= week { return .previous7 }
        if let month = calendar.date(byAdding: .day, value: -30, to: today), date >= month { return .previous30 }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let nowYear = calendar.component(.year, from: now)
        if parts.year == nowYear { return .month(parts.year ?? 0, parts.month ?? 0) }
        return .year(parts.year ?? 0)
    }

    static func dateTitle(_ bucket: DateBucket, calendar: Calendar, locale: Locale) -> (String, Bool) {
        switch bucket {
        case .future: return ("Future", false)
        case .today: return ("Today", false)
        case .yesterday: return ("Yesterday", false)
        case .previous7: return ("Previous 7 Days", false)
        case .previous30: return ("Previous 30 Days", false)
        case .month(let y, let m):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("MMMM")
            let date = calendar.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
            return (formatter.string(from: date), true)
        case .year(let y): return (String(y), true)
        case .unknown: return ("Unknown Date", false)
        }
    }

    /// Size buckets use decimal thresholds regardless of the display unit.
    static func sizeBucket(_ item: FileItem) -> (Int, String) {
        guard let size = item.size else { return (5, "Unknown Size") }
        switch size {
        case ...999_999: return (1, "Less than 1 MB")
        case ...99_999_999: return (2, "1 MB – 100 MB")
        case ...999_999_999: return (3, "100 MB – 1 GB")
        default: return (4, "1 GB or Larger")
        }
    }

    /// Groups already-sorted items, keeping each group's internal order.
    public static func group(_ items: [FileItem], mode: FileGroupingMode, pinnedPaths: Set<String> = [],
                             now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current,
                             kind: (FileItem) -> String, application: (FileItem) -> String?) -> [FileGroup] {
        guard mode != .none else {
            return [FileGroup(id: "all", title: "All Items", isLiteral: false, items: items)]
        }
        var pinned: [FileItem] = []
        var buckets: [String: (order: (Int, Int, String), title: String, literal: Bool, items: [FileItem])] = [:]
        func add(_ item: FileItem, id: String, order: (Int, Int, String), title: String, literal: Bool) {
            buckets[id, default: (order, title, literal, [])].items.append(item)
        }
        for item in items {
            if item.isBrowsableFolder && pinnedPaths.contains(item.url.path) {
                pinned.append(item)
                continue
            }
            switch mode {
            case .none:
                break
            case .modified, .created, .added, .lastOpened:
                let date: Date? = switch mode {
                case .modified: item.modificationDate
                case .created: item.creationDate
                case .added: item.addedDate
                default: item.lastOpenedDate
                }
                let bucket = dateBucket(date, now: now, calendar: calendar)
                let (title, literal) = dateTitle(bucket, calendar: calendar, locale: locale)
                add(item, id: "date:\(bucket.rank.0):\(bucket.rank.1)", order: (bucket.rank.0, bucket.rank.1, ""), title: title, literal: literal)
            case .size:
                if item.isBrowsableFolder {
                    add(item, id: "folders", order: (0, 0, ""), title: "Folders", literal: false)
                } else {
                    let (rank, title) = sizeBucket(item)
                    add(item, id: "size:\(rank)", order: (rank, 0, ""), title: title, literal: false)
                }
            case .kind:
                let text = kind(item)
                add(item, id: "kind:\(text)", order: (0, 0, text), title: text, literal: true)
            case .application:
                if let app = application(item) {
                    add(item, id: "app:\(app)", order: (0, 0, app), title: app, literal: true)
                } else {
                    add(item, id: "app:none", order: (1, 0, ""), title: "No Application", literal: false)
                }
            case .tags:
                if let tag = item.tags.first {
                    add(item, id: "tag:\(tag)", order: (0, 0, tag), title: tag, literal: true)
                } else {
                    add(item, id: "tag:none", order: (1, 0, ""), title: "No Tags", literal: false)
                }
            case .fileExtension:
                if item.isBrowsableFolder {
                    add(item, id: "folders", order: (0, 0, ""), title: "Folders", literal: false)
                } else if item.fileExtension.isEmpty {
                    add(item, id: "ext:none", order: (2, 0, ""), title: "No Extension", literal: false)
                } else {
                    let ext = item.fileExtension.lowercased()
                    add(item, id: "ext:\(ext)", order: (1, 0, ext), title: ext.uppercased(), literal: true)
                }
            }
        }
        var groups = buckets.sorted { lhs, rhs in
            let l = lhs.value.order, r = rhs.value.order
            if l.0 != r.0 { return l.0 < r.0 }
            if l.1 != r.1 { return l.1 < r.1 }
            return l.2.localizedStandardCompare(r.2) == .orderedAscending
        }.map { FileGroup(id: $0.key, title: $0.value.title, isLiteral: $0.value.literal, items: $0.value.items) }
        if !pinned.isEmpty {
            groups.insert(FileGroup(id: "pinned", title: "Pinned Folders", isLiteral: false, items: pinned), at: 0)
        }
        return groups
    }
}
