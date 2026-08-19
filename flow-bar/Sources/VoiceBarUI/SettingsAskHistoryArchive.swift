import Foundation

/// One ask exchange: the question VoiceLayer spoke, and the answer Etan recorded.
///
/// Both sides are optional at the *audio* level only because a half-written archive should still
/// be listed rather than vanish. The entry itself exists as soon as the archive's `source`
/// marks it an ask exchange — including when the response never transcribed, which is the case
/// the Ask tab was asked for: the transcript he otherwise cannot see at all.
public struct SettingsAskHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let dayKey: String
    public let askID: String
    public let createdAt: Date
    public let questionText: String
    public let questionAudioPath: URL?
    public let responseTranscript: String
    public let responseAudioPath: URL?

    public var hasQuestionText: Bool {
        !questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasResponseTranscript: Bool {
        !responseTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var displayQuestionText: String {
        hasQuestionText ? questionText : "No question text stored"
    }

    public var displayResponseTranscript: String {
        hasResponseTranscript ? responseTranscript : "No transcript stored"
    }

    public func timestamp(
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        SettingsArchiveScanner.shortTimestamp(for: createdAt, locale: locale, timeZone: timeZone)
    }
}

public struct SettingsAskHistoryDayGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let dayKey: String
    public let date: Date
    public let entries: [SettingsAskHistoryEntry]

    public init(dayKey: String, date: Date, entries: [SettingsAskHistoryEntry]) {
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

public struct SettingsAskHistoryPage: Equatable, Sendable {
    public let groups: [SettingsAskHistoryDayGroup]
    public let loadedEntryCount: Int
    public let hasMore: Bool

    public init(
        groups: [SettingsAskHistoryDayGroup],
        loadedEntryCount: Int? = nil,
        hasMore: Bool
    ) {
        self.groups = groups
        self.loadedEntryCount = loadedEntryCount ?? groups.reduce(0) { $0 + $1.entries.count }
        self.hasMore = hasMore
    }
}

/// The Ask side of Settings → History: aggregation only, over archives the ask flow already writes.
public enum SettingsAskHistoryArchive {
    public static let defaultPageSize = SettingsHistoryArchive.defaultPageSize

    public static var defaultRoot: URL {
        SettingsHistoryArchive.defaultRoot
    }

    public static func load(from root: URL = defaultRoot) -> [SettingsAskHistoryDayGroup] {
        loadPage(from: root, limit: .max).groups
    }

    public static func loadPage(
        from root: URL = defaultRoot,
        limit: Int = defaultPageSize
    ) -> SettingsAskHistoryPage {
        let scan = SettingsArchiveScanner.scan(root: root, limit: limit, loadEntry: loadEntry)
        let groups = scan.days.map { day in
            SettingsAskHistoryDayGroup(
                dayKey: day.dayKey,
                date: day.date,
                entries: newestFirst(day.entries)
            )
        }
        return SettingsAskHistoryPage(
            groups: newestFirst(groups),
            loadedEntryCount: scan.loadedEntryCount,
            hasMore: scan.hasMore
        )
    }

    private static func loadEntry(
        from askURL: URL,
        dayKey: String,
        fallbackDate: Date
    ) -> SettingsAskHistoryEntry? {
        guard let metadata = SettingsArchiveMetadata.load(
            from: askURL.appendingPathComponent("metadata.json")
        ), metadata.isAskExchange else {
            return nil
        }

        let askID = metadata.id?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .settingsArchiveNilIfEmpty
            ?? askURL.lastPathComponent
        let createdAt = metadata.createdAt.flatMap(SettingsArchiveScanner.parseISODate) ?? fallbackDate

        return SettingsAskHistoryEntry(
            id: askURL.path,
            dayKey: dayKey,
            askID: askID,
            createdAt: createdAt,
            questionText: SettingsArchiveScanner.readTrimmedText(
                at: askURL.appendingPathComponent("agent-transcript.txt")
            ),
            questionAudioPath: SettingsArchiveScanner.existingFile(
                askURL.appendingPathComponent("agent-audio.mp3")
            ),
            responseTranscript: SettingsArchiveScanner.readTrimmedText(
                at: askURL.appendingPathComponent("voicelayer-transcript.txt")
            ),
            responseAudioPath: SettingsArchiveScanner.existingFile(
                askURL.appendingPathComponent("audio.wav")
            )
        )
    }

    private static func newestFirst(
        _ groups: [SettingsAskHistoryDayGroup]
    ) -> [SettingsAskHistoryDayGroup] {
        groups.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.dayKey > rhs.dayKey
            }
            return lhs.date > rhs.date
        }
    }

    private static func newestFirst(
        _ entries: [SettingsAskHistoryEntry]
    ) -> [SettingsAskHistoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.askID > rhs.askID
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
