import Foundation

struct SettingsSpeechHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let originalText: String
    let spokenText: String
    let voice: String
    let status: String
    let reason: String?
    let durationMs: Int?
    let missingAudioCount: Int
    let audioPaths: [URL]
    var audioPath: URL? { audioPaths.first }

    var textsDiffer: Bool { originalText != spokenText }
    var preview: String { spokenText.isEmpty ? "No generated speech text stored" : String(spokenText.prefix(160)) }
    var durationLabel: String { durationMs.map { SettingsAudioPlaybackPosition.clockLabel(Double($0) / 1000) } ?? "Duration unavailable" }
    var statusLabel: String {
        switch status {
        case "completed": "Completed"
        case "stopped": "Stopped"
        case "replaced", "cancelled": "Cancelled"
        case "failed", "rejected": "Failed"
        case "interrupted_unknown", "interrupted": "Interrupted"
        case "received": "Received"
        case "requested": "Requested"
        case "preparing": "Preparing"
        case "playing": "Playing"
        case "paused": "Paused"
        default: "Unknown"
        }
    }

    var mediaPart: SettingsHistoryMediaPart {
        SettingsHistoryMediaPart(role: .speech, displayText: preview, isPlaceholder: spokenText.isEmpty,
            actionableText: spokenText.isEmpty ? nil : spokenText, audioPath: audioPath,
            durationLabel: durationLabel, transcribedDurationLabel: nil, playbackQueue: audioPaths)
    }
}

/// Read-only projection of the persisted speak store. Never recovers or rewrites live records.
enum SettingsSpeechHistoryArchive {
    static func load(from root: URL = SettingsHistoryArchive.defaultRoot, limit: Int = 100, now: Date = Date()) -> [SettingsSpeechHistoryEntry] {
        SettingsArchiveScanner.scan(root: root, limit: limit) { directory, day, date in
            loadEntry(from: directory, dayKey: day, fallbackDate: date, now: now)
        }.days
            .flatMap(\.entries).sorted { $0.createdAt > $1.createdAt }
    }

    private struct Metadata: Decodable {
        let schema_version: Int
        let source: String
        let id: String
        let created_at: String
        let status: String
        let requested: Requested?
        let lifecycle: Lifecycle?
        let speech: Speech?
        struct Speech: Decodable {
            let state: String
            let reason: String?
            let played_ms: Double?
            let playing_since: String?
            let generated: [Generated]
            struct Generated: Decodable { let index: Int; let text: String; let audio_path: String?; let voice: String? }
        }
        let artifacts: [Artifact]?
        struct Requested: Decodable { let voice: String? }
        struct Lifecycle: Decodable {
            let summary: Summary?
            struct Summary: Decodable { let generated_audio_ms: Double?; let error_code: String? }
        }
        struct Artifact: Decodable {
            let role: String
            let relative_path: String?
            let duration_ms: Double?
        }
    }

    private static func loadEntry(from directory: URL, dayKey: String, fallbackDate: Date, now: Date) -> SettingsSpeechHistoryEntry? {
        func safeFile(_ relative: String) -> URL? {
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
            let file = directory.appendingPathComponent(relative)
            let resolvedRoot = directory.resolvingSymlinksInPath().path + "/"
            guard file.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return file
        }
        guard let metadataURL = safeFile("metadata.json"), let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.schema_version == 1, metadata.source == "speak", metadata.id == directory.lastPathComponent else { return nil }
        func text(_ name: String) -> String {
            safeFile(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: metadata.created_at) ?? ISO8601DateFormatter().date(from: metadata.created_at) ?? fallbackDate
        let audio = metadata.artifacts?.first { $0.role == "playback_ready" && $0.relative_path.flatMap(safeFile) != nil }
        var played = metadata.speech?.played_ms
        if metadata.speech?.state == "playing", let since = metadata.speech?.playing_since,
           let start = formatter.date(from: since) ?? ISO8601DateFormatter().date(from: since) {
            played = (played ?? 0) + max(0, now.timeIntervalSince(start) * 1000)
        }
        let duration = metadata.lifecycle?.summary?.generated_audio_ms ?? played ?? audio?.duration_ms
        let generated = metadata.speech?.generated.sorted { $0.index < $1.index }
        let paths = generated.map { $0.compactMap { $0.audio_path.flatMap(safeFile) } }
            ?? (metadata.artifacts ?? []).filter { $0.role == "playback_ready" }.compactMap { $0.relative_path.flatMap(safeFile) }
        let voices = generated.map { Array(Set($0.compactMap(\.voice))).sorted().joined(separator: ", ") }
        return SettingsSpeechHistoryEntry(id: metadata.id, createdAt: date,
            originalText: text("input.txt"), spokenText: generated.map { $0.map(\.text).joined(separator: " ") } ?? text("spoken.txt"),
            voice: voices.flatMap { $0.isEmpty ? nil : $0 } ?? metadata.requested?.voice ?? "Voice unavailable", status: metadata.speech?.state ?? metadata.status,
            reason: metadata.speech?.reason ?? metadata.lifecycle?.summary?.error_code,
            durationMs: duration.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil },
            missingAudioCount: (generated?.count ?? (metadata.artifacts ?? []).filter { $0.role == "playback_ready" }.count) - paths.count,
            audioPaths: paths)
    }
}

/// One Speech history load, run from the scope's `.task(id:)`. Returns nil when that task was
/// cancelled (a newer load replaced it), so stale entries are never applied.
///
/// AIDEV-NOTE: Same debounce as `loadHistory`/`loadAskHistory`: an archive-change reload waits 300 ms
/// inside the cancellable task, so a burst of notifications restarts the wait and scans once. The scan
/// runs detached off the main actor; the cancellation handler forwards cancellation to it, and
/// `SettingsArchiveScanner.scan` checks `Task.isCancelled` per day and per entry.
enum SettingsSpeechHistoryReload {
    static func run(
        debounce: Bool,
        load: @escaping @Sendable () -> [SettingsSpeechHistoryEntry]
    ) async -> [SettingsSpeechHistoryEntry]? {
        if debounce {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else { return nil }
        let scan = Task.detached(priority: .utility, operation: load)
        let entries = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        return Task.isCancelled ? nil : entries
    }
}
