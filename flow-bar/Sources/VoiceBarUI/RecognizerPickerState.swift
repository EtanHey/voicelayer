import Foundation
import CoreFoundation

public enum RecognizerPickerEngine: String, CaseIterable, Identifiable, Sendable {
    case parakeet, whisper
    public var id: Self { self }
    public var title: String {
        switch self {
        case .parakeet: "Parakeet TDT 0.6B v3"
        case .whisper: "Whisper large-v3-turbo"
        }
    }
}

public enum RecognizerPickerResidency: String, Sendable {
    case loaded, loading, unloaded, error, unknown
    public var title: String {
        switch self {
        case .loaded: "Ready"
        case .loading: "Loading…"
        case .unloaded: "Sleeping (loads when you dictate)"
        case .error: "Error"
        case .unknown: "Unknown"
        }
    }
    init?(phase: String) {
        switch phase {
        case "ready": self = .loaded
        case "loading": self = .loading
        case "sleeping": self = .unloaded
        case "error": self = .error
        default: return nil
        }
    }
}

public enum RecognizerManagementAction: String, Sendable {
    case load, unload, download, delete, cancelDownload
    public var command: String {
        switch self {
        case .load, .unload: "set_recognizer_residency"
        case .download: "download_recognizer"
        case .delete: "delete_recognizer"
        case .cancelDownload: "cancel_recognizer_download"
        }
    }
}
public struct RecognizerDownloadProgress: Equatable, Sendable {
    public let state: String
    public let received: Int
    public let total: Int
    public let error: String?
    public var isActive: Bool { ["downloading", "verifying", "runtime"].contains(state) }
}

/// Exact PICKER-API v1 snapshot. Unknown availability remains nil, never false.
public struct RecognizerStatusSnapshot: Equatable, Sendable {
    public struct Engine: Equatable, Sendable {
        public let phase: RecognizerPickerResidency
        public let available: Bool?
        public fileprivate(set) var assetsPresent: Bool
        public fileprivate(set) var diskBytes: Int
        public let error: String?
        public let download: RecognizerDownloadProgress?
    }
    public let revision: Int
    public let desired: RecognizerPickerEngine
    public let effective: RecognizerPickerEngine?
    public let phase: RecognizerPickerResidency
    public private(set) var parakeet: Engine
    public private(set) var whisper: Engine
    public let fallbackReason: String?
    public private(set) var switchAllowed: Bool
    public private(set) var switchRefusalReason: String?
    public let idleUnloadSeconds: Double
    public let source: String

