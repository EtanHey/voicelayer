import Foundation

enum VoiceModelDisplayName {
    static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let basename = URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
        let cleaned = basename.hasPrefix("ggml-") ? String(basename.dropFirst(5)) : basename
        return cleaned.isEmpty ? nil : cleaned
    }
}
