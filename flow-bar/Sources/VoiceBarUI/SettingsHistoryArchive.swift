import Foundation

public extension Notification.Name {
    static let voiceBarHistoryArchiveDidChange = Notification.Name("VoiceBarHistoryArchiveDidChange")
}

public struct SettingsHistoryEntry: Identifiable, Equatable {
    public let id: String
    public let dayKey: String
    public let recordingID: String
    public let createdAt: Date
    public let transcript: String
    public let audioPath: URL

    public var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var displayTranscript: String {
        hasTranscript ? transcript : "No transcript stored"
    }

    public func timestamp(
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

public struct SettingsHistoryDayGroup: Identifiable, Equatable {
    public let id: String
    public let dayKey: String
    public let date: Date
    public let entries: [SettingsHistoryEntry]

    public init(dayKey: String, date: Date, entries: [SettingsHistoryEntry]) {
        id = dayKey
        self.dayKey = dayKey
        self.date = date
        self.entries = entries
    }

    public func dayTitle(
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

public enum SettingsHistoryArchive {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("voicelayer")
            .appendingPathComponent("recordings")
    }

    public static func load(from root: URL = defaultRoot) -> [SettingsHistoryDayGroup] {
        let fileManager = FileManager.default
        guard let dayURLs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return dayURLs
            .filter(\.isDirectory)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { dayURL in
                loadDayGroup(from: dayURL)
            }
    }

    private static func loadDayGroup(from dayURL: URL) -> SettingsHistoryDayGroup? {
        let dayKey = dayURL.lastPathComponent
        guard let dayDate = parseDayKey(dayKey),
              let entryURLs = try? FileManager.default.contentsOfDirectory(
                  at: dayURL,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }

        let entries = entryURLs
            .filter { $0.isDirectory && !$0.lastPathComponent.hasPrefix(".tmp-") }
            .compactMap { loadEntry(from: $0, dayKey: dayKey, fallbackDate: dayDate) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.recordingID < rhs.recordingID
                }
                return lhs.createdAt < rhs.createdAt
            }

        guard !entries.isEmpty else { return nil }
        return SettingsHistoryDayGroup(dayKey: dayKey, date: dayDate, entries: entries)
    }

    private static func loadEntry(
        from recordingURL: URL,
        dayKey: String,
        fallbackDate: Date
    ) -> SettingsHistoryEntry? {
        let audioURL = recordingURL.appendingPathComponent("audio.wav")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return nil
        }

        let metadata = loadMetadata(from: recordingURL.appendingPathComponent("metadata.json"))
        let recordingID = metadata?.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? recordingURL.lastPathComponent
        let createdAt = metadata?.createdAt.flatMap(parseISODate) ?? fallbackDate
        let transcriptURL = recordingURL.appendingPathComponent("voicelayer-transcript.txt")
        let transcript = ((try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SettingsHistoryEntry(
            id: audioURL.path,
            dayKey: dayKey,
            recordingID: recordingID,
            createdAt: createdAt,
            transcript: transcript,
            audioPath: audioURL
        )
    }

    private struct Metadata: Decodable {
        let id: String?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
        }
    }

    private static func loadMetadata(from url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func parseDayKey(_ dayKey: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayKey)
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