    public init?(payload: [String: Any]) {
        func boolean(_ value: Any?) -> Bool? {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        func integer(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < Double(Int.max),
                  n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.intValue
        }
        func idleSeconds(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue > 0, n.doubleValue <= 2_147_483 else { return nil }
            return n.doubleValue
        }
        func nullableString(_ key: String, in d: [String: Any]) -> Bool {
            d[key] is NSNull || d[key] is String
        }
        func engine(_ value: Any?) -> Engine? {
            guard let d = value as? [String: Any], let phaseText = d["phase"] as? String,
                  let phase = RecognizerPickerResidency(phase: phaseText),
                  d["available"] is NSNull || boolean(d["available"]) != nil,
                  nullableString("error", in: d) else { return nil }
            var download: RecognizerDownloadProgress?
            if let progress = d["download"] as? [String: Any], let state = progress["state"] as? String,
               let received = integer(progress["received_bytes"]), let total = integer(progress["total_bytes"]) {
                download = RecognizerDownloadProgress(state: state, received: received, total: total, error: progress["error"] as? String)
            }
            return Engine(phase: phase, available: boolean(d["available"]), assetsPresent: boolean(d["assets_present"]) ?? false, diskBytes: integer(d["disk_bytes"]) ?? 0, error: d["error"] as? String, download: download)
        }
        guard let revision = integer(payload["revision"]),
              let desiredText = payload["desired"] as? String, let desired = RecognizerPickerEngine(rawValue: desiredText),
              payload["effective"] is NSNull || (payload["effective"] as? String).flatMap(RecognizerPickerEngine.init(rawValue:)) != nil,
              let phaseText = payload["phase"] as? String, let phase = RecognizerPickerResidency(phase: phaseText),
              let engines = payload["engines"] as? [String: Any],
              let parakeet = engine(engines["parakeet"]), let whisper = engine(engines["whisper"]),
              nullableString("fallback_reason", in: payload), nullableString("switch_refusal_reason", in: payload),
              let switchAllowed = boolean(payload["switch_allowed"]),
              let idle = idleSeconds(payload["idle_unload_seconds"]),
              let source = payload["source"] as? String, ["settings", "env", "default"].contains(source)
        else { return nil }
        let effective = (payload["effective"] as? String).flatMap(RecognizerPickerEngine.init(rawValue:))
        // Effective records current/last provenance, including after a one-shot provider exits.
        // Only authoritative phases describe residency; availability remains nullable.
        self.revision = revision; self.desired = desired; self.effective = effective; self.phase = phase
        self.parakeet = parakeet; self.whisper = whisper
        self.fallbackReason = payload["fallback_reason"] as? String
        self.switchAllowed = switchAllowed; self.switchRefusalReason = payload["switch_refusal_reason"] as? String
        self.idleUnloadSeconds = idle; self.source = source
    }

    /// Reads recompute busy permission without publishing a new engine revision.
    /// Preserve all accepted engine/preference/provenance fields at equal revisions.
    func updatingSwitchPermission(from currentRead: Self) -> Self {
        var updated = self
        updated.parakeet.assetsPresent = currentRead.parakeet.assetsPresent
        updated.parakeet.diskBytes = currentRead.parakeet.diskBytes
        updated.whisper.assetsPresent = currentRead.whisper.assetsPresent
        updated.whisper.diskBytes = currentRead.whisper.diskBytes
        updated.switchAllowed = currentRead.switchAllowed
        updated.switchRefusalReason = currentRead.switchRefusalReason
        return updated
    }
}

/// No persistence, engine calls, optimistic selection, or UI-owned idle timer.
public struct RecognizerPickerState: Equatable, Sendable {
    public let selected: RecognizerPickerEngine?
    public let effective: RecognizerPickerEngine?
    public let parakeet: RecognizerPickerResidency
    public let whisper: RecognizerPickerResidency
    public let disabledReason: String?
    public let fallbackReason: String?
    public let commandNotice: String?
    public let parakeetAvailable: Bool?
    public let parakeetError: String?
    public let parakeetAssetsPresent: Bool
    public let whisperAssetsPresent: Bool
    public let diskBytes: [RecognizerPickerEngine: Int]
    public let downloads: [RecognizerPickerEngine: RecognizerDownloadProgress]

