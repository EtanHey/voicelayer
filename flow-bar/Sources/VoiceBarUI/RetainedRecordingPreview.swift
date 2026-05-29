import Foundation

public enum RetainedRecordingPreview {
    public static var urlProvider: () -> URL? = { nil }

    public static func exists() -> Bool {
        guard let url = urlProvider() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
