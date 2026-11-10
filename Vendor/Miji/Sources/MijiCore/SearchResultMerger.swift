import Foundation

/// Final list shared by GUI and CLI: protect strong names, surface useful body evidence.
public enum SearchResultMerger {
    public static func merge(nameResults: [SearchHit], contentResults: [SearchHit],
                             scope: SearchScope, sort: SearchSort, limit: Int,
                             query: String = "") -> [SearchHit] {
        let names = scope == .content ? [] : nameResults
        let extra = scope == .name ? [] : contentResults
        let decorated = Dictionary(uniqueKeysWithValues: extra.map { ($0.id, $0) })
        var ids = Set(names.map(\.id))
        var merged = names.map { decorated[$0.id] ?? $0 } + extra.filter { ids.insert($0.id).inserted }
        if sort == .relevance && scope == .all {
            let terms = QueryParser.parse(query).terms.filter { $0.field == .text && !$0.isExcluded }.map(\.value)
            func strongName(_ hit: SearchHit) -> Bool {
                guard !terms.isEmpty else { return true }
                let name = QueryParser.normalize(hit.file.name)
                let stem = QueryParser.normalize((hit.file.name as NSString).deletingPathExtension)
                let phrase = terms.joined(separator: " ")
                if name == phrase || stem == phrase { return true }
                guard terms.count == 1, let term = terms.first else { return false }
                if name.hasPrefix(term) { return true }
                // Transliteration only matters for Latin queries that did not match the literal prefix.
                guard term.unicodeScalars.allSatisfy({ $0.isASCII }), !name.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
                let romanized = SearchDatabase.pinyin(hit.file.name)
                return romanized.0.hasPrefix(term) || romanized.1.hasPrefix(term)
            }
            let strong = names.filter(strongName)
            let strongIDs = Set(strong.map(\.id))
            let nameIDs = Set(names.map(\.id))
            let useful = extra.filter { !strongIDs.contains($0.id) && $0.contentRelevance >= 2 }
            let usefulIDs = Set(useful.map(\.id))
            let ordinary = names.filter { !strongIDs.contains($0.id) && !usefulIDs.contains($0.id) }
            let mentions = extra.filter { !nameIDs.contains($0.id) && $0.contentRelevance < 2 }
            merged = strong.map { decorated[$0.id] ?? $0 }
            // Preserve each source's ranking without adding incomparable raw scores.
            for index in 0..<max(ordinary.count, useful.count) {
                if index < useful.count { merged.append(useful[index]) }
                if index < ordinary.count { merged.append(decorated[ordinary[index].id] ?? ordinary[index]) }
            }
            merged += mentions
        } else if sort != .relevance {
            merged.sort {
                if sort == .modified && $0.file.modified != $1.file.modified { return $0.file.modified > $1.file.modified }
                if sort == .size && $0.file.size != $1.file.size { return $0.file.size > $1.file.size }
                let a = $0.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                let b = $1.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                return a == b ? $0.id < $1.id : a < b
            }
        }
        return Array(merged.prefix(max(0, limit)))
    }
}
