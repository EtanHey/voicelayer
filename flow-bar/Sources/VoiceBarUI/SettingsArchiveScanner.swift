import Foundation

/// One day directory's worth of materialized archive entries.
struct SettingsArchiveDayScan<Entry> {
    let dayKey: String
    let date: Date
    let entries: [Entry]
}

/// A bounded newest-first walk over the recordings archive.
struct SettingsArchiveScanResult<Entry> {
    let days: [SettingsArchiveDayScan<Entry>]
    let loadedEntryCount: Int
    let hasMore: Bool
}

// AIDEV-NOTE: Shared by the Settings → History recording list and the Ask list. Both surfaces
// read the same `~/.local/share/voicelayer/recordings/<day>/<id>/` tree and differ only in which
// directories they claim (`loadEntry` returns nil to skip). Keeping the walk here is what stops
// the two lists drifting on ordering, paging, or `.tmp-` staging-directory skipping — and what
// keeps ask exchanges out of the recording list in exactly one place.
enum SettingsArchiveScanner {
    /// Walks `root/<yyyy-MM-dd>/<entry-id>/` newest day first, newest entry first, materializing
    /// at most `limit` entries. `hasMore` is exact: it is true only when a further entry actually
    /// loads, so a tail of directories the caller skips never leaves a dead "Load older" button.
    static func scan<Entry>(
        root: URL,
        limit: Int,
        loadEntry: (_ entryURL: URL, _ dayKey: String, _ fallbackDate: Date) -> Entry?
    ) -> SettingsArchiveScanResult<Entry> {
        let fileManager = FileManager.default
        guard let dayURLs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SettingsArchiveScanResult(days: [], loadedEntryCount: 0, hasMore: false)
        }

        let boundedLimit = max(0, limit)
        let sortedDayURLs = dayURLs
            .filter(\.isArchiveDirectory)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        var days: [SettingsArchiveDayScan<Entry>] = []
        var loadedEntryCount = 0
        var hasMore = false

        for dayURL in sortedDayURLs {
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
                .filter { $0.isArchiveDirectory && !$0.lastPathComponent.hasPrefix(".tmp-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }

            var entries: [Entry] = []
            var reachedLimit = false
            for entryURL in candidates {
                guard let entry = loadEntry(entryURL, dayKey, dayDate) else { continue }
                if loadedEntryCount == boundedLimit {
                    // One entry past the limit materialized, so older entries genuinely exist.
                    hasMore = true
                    reachedLimit = true
                    break
                }
                entries.append(entry)
                loadedEntryCount += 1
            }

            if !entries.isEmpty {
                days.append(SettingsArchiveDayScan(dayKey: dayKey, date: dayDate, entries: entries))
            }
            if reachedLimit {
                break
            }
        }

        return SettingsArchiveScanResult(
            days: days,
            loadedEntryCount: loadedEntryCount,
            hasMore: hasMore
        )
    }

    /// The archive's day directories are UTC `yyyy-MM-dd` names written by the MCP layer.
    static func parseDayKey(_ dayKey: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayKey)
    }

    static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func readTrimmedText(at url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func existingFile(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func dayTitle(for date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    static func shortTimestamp(for date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Common shape of every `metadata.json` the archive writes, narrowed to the fields both lists need.
struct SettingsArchiveMetadata: Decodable {
    let id: String?
    let createdAt: String?
    let source: String?
    /// Mic-on time: how long the recording actually ran.
    let durationMs: Int?
    /// The slice of that audio handed to speech-to-text.
    let transcribedDurationMs: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case source
        case durationMs = "duration_ms"
        case transcribedDurationMs = "transcribed_duration_ms"
    }

    /// True when this archive is an ask exchange rather than an F5 dictation.
    var isAskExchange: Bool {
        source == SettingsArchiveSchema.askSourceValue
    }

    static func load(from url: URL) -> SettingsArchiveMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SettingsArchiveMetadata.self, from: data)
    }
}

extension URL {
    var isArchiveDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

extension String {
    var settingsArchiveNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
