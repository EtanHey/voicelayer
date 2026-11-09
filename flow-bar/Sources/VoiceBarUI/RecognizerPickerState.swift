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
    public var shortName: String { self == .parakeet ? "Parakeet" : "Whisper" }
    public var other: Self { self == .parakeet ? .whisper : .parakeet }
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

/// Keep-warm switch (Etan ruling: Parakeet stays resident; "Unload when idle" is OFF by default). Lane K2's contract
/// (K2-CONTRACT.md): `recognizer_status` carries flat `unload_when_idle: Bool`, `unload_when_idle_locked: Bool` and
/// `unload_when_idle_env_var: String?`; it governs Parakeet's idle eviction. Writes are
/// `{"cmd": "set_model_unload_when_idle", "value": Bool, "id": …}`, acked with a fresh `recognizer_status`.
/// An older daemon that omits `unload_when_idle` gets no row: a switch that changes nothing is worse than none.
public struct RecognizerUnloadWhenIdle: Equatable, Sendable {
    public static let command = "set_model_unload_when_idle"

    public let effective: Bool
    public let locked: Bool
    /// The override the daemon named, verbatim (VOICELAYER_MODEL_UNLOAD_WHEN_IDLE or the legacy
    /// VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS). Never guessed here.
    public let environmentVariable: String?

    public init(effective: Bool, locked: Bool = false, environmentVariable: String? = nil) {
        self.effective = effective; self.locked = locked; self.environmentVariable = environmentVariable
    }

