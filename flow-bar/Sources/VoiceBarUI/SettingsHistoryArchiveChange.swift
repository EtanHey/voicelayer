import Foundation

/// One archive directory was rewritten. Materialized by the archive actor, then applied without a page scan.
public struct SettingsHistoryArchiveChange: Sendable {
    public let directory: URL
    public let dictation: SettingsHistoryEntry?
    public let ask: SettingsAskHistoryEntry?
    public let revision: UInt64

    public func applying(to page: SettingsHistoryPage, matching query: String = "") -> SettingsHistoryPage {
        let search = SettingsHistorySearch(query)
        let replacement = dictation.flatMap { search.matches($0.transcript) ? $0 : nil }
        var groups = page.groups
        let dayKey = directory.deletingLastPathComponent().lastPathComponent
        let groupIndex = groups.firstIndex { $0.dayKey == dayKey }
        let rowIndex = groupIndex.flatMap { group in
            groups[group].entries.firstIndex { sameDirectory($0.audioPath.deletingLastPathComponent()) }
        }
        if let group = groupIndex, let row = rowIndex {
            var entries = groups[group].entries
            if let replacement {
                // Keep the published id (and SwiftUI's selection identity), including /var spelling.
                guard entries[row] != replacement else { return page }
                entries[row] = replacement
            } else {
                entries.remove(at: row)
            }
            let old = groups[group]
            groups[group] = SettingsHistoryDayGroup(dayKey: old.dayKey, date: old.date, entries: entries)
            if entries.isEmpty { groups.remove(at: group) }
        } else if let replacement, shouldInsert(in: page) {
            if let group = groupIndex {
                let old = groups[group]
                let entries = (old.entries + [replacement]).sorted {
                    $0.createdAt == $1.createdAt ? $0.recordingID > $1.recordingID : $0.createdAt > $1.createdAt
                }
                groups[group] = SettingsHistoryDayGroup(dayKey: old.dayKey, date: old.date, entries: entries)
            } else {
                let date = SettingsArchiveScanner.parseDayKey(dayKey) ?? replacement.createdAt
                groups.append(SettingsHistoryDayGroup(dayKey: dayKey, date: date, entries: [replacement]))
                groups.sort { $0.dayKey > $1.dayKey }
            }
        } else {
            return page
        }
        // New rows extend the loaded window; never drop the selected tail row to maintain a page size.
        return SettingsHistoryPage(groups: groups, hasMore: page.hasMore)
    }

    public func applying(to page: SettingsAskHistoryPage, matching query: String = "") -> SettingsAskHistoryPage {
        let search = SettingsHistorySearch(query)
        let replacement = ask.flatMap { search.matches($0.questionText, $0.responseTranscript) ? $0 : nil }
        var groups = page.groups
        let dayKey = directory.deletingLastPathComponent().lastPathComponent
        let groupIndex = groups.firstIndex { $0.dayKey == dayKey }
        let rowIndex = groupIndex.flatMap { group in groups[group].entries.firstIndex { sameDirectory(URL(fileURLWithPath: $0.id)) } }
        if let group = groupIndex, let row = rowIndex {
            var entries = groups[group].entries
            if let replacement {
                guard entries[row] != replacement else { return page }
                entries[row] = replacement
            } else {
                entries.remove(at: row)
            }
            let old = groups[group]
            groups[group] = SettingsAskHistoryDayGroup(dayKey: old.dayKey, date: old.date, entries: entries)
            if entries.isEmpty { groups.remove(at: group) }
        } else if let replacement, shouldInsert(in: page) {
            if let group = groupIndex {
                let old = groups[group]
                let entries = (old.entries + [replacement]).sorted {
                    $0.createdAt == $1.createdAt ? $0.askID > $1.askID : $0.createdAt > $1.createdAt
                }
                groups[group] = SettingsAskHistoryDayGroup(dayKey: old.dayKey, date: old.date, entries: entries)
            } else {
                let date = SettingsArchiveScanner.parseDayKey(dayKey) ?? replacement.createdAt
                groups.append(SettingsAskHistoryDayGroup(dayKey: dayKey, date: date, entries: [replacement]))
                groups.sort { $0.dayKey > $1.dayKey }
            }
        } else {
            return page
        }
        return SettingsAskHistoryPage(groups: groups, hasMore: page.hasMore)
    }

    private func sameDirectory(_ other: URL) -> Bool {
        // The day + directory key is stable across /var and /private/var, without main-thread filesystem I/O.
        other.lastPathComponent == directory.lastPathComponent
            && other.deletingLastPathComponent().lastPathComponent == directory.deletingLastPathComponent().lastPathComponent
    }

    private func shouldInsert(in page: SettingsHistoryPage) -> Bool {
        guard page.hasMore, let tail = page.groups.last?.entries.last else { return true }
        return isAtLeastAsNew(as: tail.audioPath.deletingLastPathComponent())
    }

    private func shouldInsert(in page: SettingsAskHistoryPage) -> Bool {
        guard page.hasMore, let tail = page.groups.last?.entries.last else { return true }
        return isAtLeastAsNew(as: URL(fileURLWithPath: tail.id))
    }

    private func isAtLeastAsNew(as tail: URL) -> Bool {
        let day = directory.deletingLastPathComponent().lastPathComponent
        let tailDay = tail.deletingLastPathComponent().lastPathComponent
        return day == tailDay ? directory.lastPathComponent >= tail.lastPathComponent : day > tailDay
    }
}

/// Keep only the latest event for each row while a page snapshot is in flight. Actor reads may complete
/// before their main-actor notifications are delivered, so an older notification must never win.
public struct SettingsHistoryArchiveChanges {
    private var latest: [String: UInt64] = [:]
    private var pending: [String: SettingsHistoryArchiveChange] = [:]

    public init() {}

    public mutating func receive(_ change: SettingsHistoryArchiveChange, duringLoad: Bool) -> Bool {
        let key = change.directory.deletingLastPathComponent().lastPathComponent + "/" + change.directory.lastPathComponent
        guard change.revision >= latest[key, default: 0] else { return false }
        latest[key] = change.revision
        if duringLoad { pending[key] = change }
        return true
    }

    public mutating func takePending() -> [SettingsHistoryArchiveChange] {
        defer { pending.removeAll() }
        return Array(pending.values)
    }
}
