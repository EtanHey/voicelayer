import Foundation
import Darwin

public struct SettingsHistoryDiagnostics: Equatable, Sendable {
    public enum ArchiveState: Equatable, Sendable { case captured, transcribed, partial, failed, cancelled, unavailable }
    public enum SavedTextState: Equatable, Sendable { case present, empty, unavailable }
    public let archiveState: ArchiveState
    public let savedTextState: SavedTextState
    public let selection: String
    public let summary: String
    public let savedResult: String
    public let capturedAt: Date?
    public let backend: String?
    public let model: String?
    public let detail: String?
    public let warnings: [String]

    /// Retained archive language mode; never a current preference or detected-language substitution.
    public let languageSetting: String?
    public let inputDeviceName: String?
    public init(archiveState: ArchiveState, savedTextState: SavedTextState, selection: String,
                summary: String, savedResult: String, capturedAt: Date?, backend: String?, model: String?,
                detail: String?, warnings: [String], languageSetting: String? = nil, inputDeviceName: String? = nil) {
        self.archiveState = archiveState; self.savedTextState = savedTextState; self.selection = selection
        self.summary = summary; self.savedResult = savedResult; self.capturedAt = capturedAt
        self.backend = backend; self.model = model; self.detail = detail; self.warnings = warnings
        self.languageSetting = Self.retainedLabel(languageSetting)
        self.inputDeviceName = Self.retainedLabel(inputDeviceName)
    }
    private static func retainedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = SettingsHistoryDiagnosticPrivacy.text(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(120))
    }

    public static let metadataByteLimit = 65536

    /// Reads only fixed archive filenames, through directory descriptors with no symlink following.
    /// The selection is the on-disk day/directory, never a metadata-supplied path or timestamp.
    public static func load(audioPath: URL, root: URL) -> Self {
        let root = root.standardizedFileURL
        let audio = audioPath.standardizedFileURL
        let components = audio.pathComponents
        let rootComponents = root.pathComponents
        let valid = components.starts(with: rootComponents) && components.count == rootComponents.count + 3
            && audio.lastPathComponent == "audio.wav"
        let relative = valid ? Array(components.suffix(3).prefix(2)) : []
        let selection = relative.map(SettingsHistoryDiagnosticPrivacy.text).joined(separator: "/")
        func unavailable(_ warning: String) -> Self {
            Self(archiveState: .unavailable, savedTextState: .unavailable, selection: selection.isEmpty ? "Selection unavailable" : selection, summary: "Diagnostics unavailable",
                savedResult: "Saved result not checked", capturedAt: nil, backend: nil, model: nil, detail: nil, warnings: [warning])
        }
        guard valid, root.resolvingSymlinksInPath().path == root.path else {
            return unavailable("Archive selection is outside the allowed root or uses a symlink.")
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return unavailable("Archive root is unavailable.") }
        defer { close(rootFD) }
        let dayFD = openat(rootFD, relative[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dayFD >= 0 else { return unavailable("Archive day is unavailable or unsafe.") }
        defer { close(dayFD) }
        let entryFD = openat(dayFD, relative[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard entryFD >= 0 else { return unavailable("Archive entry is unavailable or unsafe.") }
        defer { close(entryFD) }
        // Only presence/size is needed. No transcript words or audio samples are read for diagnostics.
        let transcriptSize = fileSize("voicelayer-transcript.txt", in: entryFD)
        let savedTextState: SavedTextState = transcriptSize.map { $0 > 0 ? .present : .empty } ?? .unavailable
        let saved = transcriptSize.map { $0 > 0 ? "Saved transcript present; attempt identity unknown" : "Saved transcript is empty" }
            ?? "Saved transcript unavailable"
        let data: Data
        do { data = try readMetadata(in: entryFD) }
        catch { return Self(archiveState: .unavailable, savedTextState: savedTextState, selection: selection, summary: "Metadata unavailable", savedResult: saved,
            capturedAt: nil, backend: nil, model: nil, detail: nil,
            warnings: ["Metadata missing, unreadable, unsafe, or larger than 64 KiB. Earlier attempts were not recorded here."]) }
        guard let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self(archiveState: .unavailable, savedTextState: savedTextState, selection: selection, summary: "Metadata could not be read", savedResult: saved,
                capturedAt: nil, backend: nil, model: nil, detail: nil, warnings: ["Malformed metadata. Attempt history unavailable."])
        }
        let reason = metadata["not_transcribed_reason"] as? String
        let status = metadata["transcription_status"] as? String
        let summary: String
        if reason == "transcription-failed" { summary = "Speech recognition failed: see saved details" }
        else if status == "partial" { summary = "Archive reports a partial transcript" }
        else if status == "cancelled" { summary = "Recording cancelled" }
        else if let reason { summary = "Not transcribed: \(SettingsHistoryDiagnosticPrivacy.text(reason))" }
        else if status == "transcribed" { summary = "Archive reports a transcribed result" }
        else if status == "captured" { summary = "Recording captured; no successful transcription recorded" }
        else { summary = "Legacy entry: outcome unavailable" }
        var warnings = ["Earlier attempts and retry times are not retained in this archive format."]
        if let id = metadata["id"] as? String, id != relative[1] { warnings.append("Metadata ID differs from the selected folder. Folder identity is used.") }
        if reason != nil, (transcriptSize ?? 0) > 0 { warnings.append("Saved text and an error coexist. The error does not replace or validate the saved result.") }
        let provenance = metadata["provenance"] as? [String: Any]
        let archiveState: ArchiveState = reason == "transcription-failed" ? .failed
            : status == "partial" ? .partial : status == "cancelled" ? .cancelled : status == "transcribed" ? .transcribed
            : status == "captured" ? .captured : .unavailable
        return Self(archiveState: archiveState, savedTextState: savedTextState, selection: selection, summary: summary, savedResult: saved,
            capturedAt: (metadata["created_at"] as? String).flatMap(parseDate),
            backend: (metadata["backend"] as? String).flatMap { $0 == "not-transcribed" ? nil : SettingsHistoryDiagnosticPrivacy.text($0) },
            model: (provenance?["whisper_model_path"] as? String).map { SettingsHistoryDiagnosticPrivacy.text(URL(fileURLWithPath: $0).lastPathComponent) },
            detail: (metadata["not_transcribed_detail"] as? String).map(SettingsHistoryDiagnosticPrivacy.text), warnings: warnings,
            languageSetting: (provenance?["language_mode"] as? String) ?? (metadata["language_mode"] as? String),
            inputDeviceName: metadata["input_device_name"] as? String)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func fileSize(_ name: String, in directory: Int32) -> Int64? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return info.st_size
    }

    private static func readMetadata(in directory: Int32) throws -> Data {
        let fd = openat(directory, "metadata.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= metadataByteLimit else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while data.count <= metadataByteLimit {
            let count = read(fd, &bytes, min(bytes.count, metadataByteLimit + 1 - data.count))
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.count <= metadataByteLimit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
