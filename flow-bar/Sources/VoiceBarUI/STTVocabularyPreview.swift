import Foundation

public struct STTVocabularyAliasPreview: Codable, Equatable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct STTDictionaryEntry: Codable, Equatable, Hashable {
    public var canonical: String
    public var variants: [String]

    public init(canonical: String, variants: [String]) {
        self.canonical = canonical
        self.variants = variants
    }
}

public struct STTVocabularyPreview: Codable, Equatable {
    public var updatedAt: String?
    public var entries: [STTDictionaryEntry]

    public init(updatedAt: String?, entries: [STTDictionaryEntry]) {
        self.updatedAt = updatedAt
        self.entries = entries
    }

    public init(updatedAt: String?, promptTerms: [String], aliases: [STTVocabularyAliasPreview]) {
        self.updatedAt = updatedAt
        var entries: [STTDictionaryEntry] = []
        for term in promptTerms {
            Self.upsertEntry(canonical: term, in: &entries)
        }
        for alias in aliases {
            Self.upsertVariant(alias.from, canonical: alias.to, in: &entries)
        }
        self.entries = entries
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
        if let decodedEntries = try container.decodeIfPresent([STTDictionaryEntry].self, forKey: .entries) {
            entries = Self.normalizedEntries(decodedEntries)
            return
        }
        let promptTerms = try container.decodeIfPresent([String].self, forKey: .promptTerms) ?? []
        let aliases = try container.decodeIfPresent([STTVocabularyAliasPreview].self, forKey: .aliases) ?? []
        var migrated: [STTDictionaryEntry] = []
        for term in promptTerms {
            Self.upsertEntry(canonical: term, in: &migrated)
        }
        for alias in aliases {
            Self.upsertVariant(alias.from, canonical: alias.to, in: &migrated)
        }
        entries = migrated
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
        var entries: [STTDictionaryEntry] = []
        for entry in input {
            upsertEntry(canonical: entry.canonical, in: &entries)
            for variant in entry.variants {
                upsertVariant(variant, canonical: entry.canonical, in: &entries)
            }
        }
        return entries
    }

    private static func upsertEntry(canonical: String, in entries: inout [STTDictionaryEntry]) {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !entries.contains(where: { $0.canonical.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return
        }
        entries.append(STTDictionaryEntry(canonical: trimmed, variants: []))
    }

    private static func upsertVariant(_ variant: String, canonical: String, in entries: inout [STTDictionaryEntry]) {
        let trimmedVariant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVariant.isEmpty, !trimmedCanonical.isEmpty else { return }
        upsertEntry(canonical: trimmedCanonical, in: &entries)
        guard let index = entries
            .firstIndex(where: { $0.canonical.localizedCaseInsensitiveCompare(trimmedCanonical) == .orderedSame })
        else {
            return
        }
        let variantKey = aliasKey(trimmedVariant)
        guard variantKey != aliasKey(entries[index].canonical) else { return }
        guard !entries[index].variants.contains(where: { aliasKey($0) == variantKey }) else { return }
        entries[index].variants.append(trimmedVariant)
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
