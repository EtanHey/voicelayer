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
        SettingsArchiveScanner.shortTimestamp(for: createdAt, locale: locale, timeZone: timeZone)
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
        SettingsArchiveScanner.dayTitle(for: date, locale: locale, timeZone: timeZone)
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

/// The recording (F5 / VoiceBar) side of Settings → History.
///
/// AIDEV-NOTE: Ask exchanges live in the same day directories but are deliberately excluded
/// here — Etan asked explicitly that ask recordings never merge into the left list. They are
/// surfaced by `SettingsAskHistoryArchive` instead.
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
        let scan = SettingsArchiveScanner.scan(root: root, limit: limit, loadEntry: loadEntry)
        let groups = scan.days.map { day in
            SettingsHistoryDayGroup(
                dayKey: day.dayKey,
                date: day.date,
                entries: newestFirst(day.entries)
            )
        }
        return SettingsHistoryPage(
            groups: newestFirst(groups),
            loadedEntryCount: scan.loadedEntryCount,
            hasMore: scan.hasMore
        )
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

        let metadata = SettingsArchiveMetadata.load(
            from: recordingURL.appendingPathComponent("metadata.json")
        )
        guard metadata?.isAskExchange != true else {
            return nil
        }

        let recordingID = metadata?.id?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .settingsArchiveNilIfEmpty
            ?? recordingURL.lastPathComponent
        let createdAt = metadata?.createdAt.flatMap(SettingsArchiveScanner.parseISODate) ?? fallbackDate
        let transcript = SettingsArchiveScanner.readTrimmedText(
            at: recordingURL.appendingPathComponent("voicelayer-transcript.txt")
        )

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
