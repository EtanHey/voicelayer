import Foundation

public struct STTVocabularyAliasPreview: Codable, Equatable, Hashable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct STTDictionaryEntry: Codable, Equatable, Hashable, Sendable {
    public var canonical: String
    public var variants: [String]

    public init(canonical: String, variants: [String]) {
        self.canonical = canonical
        self.variants = variants
    }
}

public struct STTDictionaryDisplayEntry: Equatable, Sendable {
    public let rowID: String
    public let source: String
    public let entry: STTDictionaryEntry

    public var isPersonal: Bool {
        source == "personal"
    }

    public init?(eventRow: [String: Any]) {
        guard let rowID = eventRow["row_id"] as? String,
              let source = eventRow["source"] as? String,
              source == "personal" || source == "bundled",
              let canonical = eventRow["canonical"] as? String,
              !canonical.isEmpty,
              rowID == "\(source):\(canonical)"
        else { return nil }
        self.rowID = rowID
        self.source = source
        entry = STTDictionaryEntry(canonical: canonical, variants: eventRow["variants"] as? [String] ?? [])
    }

    public init(source: String, entry: STTDictionaryEntry) {
        self.source = source
        rowID = "\(source):\(entry.canonical)"
        self.entry = entry
    }
}

public struct STTDictionaryDisplayIndex {
    public let sortedEntries: [STTDictionaryDisplayEntry]
    public let personalCount: Int

    public init(entries: [STTDictionaryDisplayEntry]) {
        sortedEntries = entries.sorted {
            if $0.source != $1.source { return $0.isPersonal }
            return $0.entry.canonical.localizedCaseInsensitiveCompare($1.entry.canonical) == .orderedAscending
        }
        personalCount = entries.filter(\.isPersonal).count
    }

    public func page(matching query: String, limit: Int) -> (entries: [STTDictionaryDisplayEntry], total: Int) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = term.isEmpty ? sortedEntries : sortedEntries.filter {
            $0.entry.canonical.localizedCaseInsensitiveContains(term) ||
                $0.entry.variants.contains { $0.localizedCaseInsensitiveContains(term) }
        }
        return (Array(matches.prefix(max(0, limit))), matches.count)
    }
}

public struct STTVocabularyPreview: Codable, Equatable, Sendable {
    public var updatedAt: String?
    public var entries: [STTDictionaryEntry]
    public var displayEntries: [STTDictionaryDisplayEntry]?

    public init(updatedAt: String?, entries: [STTDictionaryEntry], displayEntries: [STTDictionaryDisplayEntry]? = nil) {
        self.updatedAt = updatedAt
        self.entries = entries
        self.displayEntries = displayEntries
    }

    public init(updatedAt: String?, promptTerms: [String], aliases: [STTVocabularyAliasPreview]) {
        self.updatedAt = updatedAt
        displayEntries = nil
        var accumulator = EntryAccumulator()
        for term in promptTerms {
            accumulator.upsertEntry(canonical: term)
        }
        for alias in aliases {
            accumulator.upsertVariant(alias.from, canonical: alias.to)
        }
        entries = accumulator.entries
    }

    public enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case entries
        case promptTerms = "prompt_terms"
        case aliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        displayEntries = nil
        if let decodedEntries = try container.decodeIfPresent([STTDictionaryEntry].self, forKey: .entries) {
            entries = Self.normalizedEntries(decodedEntries)
            return
        }
        let promptTerms = try container.decodeIfPresent([String].self, forKey: .promptTerms) ?? []
        let aliases = try container.decodeIfPresent([STTVocabularyAliasPreview].self, forKey: .aliases) ?? []
        var accumulator = EntryAccumulator()
        for term in promptTerms {
            accumulator.upsertEntry(canonical: term)
        }
        for alias in aliases {
            accumulator.upsertVariant(alias.from, canonical: alias.to)
        }
        entries = accumulator.entries
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(entries, forKey: .entries)
    }

    public var promptTerms: [String] {
        entries.map(\.canonical)
    }

    public var aliases: [STTVocabularyAliasPreview] {
        entries.flatMap { entry in
            entry.variants.map { STTVocabularyAliasPreview(from: $0, to: entry.canonical) }
        }
    }

    private static func normalizedEntries(_ input: [STTDictionaryEntry]) -> [STTDictionaryEntry] {
        var accumulator = EntryAccumulator()
        for entry in input {
            accumulator.upsertEntry(canonical: entry.canonical)
            for variant in entry.variants {
                accumulator.upsertVariant(variant, canonical: entry.canonical)
            }
        }
        return accumulator.entries
    }

    private struct EntryAccumulator {
        private(set) var entries: [STTDictionaryEntry] = []
        private var canonicalIndexes: [String: Int] = [:]
        private var variantKeys: [Set<String>] = []

        mutating func upsertEntry(canonical: String) {
            _ = index(for: canonical)
        }

        mutating func upsertVariant(_ variant: String, canonical: String) {
            let trimmedVariant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedVariant.isEmpty, let entryIndex = index(for: canonical) else { return }
            let key = aliasKey(trimmedVariant)
            guard key != aliasKey(entries[entryIndex].canonical) else { return }
            guard variantKeys[entryIndex].insert(key).inserted else { return }
            entries[entryIndex].variants.append(trimmedVariant)
        }

        private mutating func index(for canonical: String) -> Int? {
            let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = canonicalKey(trimmed)
            if let existing = canonicalIndexes[key] {
                return existing
            }
            let index = entries.count
            entries.append(STTDictionaryEntry(canonical: trimmed, variants: []))
            canonicalIndexes[key] = index
            variantKeys.append([])
            return index
        }

        private func canonicalKey(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        }
    }
}

