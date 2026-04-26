import Foundation

enum RetainedRecordingPreview {
    static func defaultURL() -> URL {
        URL(fileURLWithPath: "/tmp/voicelayer-last-recording.wav")
    }

    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: defaultURL().path)
    }
}