    public init(selected: RecognizerPickerEngine?, effective: RecognizerPickerEngine?,
                parakeet: RecognizerPickerResidency, whisper: RecognizerPickerResidency,
                disabledReason: String? = nil, fallbackReason: String? = nil, notice: String? = nil,
                parakeetAvailable: Bool? = nil, parakeetError: String? = nil,
                parakeetAssetsPresent: Bool = false, whisperAssetsPresent: Bool = true,
                diskBytes: [RecognizerPickerEngine: Int] = [:], downloads: [RecognizerPickerEngine: RecognizerDownloadProgress] = [:]) {
        self.selected = selected; self.effective = effective; self.parakeet = parakeet; self.whisper = whisper
        self.disabledReason = disabledReason; self.fallbackReason = fallbackReason; self.commandNotice = notice
        self.diskBytes = diskBytes; self.downloads = downloads
        self.parakeetAssetsPresent = parakeetAssetsPresent; self.whisperAssetsPresent = whisperAssetsPresent
        self.parakeetAvailable = parakeetAvailable; self.parakeetError = parakeetError
    }
    public init(snapshot: RecognizerStatusSnapshot, pending: Bool = false, notice: String? = nil, busyReason: String? = nil) {
        self.init(selected: snapshot.desired, effective: snapshot.effective,
                  parakeet: snapshot.parakeet.phase, whisper: snapshot.whisper.phase,
                  disabledReason: busyReason ?? (pending ? "Waiting for VoiceLayer…" : (!snapshot.switchAllowed
                    ? Self.message(for: snapshot.switchRefusalReason) : nil)),
                  fallbackReason: snapshot.fallbackReason, notice: notice, parakeetAvailable: snapshot.parakeet.available, parakeetError: snapshot.parakeet.error,
                  parakeetAssetsPresent: snapshot.parakeet.assetsPresent, whisperAssetsPresent: snapshot.whisper.assetsPresent,
                  diskBytes: [.parakeet: snapshot.parakeet.diskBytes, .whisper: snapshot.whisper.diskBytes],
                  downloads: [.parakeet: snapshot.parakeet.download, .whisper: snapshot.whisper.download].compactMapValues { $0 })
    }
    public static let unavailable = RecognizerPickerState(selected: nil, effective: nil,
        parakeet: .unknown, whisper: .unknown, disabledReason: "Recognizer status unavailable")
    public func residency(for engine: RecognizerPickerEngine) -> RecognizerPickerResidency {
        engine == .parakeet ? parakeet : whisper
    }
    /// Provisioning is independent of whether the engine has ever loaded.
    public var parakeetNotSetUp: Bool { !parakeetAssetsPresent }
    public func assetsPresent(for engine: RecognizerPickerEngine) -> Bool {
        engine == .parakeet ? parakeetAssetsPresent : whisperAssetsPresent
    }
    public func assetActions(for engine: RecognizerPickerEngine) -> [RecognizerManagementAction] {
        var actions: [RecognizerManagementAction] = assetsPresent(for: engine) ? [] : [.download]
        if assetsPresent(for: engine) || (diskBytes[engine] ?? 0) > 0 { actions.append(.delete) }
        return actions
    }
    public func canManage(_ engine: RecognizerPickerEngine, action: RecognizerManagementAction) -> Bool {
        if action == .cancelDownload { return downloads[engine]?.isActive == true }
        guard !isSelectionDisabled, downloads.values.allSatisfy({ !$0.isActive }) else { return false }
        switch action {
        case .load: return assetsPresent(for: engine) && selected == engine && residency(for: engine) != .loaded
        case .unload: return residency(for: engine) == .loaded || residency(for: engine) == .error
        case .download: return !assetsPresent(for: engine)
        case .delete: return (diskBytes[engine] ?? 0) > 0 && residency(for: engine) == .unloaded
            && assetsPresent(for: engine == .parakeet ? .whisper : .parakeet)
        case .cancelDownload: return false
        }
    }
    public var parakeetSetupReason: String? {
        parakeetNotSetUp ? "Needs a one-time setup" : nil
    }
    public func statusText(for engine: RecognizerPickerEngine) -> String {
        if engine == .whisper, !assetsPresent(for: engine) { return "Not downloaded" }
        if engine == .parakeet {
            if parakeetNotSetUp { return "Not set up" }
            if parakeet == .loaded, parakeetAvailable != true { return "Unknown" }
            if parakeet == .unloaded, parakeetAvailable == false { return "Unavailable" }
        }
        return residency(for: engine).title
    }
    public var isSelectionDisabled: Bool {
        disabledReason != nil || selected == nil || parakeet == .unknown || whisper == .unknown
            || parakeet == .loading || whisper == .loading
    }
    /// Product decision: desired selection keeps controls stable through transient fallback.
    /// The backend retains the saved value for Whisper; this controls UI applicability only.
    public var smartChunkingApplicable: Bool {
        selected == .whisper
    }
    public var explanation: String? {
        if let commandNotice { return commandNotice }
        if downloads.values.contains(where: { $0.isActive }) { return nil }
        for engine in RecognizerPickerEngine.allCases {
            if let failure = downloads[engine], failure.state == "error", let reason = failure.error {
                return engine.title + ": " + Self.message(for: reason)
            }
        }
        if fallbackReason == "vad-no-speech" { return "No speech detected." }
        if selected == .parakeet, effective == .whisper, fallbackReason == "parakeet-startup-failed" {
            return "Using Whisper: Parakeet failed to load"
        }
        if selected == .whisper, effective == .parakeet, fallbackReason == "whisper-startup-failed" {
            return "Using Parakeet — Whisper failed to load"
        }
        if let fallbackReason, effective == .whisper { return Self.message(for: fallbackReason, fallback: true) }
        if let disabledReason { return disabledReason }
        if parakeet == .loading || whisper == .loading { return "Switching recognizer…" }
        if selected == .parakeet, parakeet == .error { return "Parakeet is unavailable; choose Whisper or try again later." }
        if selected == .whisper, whisper == .error { return "Whisper is unavailable; try again later." }
        return isSelectionDisabled ? "Recognizer status unavailable" : nil
    }
    public static func message(for reason: String?, fallback: Bool = false) -> String {
        if fallback {
            switch reason {
            // Legacy snapshots may carry these reasons. Report the observed provider
            // without implying that language hints or prompts route away from the user's choice.
            case "language", "prompt", "input-format", "input-identity": return "Using Whisper for this recording."
            default: return "Using Whisper because Parakeet couldn't transcribe this recording."
            }
        }
        switch reason {
        case "capture-active": return "Finish recording before switching recognizers."
        case "request-active": return "Wait for transcription before switching recognizers."
        case "voice-busy": return "Wait for the voice session before switching recognizers."
        case "transition-active": return "Wait for the recognizer to finish switching."
        case "environment-override": return "Recognizer selection is set by the environment."
        case "cleanup-unconfirmed": return "VoiceLayer couldn't stop the previous recognizer; reconnect before switching."
        case "assets-not-present": return "Download this recognizer first."
        case "select-recognizer-first": return "Select this recognizer before loading it."
        case "recognizer-loaded": return "Unload this recognizer before deleting it."
        case "last-installed-recognizer": return "Keep at least one downloaded recognizer."
        case "insufficient-disk-space": return "There isn't enough free disk space for this download."
        case "download-checksum-mismatch": return "The download couldn't be verified. Try downloading again."
        case "download-http-failed", "download-size-mismatch", "download-failed": return "The download failed. Check your connection and try again."
        case "download-cleanup-failed": return "Download staging files couldn't be removed. Reconnect and try again."
        case "assets-validation-failed": return "Setup couldn't validate the model and runtime. Try again."
        case "download-cancelled": return "Download cancelled."
        case "assets-exist-delete-first": return "Delete the incomplete model files before downloading again."
        case "external-model-link": return "These model files are shared links; manage them in their original location."
        case "parakeet-runtime-setup-failed", "python-runtime-missing", "configured-python-missing": return "Runtime setup failed. Check Python 3.12–3.14 and try again."
        case "invalid-recognizer": return "This recognizer isn't supported by VoiceLayer."
        default: return "Recognizer switching is unavailable."
        }
    }
    public var retryEngine: RecognizerPickerEngine? {
        guard let selected, residency(for: selected) == .error,
              assetsPresent(for: selected) else { return nil }
        return selected
    }
    public func canSelect(_ engine: RecognizerPickerEngine) -> Bool {
        !isSelectionDisabled && assetsPresent(for: engine)
            && (engine != selected || retryEngine == engine)
    }
    @discardableResult public func select(_ engine: RecognizerPickerEngine,
                                         send: ((RecognizerPickerEngine) -> Void)?) -> Bool {
        guard canSelect(engine), let send else { return false }
        send(engine); return true
    }
}