public struct STTDictionaryPage: Equatable, Sendable {
    public let entries: [STTDictionaryEntry]
    public let totalMatchCount: Int

    public var hasMore: Bool {
        entries.count < totalMatchCount
    }
}

public struct STTDictionaryIndex: Equatable, Sendable {
    public let sortedEntries: [STTDictionaryEntry]

    public init(entries: [STTDictionaryEntry]) {
        sortedEntries = entries.sorted {
            $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
        }
    }

    public func page(matching query: String, limit: Int) -> STTDictionaryPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [STTDictionaryEntry] = if trimmed.isEmpty {
            sortedEntries
        } else {
            sortedEntries.filter { entry in
                entry.canonical.localizedCaseInsensitiveContains(trimmed) ||
                    entry.variants.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
        }
        return STTDictionaryPage(
            entries: Array(matches.prefix(max(0, limit))),
            totalMatchCount: matches.count
        )
    }
}

public struct STTVocabularyDraft: Equatable {
    public var correct: String
    public var wrong: String

    public init(correct: String, wrong: String) {
        self.correct = correct
        self.wrong = wrong
    }

    public var trimmedCorrect: String {
        correct.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedWrong: String {
        wrong.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canSaveAlias: Bool {
        !trimmedCorrect.isEmpty && !trimmedWrong.isEmpty
    }

    public func addAliasPayload() -> [String: Any]? {
        guard canSaveAlias else { return nil }
        return STTVocabularyCommandPayload.addAlias(
            correct: trimmedCorrect,
            wrong: trimmedWrong
        )
    }
}

public enum STTVocabularyCommandPayload {
    public static func addAlias(
        correct: String,
        wrong: String,
        id: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "cmd": "vocab_add",
            "from": wrong.trimmingCharacters(in: .whitespacesAndNewlines),
            "to": correct.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        addID(id, to: &payload)
        return payload
    }

    public static func removeAlias(
        _ alias: STTVocabularyAliasPreview,
        id: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "cmd": "vocab_remove",
            "from": alias.from.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        addID(id, to: &payload)
        return payload
    }

    public static func addTerm(
        _ term: String,
        id: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "cmd": "vocab_add_term",
            "term": term.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        addID(id, to: &payload)
        return payload
    }

    public static func removeTerm(
        _ term: String,
        id: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "cmd": "vocab_remove_term",
            "term": term.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        addID(id, to: &payload)
        return payload
    }

    public static func list(id: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["cmd": "vocab_list"]
        addID(id, to: &payload)
        return payload
    }

    private static func addID(_ id: String?, to payload: inout [String: Any]) {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return }
        payload["id"] = trimmed
    }
}

public extension STTVocabularyPreview {
    func filteredEntries(matching query: String) -> [STTDictionaryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedEntries = entries.sorted {
            $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
        }
        guard !trimmed.isEmpty else { return sortedEntries }
        return sortedEntries.filter { entry in
            entry.canonical.localizedCaseInsensitiveContains(trimmed) ||
                entry.variants.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func filteredAliases(matching query: String) -> [STTVocabularyAliasPreview] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return aliases }
        return aliases.filter {
            $0.from.localizedCaseInsensitiveContains(trimmed) ||
                $0.to.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func filteredPromptTerms(matching query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return promptTerms }
        return promptTerms.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

private func aliasKey(_ value: String) -> String {
    value
        .lowercased()
        .filter { ($0.isASCII && $0.isLetter) || $0.isNumber }
}
