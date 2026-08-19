import Foundation

public extension Notification.Name {
    static let voiceBarHistoryArchiveDidChange = Notification.Name("VoiceBarHistoryArchiveDidChange")
}

public struct SettingsHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let dayKey: String
    public let recordingID: String
    public let createdAt: Date
    public let transcript: String
    public let audioPath: URL
    /// Mic-on time: how long the recording actually ran.
    public let durationMs: Int?
    /// The slice of that audio handed to speech-to-text. Shorter than `durationMs`
    /// when the trailing-silence trim fired.
    public let transcribedDurationMs: Int?

    public init(
        id: String,
        dayKey: String,
        recordingID: String,
        createdAt: Date,
        transcript: String,
        audioPath: URL,
        durationMs: Int? = nil,
        transcribedDurationMs: Int? = nil
    ) {
        self.id = id
        self.dayKey = dayKey
        self.recordingID = recordingID
        self.createdAt = createdAt
        self.transcript = transcript
        self.audioPath = audioPath
        self.durationMs = durationMs
        self.transcribedDurationMs = transcribedDurationMs
    }

    public var durationLabel: String? {
        Self.clockLabel(durationMs)
    }

    /// Only surfaced when it differs from mic-on time — otherwise every VAD row
    /// would carry a redundant twin of the same number.
    public var transcribedDurationLabel: String? {
        guard let transcribedDurationMs, let durationMs else { return nil }
        guard abs(transcribedDurationMs - durationMs) >= 1000 else { return nil }
        return Self.clockLabel(transcribedDurationMs)
    }

    static func clockLabel(_ milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let totalSeconds = Int((Double(milliseconds) / 1000).rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

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

public struct SettingsHistoryDayGroup: Identifiable, Equatable, Sendable {
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

public struct SettingsHistoryPage: Equatable, Sendable {
    public let groups: [SettingsHistoryDayGroup]
    public let loadedEntryCount: Int
    public let hasMore: Bool

    public init(
        groups: [SettingsHistoryDayGroup],
        loadedEntryCount: Int? = nil,
        hasMore: Bool
    ) {
        self.groups = groups
        self.loadedEntryCount = loadedEntryCount ?? groups.reduce(0) { $0 + $1.entries.count }
        self.hasMore = hasMore
    }
}

public enum SettingsHistoryArchive {
    public static let defaultPageSize = 100

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("voicelayer")
            .appendingPathComponent("recordings")
    }

    public static func load(from root: URL = defaultRoot) -> [SettingsHistoryDayGroup] {
        loadPage(from: root, limit: .max).groups
    }

    public static func loadPage(
        from root: URL = defaultRoot,
        limit: Int = defaultPageSize
    ) -> SettingsHistoryPage {
        let fileManager = FileManager.default
        guard let dayURLs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SettingsHistoryPage(groups: [], loadedEntryCount: 0, hasMore: false)
        }

        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else {
            return SettingsHistoryPage(groups: [], loadedEntryCount: 0, hasMore: !dayURLs.isEmpty)
        }

        let sortedDayURLs = dayURLs
            .filter(\.isDirectory)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        var groups: [SettingsHistoryDayGroup] = []
        var loadedEntryCount = 0
        var hasMore = false

        for (dayIndex, dayURL) in sortedDayURLs.enumerated() {
            let dayKey = dayURL.lastPathComponent
            guard let dayDate = parseDayKey(dayKey),
                  let entryURLs = try? fileManager.contentsOfDirectory(
                      at: dayURL,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  )
            else {
                continue
            }

            let candidates = entryURLs
                .filter { $0.isDirectory && !$0.lastPathComponent.hasPrefix(".tmp-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            var entries: [SettingsHistoryEntry] = []
            var shouldStopAfterDay = false

            for (entryIndex, entryURL) in candidates.enumerated() {
                guard let entry = loadEntry(from: entryURL, dayKey: dayKey, fallbackDate: dayDate) else {
                    continue
                }
                entries.append(entry)
                loadedEntryCount += 1
                if loadedEntryCount == boundedLimit {
                    hasMore = entryIndex < candidates.count - 1 || dayIndex < sortedDayURLs.count - 1
                    shouldStopAfterDay = true
                    break
                }
            }

            if !entries.isEmpty {
                groups.append(SettingsHistoryDayGroup(
                    dayKey: dayKey,
                    date: dayDate,
                    entries: newestFirst(entries)
                ))
            }
            if shouldStopAfterDay {
                break
            }
        }

        return SettingsHistoryPage(
            groups: newestFirst(groups),
            loadedEntryCount: loadedEntryCount,
            hasMore: hasMore
        )
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
            .sorted(by: isNewerEntry)

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
            audioPath: audioURL,
            durationMs: metadata?.durationMs,
            transcribedDurationMs: metadata?.transcribedDurationMs
        )
    }

    private struct Metadata: Decodable {
        let id: String?
        let createdAt: String?
        let durationMs: Int?
        let transcribedDurationMs: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case durationMs = "duration_ms"
            case transcribedDurationMs = "transcribed_duration_ms"
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

    private static func newestFirst(_ groups: [SettingsHistoryDayGroup]) -> [SettingsHistoryDayGroup] {
        groups.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.dayKey > rhs.dayKey
            }
            return lhs.date > rhs.date
        }
    }

    private static func newestFirst(_ entries: [SettingsHistoryEntry]) -> [SettingsHistoryEntry] {
        entries.sorted(by: isNewerEntry)
    }

    private static func isNewerEntry(_ lhs: SettingsHistoryEntry, _ rhs: SettingsHistoryEntry) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.recordingID > rhs.recordingID
        }
        return lhs.createdAt > rhs.createdAt
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
