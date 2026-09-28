import Foundation

/// One in-memory index of the recordings archive for History's two scopes (Dictations and Ask).
///
/// AIDEV-NOTE: Etan (2.2.24 review): switching Recording↔Ask is slow, and reopening History is slow "even
/// though I was just there". `SettingsHistoryArchive.loadPage` re-walks the day directories and re-decodes every
/// entry up to the limit on every call. This actor walks the tree once, decodes each entry at most once per
/// scope, and serves later pages from memory. It stays exact:
/// - the walk order and skip rules mirror `SettingsArchiveScanner.scan`, and a page is assembled by the SAME
///   `page(from:)` the scanner path uses, so an indexed page equals a scanned one (tested on a mixed archive);
/// - every call re-checks the day directories' modification dates, so a new recording shows up;
/// - an entry rewritten in place (a re-transcription) is dropped by `invalidate(entryPath:)`;
/// - `release()` drops everything when Settings closes (P09b follow-up 3, R1); decoding runs inside an
///   `autoreleasepool` so a large first page doesn't leave Foundation garbage behind (R2).
public actor SettingsArchiveIndex {
    public static let shared = SettingsArchiveIndex()

    private struct Candidate {
        let url: URL
        let dayKey: String
        let dayDate: Date

        /// `day/entry`, unique within one archive root and independent of how the root path was spelled
        /// (the directory listing resolves `/var` to `/private/var`; a caller's audio path may not).
        var id: String {
            SettingsArchiveIndex.key(forEntryDirectory: url)
        }
    }

    /// A decoded entry, or `.skipped` when the scope's loader rejected the directory.
    private enum Decoded<Entry> {
        case entry(Entry)
        case skipped
    }

    private final class RootState {
        /// Newest-first day directories. A day's entries are listed only when a walk reaches it, so the first page
        /// never lists the whole archive.
        var days: [URL] = []
        var candidatesByDay: [String: [Candidate]] = [:]
        var dayModifiedAt: [String: Date] = [:]
        var dictations: [String: Decoded<SettingsHistoryEntry>] = [:]
        var asks: [String: Decoded<SettingsAskHistoryEntry>] = [:]
        /// Folded searchable fields per entry, read without decoding the entry (H1-c). Ask keeps the question and
        /// the answer apart so a query never matches across them.
        var dictationSearchText: [String: [String]] = [:]
        var askSearchText: [String: [String]] = [:]
    }

    private var roots: [String: RootState] = [:]
    /// Bumped by `release()`, so a prewarm that was mid-walk when Settings closed stops instead of refilling.
    private var releaseEpoch = 0

    public init() {}

    /// The first `limit` Dictations, or with a non-blank `query` the first `limit` whose transcript matches it.
    public func dictationPage(
        from root: URL = SettingsHistoryArchive.defaultRoot,
        limit: Int = SettingsHistoryArchive.defaultPageSize,
        matching query: String = ""
    ) -> SettingsHistoryPage {
        let state = refreshedState(for: root)
        let search = SettingsHistorySearch(query)
        let scan = walk(
            state, limit: limit, cache: \.dictations, load: SettingsHistoryArchive.loadEntry,
            prefilter: search.isActive ? { candidate in
                self.searchText(
                    for: candidate,
                    in: state,
                    cache: \.dictationSearchText,
                    read: Self.dictationSearchFields
                )
                .contains(where: search.matches(folded:))
            } : nil
        )
        return SettingsHistoryArchive.page(from: scan)
    }

    /// The first `limit` Ask exchanges, or with a non-blank `query` the first `limit` whose question or response
    /// matches it.
    public func askPage(
        from root: URL = SettingsAskHistoryArchive.defaultRoot,
        limit: Int = SettingsAskHistoryArchive.defaultPageSize,
        matching query: String = ""
    ) -> SettingsAskHistoryPage {
        let state = refreshedState(for: root)
        let search = SettingsHistorySearch(query)
        let scan = walk(
            state, limit: limit, cache: \.asks, load: SettingsAskHistoryArchive.loadEntry,
            prefilter: search.isActive ? { candidate in
                self.searchText(for: candidate, in: state, cache: \.askSearchText, read: Self.askSearchFields)
                    .contains(where: search.matches(folded:))
            } : nil
        )
        return SettingsAskHistoryArchive.page(from: scan)
    }

    /// Drops one entry (by its audio path or its directory) so the next page decodes it again.
    public func invalidate(entryPath: String) {
        let url = URL(fileURLWithPath: entryPath)
        let id = Self.key(forEntryDirectory: url.pathExtension.isEmpty ? url : url.deletingLastPathComponent())
        for state in roots.values {
            state.dictations.removeValue(forKey: id)
            state.asks.removeValue(forKey: id)
            state.dictationSearchText.removeValue(forKey: id)
            state.askSearchText.removeValue(forKey: id)
        }
    }

    /// Settings closed: drop the whole index.
    public func release() {
        roots.removeAll()
        releaseEpoch &+= 1
    }

    func cachedRootCount() -> Int {
        roots.count
    }

    func cachedSearchTextCount() -> Int {
        roots.values.reduce(0) { $0 + $1.dictationSearchText.count }
    }

    // MARK: - Search prewarm

    /// Reads and folds every entry's search text so the first search of a Settings session is warm (lead add-on:
    /// it was 2.3–3.2 s cold on the real archive).
    ///
    /// AIDEV-NOTE: This runs in the background and must never delay a page the user asked for. The actor is
    /// reentrant at `await`, so yielding every `chunkSize` entries lets a queued page load or search run in
    /// between. It stops when its task is cancelled (History went away) or when `release()` ran (Settings closed),
    /// so it can't refill a released index.
    /// Returns how many entries it visited.
    @discardableResult
    public func prewarmSearchText(
        from root: URL = SettingsHistoryArchive.defaultRoot,
        chunkSize: Int = 128
    ) async -> Int {
        let epoch = releaseEpoch
        let state = refreshedState(for: root)
        var sinceYield = 0
        var visited = 0
        for day in state.days {
            for candidate in candidates(of: day, in: state) {
                guard !Task.isCancelled, epoch == releaseEpoch else { return visited }
                visited += 1
                let needsDictation = state.dictationSearchText[candidate.id] == nil
                let needsAsk = state.askSearchText[candidate.id] == nil
                if needsDictation || needsAsk {
                    // One read of the shared transcript fills both scopes; folded exactly as the page path does.
                    let transcript = Self.folded(candidate.url, "voicelayer-transcript.txt")
                    if needsDictation { state.dictationSearchText[candidate.id] = [transcript] }
                    if needsAsk {
                        state.askSearchText[candidate.id] = [
                            Self.folded(candidate.url, "agent-transcript.txt"),
                            transcript,
                        ]
                    }
                }
                sinceYield += 1
                if sinceYield >= max(chunkSize, 1) {
                    sinceYield = 0
                    await Task.yield()
                }
            }
        }
        return visited
    }

    private static func dictationSearchFields(_ entry: URL) -> [String] {
        [SettingsArchiveScanner.readTrimmedText(at: entry.appendingPathComponent("voicelayer-transcript.txt"))]
    }

    private static func askSearchFields(_ entry: URL) -> [String] {
        [
            SettingsArchiveScanner.readTrimmedText(at: entry.appendingPathComponent("agent-transcript.txt")),
            SettingsArchiveScanner.readTrimmedText(at: entry.appendingPathComponent("voicelayer-transcript.txt")),
        ]
    }

    private static func folded(_ entry: URL, _ file: String) -> String {
        SettingsHistorySearch.fold(SettingsArchiveScanner.readTrimmedText(at: entry.appendingPathComponent(file)))
    }

    // MARK: - Walk

    /// The first `limit` entries that pass `prefilter` (when searching) and the scope's loader accepts, in
    /// `SettingsArchiveScanner.scan` order, with `hasMore` exact (true only when one more such entry loads).
    private func walk<Entry>(
        _ state: RootState,
        limit: Int,
        cache: ReferenceWritableKeyPath<RootState, [String: Decoded<Entry>]>,
        load: (URL, String, Date) -> Entry?,
        prefilter: ((Candidate) -> Bool)?
    ) -> SettingsArchiveScanResult<Entry> {
        let boundedLimit = max(0, limit)
        var days: [SettingsArchiveDayScan<Entry>] = []
        var current: (dayKey: String, date: Date, entries: [Entry])?
        var loadedEntryCount = 0
        var hasMore = false

        autoreleasepool {
            // A load cancelled by a scope switch stops here: the actor is held until the walk ends, and the next
            // scope's page waits behind it. The caller discards the partial page; decoded entries stay valid.
            walking: for day in state.days {
                guard !Task.isCancelled else { break walking }
                for candidate in candidates(of: day, in: state) {
                    guard !Task.isCancelled else { break walking }
                    // A search reads only the entry's text first; the full entry is decoded for a hit alone.
                    if let prefilter, !prefilter(candidate) { continue }
                    let decoded: Decoded<Entry>
                    if let cached = state[keyPath: cache][candidate.id] {
                        decoded = cached
                    } else {
                        decoded = load(candidate.url, candidate.dayKey, candidate.dayDate)
                            .map { .entry($0) } ?? .skipped
                        state[keyPath: cache][candidate.id] = decoded
                    }
                    guard case let .entry(entry) = decoded else { continue }
                    if loadedEntryCount == boundedLimit {
                        hasMore = true
                        break walking
                    }
                    if current?.dayKey != candidate.dayKey {
                        if let finished = current {
                            days.append(SettingsArchiveDayScan(dayKey: finished.dayKey, date: finished.date,
                                                               entries: finished.entries))
                        }
                        current = (candidate.dayKey, candidate.dayDate, [])
                    }
                    current?.entries.append(entry)
                    loadedEntryCount += 1
                }
            }
        }
        if let finished = current, !finished.entries.isEmpty {
            days.append(SettingsArchiveDayScan(dayKey: finished.dayKey, date: finished.date, entries: finished.entries))
        }
        return SettingsArchiveScanResult(days: days, loadedEntryCount: loadedEntryCount, hasMore: hasMore)
    }

    // MARK: - Directory state

    private func refreshedState(for root: URL) -> RootState {
        let key = root.standardizedFileURL.path
        let state = roots[key] ?? RootState()
        roots[key] = state
        state.days = dayURLs(root: root)
        let currentKeys = Set(state.days.map(\.lastPathComponent))
        // A listed day whose directory changed (a new entry) or vanished is listed again on the next walk.
        for (dayKey, listedAt) in state.dayModifiedAt {
            let day = root.appendingPathComponent(dayKey)
            if !currentKeys.contains(dayKey) || Self.modificationDate(day) != listedAt {
                evictDay(dayKey, in: state)
            }
        }
        return state
    }

    /// AIDEV-NOTE: on the real 11k archive a search that decoded every entry took 9 s cold and 1 s warm; reading
    /// only the text and folding it once is what makes a whole-archive search affordable.
    private func searchText(
        for candidate: Candidate,
        in state: RootState,
        cache: ReferenceWritableKeyPath<RootState, [String: [String]]>,
        read: (URL) -> [String]
    ) -> [String] {
        if let cached = state[keyPath: cache][candidate.id] { return cached }
        let folded = read(candidate.url).map(SettingsHistorySearch.fold)
        state[keyPath: cache][candidate.id] = folded
        return folded
    }

    private func candidates(of day: URL, in state: RootState) -> [Candidate] {
        let dayKey = day.lastPathComponent
        if let listed = state.candidatesByDay[dayKey] { return listed }
        let modifiedAt = Self.modificationDate(day)
        let listed = scanDay(day)
        state.candidatesByDay[dayKey] = listed
        state.dayModifiedAt[dayKey] = modifiedAt
        return listed
    }

    private func evictDay(_ dayKey: String, in state: RootState) {
        for candidate in state.candidatesByDay[dayKey] ?? [] {
            state.dictations.removeValue(forKey: candidate.id)
            state.asks.removeValue(forKey: candidate.id)
            state.dictationSearchText.removeValue(forKey: candidate.id)
            state.askSearchText.removeValue(forKey: candidate.id)
        }
        state.candidatesByDay.removeValue(forKey: dayKey)
        state.dayModifiedAt.removeValue(forKey: dayKey)
    }

    /// Same selection and order as `SettingsArchiveScanner.scan`: visible directories, newest day first.
    private func dayURLs(root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.isArchiveDirectory && SettingsArchiveScanner.parseDayKey($0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func scanDay(_ day: URL) -> [Candidate] {
        let dayKey = day.lastPathComponent
        guard let date = SettingsArchiveScanner.parseDayKey(dayKey) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(
            at: day, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.isArchiveDirectory && !$0.lastPathComponent.hasPrefix(".tmp-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { Candidate(url: $0, dayKey: dayKey, dayDate: date) }
    }

    private static func key(forEntryDirectory directory: URL) -> String {
        "\(directory.deletingLastPathComponent().lastPathComponent)/\(directory.lastPathComponent)"
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
