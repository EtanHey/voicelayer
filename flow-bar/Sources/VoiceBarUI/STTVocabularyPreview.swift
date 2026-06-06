import Foundation

public struct STTVocabularyAliasPreview: Codable, Equatable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct STTVocabularyPreview: Codable, Equatable {
    public var updatedAt: String?
    public var promptTerms: [String]
    public var aliases: [STTVocabularyAliasPreview]

    public init(updatedAt: String?, promptTerms: [String], aliases: [STTVocabularyAliasPreview]) {
        self.updatedAt = updatedAt
        self.promptTerms = promptTerms
        self.aliases = aliases
    }

    public enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case promptTerms = "prompt_terms"
        case aliases
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
