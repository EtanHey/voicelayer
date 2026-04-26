import Foundation

struct STTVocabularyAliasPreview: Codable, Equatable {
    var from: String
    var to: String
}

struct STTVocabularyPreview: Codable, Equatable {
    var updatedAt: String?
    var promptTerms: [String]
    var aliases: [STTVocabularyAliasPreview]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case promptTerms = "prompt_terms"
        case aliases
    }
}

enum STTVocabularySnapshotLoader {
    static func load() -> STTVocabularyPreview {
        let url = defaultURL()
        guard let data = try? Data(contentsOf: url) else {
            return STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        }

        do {
            return try JSONDecoder().decode(STTVocabularyPreview.self, from: data)
        } catch {
            return STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        }
    }

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("voicelayer", isDirectory: true)
            .appendingPathComponent("stt-vocabulary.json", isDirectory: false)
    }
}
