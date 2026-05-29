import Foundation

public struct STTVocabularyAliasPreview: Codable, Equatable {
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