    /// Reads the three flat fields from a `recognizer_status` payload; nil when `unload_when_idle` is absent or any
    /// present field has the wrong type.
    public init?(status payload: [String: Any]) {
        func boolean(_ value: Any?) -> Bool? {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        guard let effective = boolean(payload["unload_when_idle"]) else { return nil }
        let lockedValue = payload["unload_when_idle_locked"], variableValue = payload["unload_when_idle_env_var"]
        guard lockedValue == nil || boolean(lockedValue) != nil,
              variableValue == nil || variableValue is NSNull || variableValue is String else { return nil }
        let variable = (variableValue as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(effective: effective, locked: boolean(lockedValue) ?? false, environmentVariable: variable)
    }

    /// "Set by <VAR>" with the daemon's own variable name, like the Processing rows.
    public var lockedReason: String? {
        guard locked else { return nil }
        return environmentVariable.map { "Set by \($0)" } ?? "Set by the environment"
    }
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
    public private(set) var lastTranscriptionBackend: String? = nil
    public private(set) var switchAllowed: Bool
    public private(set) var switchRefusalReason: String?
    public let idleUnloadSeconds: Double
    public let source: String
    /// Optional keep-warm switch; nil when this daemon does not report one.
    public private(set) var unloadWhenIdle: RecognizerUnloadWhenIdle?

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
        self.lastTranscriptionBackend = payload["last_transcription_backend"] as? String
        self.fallbackReason = payload["fallback_reason"] as? String
        self.switchAllowed = switchAllowed; self.switchRefusalReason = payload["switch_refusal_reason"] as? String
        self.idleUnloadSeconds = idle; self.source = source
        self.unloadWhenIdle = RecognizerUnloadWhenIdle(status: payload)
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
        updated.unloadWhenIdle = currentRead.unloadWhenIdle
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
    public private(set) var lastTranscriptionBackend: String? = nil
    public let commandNotice: String?
    public let parakeetAvailable: Bool?
    public let parakeetError: String?
    public let parakeetAssetsPresent: Bool
    public let whisperAssetsPresent: Bool
    public let diskBytes: [RecognizerPickerEngine: Int]
    public let downloads: [RecognizerPickerEngine: RecognizerDownloadProgress]
    /// The daemon's idle-unload policy; nil when no snapshot reported one.
    public let idleUnloadSeconds: Double?
    /// The keep-warm switch; nil when the daemon does not report one.
    public let unloadWhenIdle: RecognizerUnloadWhenIdle?
    /// The keep-warm value sent to the daemon and not yet answered.
    public let unloadWhenIdlePending: Bool?

    public init(selected: RecognizerPickerEngine?, effective: RecognizerPickerEngine?,
                parakeet: RecognizerPickerResidency, whisper: RecognizerPickerResidency,
                disabledReason: String? = nil, fallbackReason: String? = nil, notice: String? = nil,
                parakeetAvailable: Bool? = nil, parakeetError: String? = nil,
                parakeetAssetsPresent: Bool = false, whisperAssetsPresent: Bool = true,
                diskBytes: [RecognizerPickerEngine: Int] = [:], downloads: [RecognizerPickerEngine: RecognizerDownloadProgress] = [:],
                idleUnloadSeconds: Double? = nil, unloadWhenIdle: RecognizerUnloadWhenIdle? = nil,
                unloadWhenIdlePending: Bool? = nil) {
        self.idleUnloadSeconds = idleUnloadSeconds; self.unloadWhenIdlePending = unloadWhenIdlePending
        self.unloadWhenIdle = unloadWhenIdle
        self.selected = selected; self.effective = effective; self.parakeet = parakeet; self.whisper = whisper
        self.disabledReason = disabledReason; self.fallbackReason = fallbackReason; self.commandNotice = notice
        self.diskBytes = diskBytes; self.downloads = downloads
        self.parakeetAssetsPresent = parakeetAssetsPresent; self.whisperAssetsPresent = whisperAssetsPresent
        self.parakeetAvailable = parakeetAvailable; self.parakeetError = parakeetError
    }
    public init(snapshot: RecognizerStatusSnapshot, pending: Bool = false, notice: String? = nil, busyReason: String? = nil,
                unloadWhenIdlePending: Bool? = nil) {
        self.init(selected: snapshot.desired, effective: snapshot.effective,
                  parakeet: snapshot.parakeet.phase, whisper: snapshot.whisper.phase,
                  disabledReason: busyReason ?? (pending ? "Waiting for VoiceLayer…" : (!snapshot.switchAllowed
                    ? Self.message(for: snapshot.switchRefusalReason) : nil)),
                  fallbackReason: snapshot.fallbackReason, notice: notice, parakeetAvailable: snapshot.parakeet.available, parakeetError: snapshot.parakeet.error,
                  parakeetAssetsPresent: snapshot.parakeet.assetsPresent, whisperAssetsPresent: snapshot.whisper.assetsPresent,
                  diskBytes: [.parakeet: snapshot.parakeet.diskBytes, .whisper: snapshot.whisper.diskBytes],
                  downloads: [.parakeet: snapshot.parakeet.download, .whisper: snapshot.whisper.download].compactMapValues { $0 },
                  idleUnloadSeconds: snapshot.idleUnloadSeconds, unloadWhenIdle: snapshot.unloadWhenIdle,
                  unloadWhenIdlePending: unloadWhenIdlePending)
        self.lastTranscriptionBackend = snapshot.lastTranscriptionBackend
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
    /// Something of this engine is on disk. CodeRabbit #672: a named model file can exist with zero bytes, which
    /// `disk_bytes` cannot show; the daemon's "delete first" download refusal is the evidence it is there.
    public func hasFilesOnDisk(_ engine: RecognizerPickerEngine) -> Bool {
        assetsPresent(for: engine) || (diskBytes[engine] ?? 0) > 0
            || downloads[engine]?.error == "assets-exist-delete-first"
    }
    /// S3: a download arrow when the model isn't on disk, a trash can when it is (both for an incomplete download).
    public func assetActions(for engine: RecognizerPickerEngine) -> [RecognizerManagementAction] {
        var actions: [RecognizerManagementAction] = assetsPresent(for: engine) ? [] : [.download]
        if hasFilesOnDisk(engine) { actions.append(.delete) }
        return actions
    }
    /// The Load/Unload control both rows show: Unload when resident, otherwise Load (which, on the row that is not
    /// selected, selects it — the daemon loads it and unloads the other).
    public func residencyAction(for engine: RecognizerPickerEngine) -> RecognizerManagementAction {
        residency(for: engine) == .loaded || residency(for: engine) == .error ? .unload : .load
    }
    public func canManage(_ engine: RecognizerPickerEngine, action: RecognizerManagementAction) -> Bool {
        if action == .cancelDownload { return downloads[engine]?.isActive == true }
        // S4: a download owns only its own engine; the other row stays fully usable.
        guard !isSelectionDisabled, downloads[engine]?.isActive != true else { return false }
        switch action {
        case .load: return assetsPresent(for: engine) && residency(for: engine) != .loaded
            && (selected == engine || canSelect(engine))
        case .unload: return residency(for: engine) == .loaded || residency(for: engine) == .error
        case .download: return !assetsPresent(for: engine)
        case .delete: return hasFilesOnDisk(engine) && residency(for: engine) == .unloaded
            && assetsPresent(for: engine.other) && selected != engine
        case .cancelDownload: return false
        }
    }
    /// Why the trash can't act right now, or nil when it can (a resident model is unloaded first). The button stays
    /// clickable and says this instead of sitting greyed out with the reason hidden in a tooltip.
    public func deleteBlockReason(for engine: RecognizerPickerEngine) -> String? {
        if downloads[engine]?.isActive == true { return "Wait for the download to finish, or cancel it." }
        if !assetsPresent(for: engine.other) {
            return "Keep at least one downloaded recognizer. Download \(engine.other.shortName) before deleting \(engine.shortName)."
        }
        // S3: the recognizer in use can't be deleted.
        if selected == engine {
            return "\(engine.shortName) is the recognizer in use. Choose \(engine.other.shortName) before deleting it."
        }
        if isSelectionDisabled { return disabledReason ?? "Recognizer status unavailable" }
        if residency(for: engine) == .loading { return "Wait for \(engine.shortName) to finish loading." }
        return nil
    }
    /// The selected row's one line about residency (S3): loading is automatic, and so is the idle unload.
    /// With the keep-warm switch reported, Parakeet's line follows it: off keeps it resident, on unloads when idle.
    /// A Sleeping row says "loads when you dictate" in its status, so this line does not repeat it.
    public func autoLoadLine(for engine: RecognizerPickerEngine) -> String? {
        guard selected == engine, assetsPresent(for: engine) else { return nil }
        if engine == .parakeet, let unloadWhenIdle {
            if unloadWhenIdle.effective {
                return idleUnloadSeconds.map { "Unloads after \(Self.idleText($0)) idle to free memory." }
                    ?? "Unloads when idle to free memory."
            }
            return residency(for: engine) == .loaded ? "Stays loaded between dictations." : nil
        }
        guard let idleUnloadSeconds else { return "Loads automatically when selected." }
        return "Loads automatically when selected; unloads after \(Self.idleText(idleUnloadSeconds)) idle."
    }

    /// Row 3 (lead 00:32Z): Sleeping on the SELECTED engine means unloaded (memory pressure, or the switch is on) and
    /// loading on the next dictation, so Sleeping → Ready after a dictation reads as normal. Another engine that is
    /// Sleeping does not load when you dictate, so it gets no hint.
    public static let sleepingHint = "loads when you dictate"
    public func showsSleepingHint(for engine: RecognizerPickerEngine) -> Bool {
        selected == engine && residency(for: engine) == .unloaded && assetsPresent(for: engine)
            && !(engine == .parakeet && parakeetAvailable == false)
    }
    static func idleText(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole >= 3600, whole % 3600 == 0 { return "\(whole / 3600) h" }
        if whole >= 60, whole % 60 == 0 { return "\(whole / 60) min" }
        return "\(whole) s"
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
        if residency(for: engine) == .unloaded { return showsSleepingHint(for: engine) ? "Sleeping (\(Self.sleepingHint))" : "Sleeping" }
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
    private var deliveredWarning: String? {
        RecognizerProvenance(backend: lastTranscriptionBackend)?.notice(about: Self.pickerSubject)
    }
    public var explanation: String? {
        if let warning = deliveredWarning { return warning }
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
        if let notice = provenanceNotice { return notice }
        if let disabledReason { return disabledReason }
        if parakeet == .loading || whisper == .loading { return "Switching recognizer…" }
        if selected == .parakeet, parakeet == .error { return "Parakeet is unavailable; choose Whisper or try again later." }
        if selected == .whisper, whisper == .error { return "Whisper is unavailable; try again later." }
        return isSelectionDisabled ? "Recognizer status unavailable" : nil
    }
    /// Row 1: what really happened, naming the engine that wrote the text. The selected engine was asked first; the
    /// effective one took over. The daemon publishes `effective` + `fallback_reason` BEFORE the fallback engine runs
    /// (parakeet-backend.ts) and leaves them in place when it fails (stt.ts marks only the phase), so these fields alone
    /// never prove a transcript was delivered. Only a ready or sleeping fallback engine has delivered one
    /// (K-ui review round 2). Loading describes the current operation; error says it didn't finish.
    var provenanceNotice: String? {
        guard let fallbackReason, let effective else { return nil }
        let first = RecognizerProvenance.Engine(selected ?? effective.other)
        let provenance = RecognizerProvenance(firstEngine: first, writer: RecognizerProvenance.Engine(effective),
                                              fallbackReason: fallbackReason)
        guard first != provenance.writer else { return nil }
        switch residency(for: effective) {
        case .loaded, .unloaded: return provenance.notice(about: Self.pickerSubject)
        // The whole recording goes to the fallback engine, not only its ending.
        case .loading: return "Transcribing this recording with \(effective.shortName)…"
        case .error: return "\(effective.shortName) couldn't finish this recording."
        case .unknown: return nil
        }
    }
    static let pickerSubject = "your last recording"
    /// Orange only for a hand-off that happened or failed; work in progress reads as a normal status line.
    public var explanationIsWarning: Bool {
        if deliveredWarning != nil { return true }
        if let effective, fallbackReason != nil, residency(for: effective) == .loading,
           commandNotice == nil, explanation == provenanceNotice { return false }
        return fallbackReason != nil || parakeet == .error
    }

    public static func message(for reason: String?) -> String {
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
