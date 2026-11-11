import Combine
import Foundation

/// Lane H: the notch History's Ask and Speech rows. It reads the archive with the Settings History tab's own
/// loaders (`SettingsAskHistoryArchive`, `SettingsSpeechHistoryArchive`), off the main actor, and only while a
/// History surface is open: the first surface to open loads, an archive change while one is open reloads, and with
/// none open it reads nothing and listens to nothing. Dictations stay the in-memory list the notch already has.
@MainActor
public final class NotchHistoryArchiveStore: ObservableObject {
    public struct Row: Equatable, Sendable {
        public let entry: RecentTranscriptionEntry
        /// What follows the time on the row's second line.
        public let detail: String?
    }

    public typealias Loader = @Sendable (Int) async -> [Row]

    public static let shared = NotchHistoryArchiveStore()
    static let limit = NotchHistoryMorph.maximumEntries

    /// Nil until the first load lands.
    @Published public private(set) var ask: [Row]?
    @Published public private(set) var speech: [Row]?
    /// How many archive loads this store has started.
    public private(set) var readCount = 0

    private let loadAsk: Loader
    private let loadSpeech: Loader
    private var openSurfaces = 0
    private var loadTask: Task<Void, Never>?
    private var changes: AnyCancellable?

    public init(loadAsk: Loader? = nil, loadSpeech: Loader? = nil) {
        // A test process never reads the real archive: without injected loaders both categories are empty.
        let isTest = !Self.readsRealArchive
        self.loadAsk = loadAsk ?? { limit in
            isTest ? [] : await Task.detached(priority: .userInitiated) {
                SettingsAskHistoryArchive.loadPage(limit: limit).groups.flatMap(\.entries).map(Self.row)
            }.value
        }
        self.loadSpeech = loadSpeech ?? { limit in
            isTest ? [] : await Task.detached(priority: .userInitiated) {
                SettingsSpeechHistoryArchive.load(limit: limit).map(Self.row)
            }.value
        }
    }

    /// False in any test process. `swift test` sets no XCTest environment variable, so this asks whether XCTest is
    /// loaded at all (the environment-only check let History tests read this Mac's real archive, 2026-11-11).
    nonisolated static var readsRealArchive: Bool {
        NSClassFromString("XCTestCase") == nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && ProcessInfo.processInfo.processName != "xctest"
    }

    func surfaceOpened() {
        openSurfaces += 1
        guard openSurfaces == 1 else { return }
        changes = NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload(debounce: true) } }
        reload(debounce: false)
    }

    func surfaceClosed() {
        openSurfaces = max(0, openSurfaces - 1)
        guard openSurfaces == 0 else { return }
        changes = nil
        loadTask?.cancel()
        loadTask = nil
    }

    private func reload(debounce: Bool) {
        guard openSurfaces > 0 else { return }
        loadTask?.cancel()
        loadTask = Task { [loadAsk, loadSpeech] in
            if debounce { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            readCount += 1
            async let asks = loadAsk(Self.limit)
            async let spoken = loadSpeech(Self.limit)
            let (askRows, speechRows) = await (asks, spoken)
            guard !Task.isCancelled else { return }
            ask = askRows
            speech = speechRows
        }
    }

    /// An Ask row leads with what the user answered; the question follows the time.
    nonisolated static func row(_ entry: SettingsAskHistoryEntry) -> Row {
        Row(
            entry: RecentTranscriptionEntry(text: entry.displayResponseTranscript, createdAt: entry.createdAt),
            detail: entry.hasQuestionText ? "Asked “\(NotchHistoryPresentation.firstWords(entry.questionText))”" : nil
        )
    }

    /// A Speech row leads with the text that was read aloud; its length follows the time.
    nonisolated static func row(_ entry: SettingsSpeechHistoryEntry) -> Row {
        Row(
            entry: RecentTranscriptionEntry(text: entry.preview, createdAt: entry.createdAt),
            detail: entry.status == "completed" || entry.durationMs == nil
                ? (entry.durationMs == nil ? entry.statusLabel : entry.durationLabel)
                : "\(entry.durationLabel) · \(entry.statusLabel)"
        )
    }
}
