import Foundation

/// Line-by-line transliteration of docs/control-availability/model/ControlAvailability.tla (Policy "Fixed").
/// It is independent of `VoiceControlAvailability`: it reads the model's raw record, never `ControlFacts`.
/// `ControlAvailabilityModelTableTests` proves it reproduces TLC's own table (model-table.json) bit for bit.
struct ModelState: Hashable {
    var connected = true, gate = "open", phase = "none", older = false, queued = false, capable = true
    var agentAsk = false, historyBusy = false, playback = "none", hidden = false, drawer = "settings"
    var tab = "TabGeneral", modal = false, transition = false, choice = "other", assets = true, resident = true
    var downloading = false, clone = "running", foreign = false, pending = false, previous = false, next = false
    var audio = true, micEligible = true, micRevision = 0, gesture = false, reported = "derived"

    /// Sorted `field=value` pairs, exactly as model-table.py writes them.
    var key: String {
        func b(_ v: Bool) -> String { v ? "TRUE" : "FALSE" }
        let fields: [(String, String)] = [
            ("connected", b(connected)), ("gate", gate), ("phase", phase), ("older", b(older)), ("queued", b(queued)),
            ("capable", b(capable)), ("agentAsk", b(agentAsk)), ("historyBusy", b(historyBusy)), ("playback", playback),
            ("hidden", b(hidden)), ("drawer", drawer), ("tab", tab), ("modal", b(modal)), ("transition", b(transition)),
            ("choice", choice), ("assets", b(assets)), ("resident", b(resident)), ("downloading", b(downloading)),
            ("clone", clone), ("foreign", b(foreign)), ("pending", b(pending)), ("previous", b(previous)),
            ("next", b(next)), ("audio", b(audio)), ("micEligible", b(micEligible)), ("micRevision", "\(micRevision)"),
            ("gesture", b(gesture)), ("reported", reported),
        ]
        return fields.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
            .map { "\($0.0)=\($0.1)" }.joined(separator: ",")
    }
}

enum ModelOracle {
    static let phases = ["none", "opening", "open", "paused", "draining", "transcribing"]
    static let playbacks = ["none", "playing", "paused", "previous", "readback", "preparing"]
    static let tabs = ["TabGeneral", "TabTranscription", "TabDictionary", "TabSpeech", "TabHistory"]
    static let archives = ["ArchiveDrawer", "ArchiveWindow", "ArchiveLatest"]
    static let microphones = ["MicDefault", "MicReorder", "MicMove", "MicVisibleFirst"]
    static let recognizerMutations = ["SelectRecognizer", "LoadRecognizer", "UnloadRecognizer"]
    static let clones = ["CloneStart", "CloneRestart", "CloneStop"]
    static let mediaButtons = ["ReadClipboard", "PreviewShort", "PreviewLong", "HistoryPlay"]
    static let transports = ["PausePlayback", "ResumePlayback", "Previous", "NextRead", "Replay", "Seek"]
    static let emergency = ["Stop", "Cancel", "F5Release"]
    static let presentation = tabs + ["Hide", "Show", "OpenHistory", "OpenSettings", "CloseDrawer"]
    static let tabSet = Set(tabs), archiveSet = Set(archives), microphoneSet = Set(microphones)
    static let recognizerSet = Set(recognizerMutations), cloneSet = Set(clones), mediaSet = Set(mediaButtons)
    static let transportSet = Set(transports), emergencySet = Set(emergency), presentationSet = Set(presentation)
    static let recognizerFamily = recognizerSet.union(["DownloadRecognizer", "ConfirmDelete"])
    static let controls = archives + microphones + recognizerMutations + clones + mediaButtons + transports + emergency
        + presentation + ["RestartListener", "Update", "CheckUpdates", "ReadSelectionKey", "RecordF5", "HistoryCopy",
                          "HistoryNavigate", "CancelDownload", "DownloadRecognizer", "RequestDelete", "ConfirmDelete", "Quit"]

    static func capturing(_ x: ModelState) -> Bool { ["opening", "open", "paused"].contains(x.phase) }
    static func unfinished(_ x: ModelState) -> Bool { x.phase != "none" || x.older || x.queued || x.historyBusy }
    static func speech(_ x: ModelState) -> Bool { ["playing", "paused", "previous", "preparing"].contains(x.playback) }
    static func mode(_ x: ModelState) -> String {
        if x.reported != "derived" { return x.reported }
        if !x.connected { return "disconnected" }
        if capturing(x) { return "recording" }
        if unfinished(x) { return "transcribing" }
        return speech(x) ? "speaking" : "idle"
    }
    static func drawerAllowed(_ x: ModelState) -> Bool { !x.hidden && !x.modal && !x.agentAsk && !speech(x) }

    static func visible(_ c: String, _ x: ModelState) -> Bool {
        if c == "ArchiveDrawer" { return x.audio && x.drawer == "history" && drawerAllowed(x) }
        if ["ArchiveWindow", "ArchiveLatest", "HistoryPlay"].contains(c) { return x.audio && !x.modal }
        if emergencySet.contains(c) { return unfinished(x) }
        if c == "Hide" { return !x.hidden && !x.modal }
        if c == "Show" { return x.hidden }
        if tabSet.contains(c) { return x.drawer == "settings" && drawerAllowed(x) }
        if c == "CloseDrawer" { return x.drawer != "none" && !x.hidden }
        if ["OpenHistory", "OpenSettings"].contains(c) { return drawerAllowed(x) }
        if c == "CloneStart" { return x.clone == "stopped" && !x.modal }
        if ["CloneRestart", "CloneStop"].contains(c) { return x.clone == "running" && !x.modal }
        if c == "CancelDownload" { return x.downloading && !x.modal }
        if c == "DownloadRecognizer" { return !x.assets && !x.modal }
        if c == "LoadRecognizer" { return x.assets && !x.resident && !x.modal }
        if c == "UnloadRecognizer" { return x.assets && x.resident && !x.modal }
        if ["RequestDelete", "ConfirmDelete"].contains(c) { return x.assets && !x.modal }
        if transportSet.contains(c) { return x.playback != "none" && !x.hidden && !x.modal }
        if ["RecordF5", "ReadSelectionKey"].contains(c) { return true }
        return !x.modal
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func uiReason(_ c: String, _ x: ModelState) -> String {
        if emergencySet.contains(c) { return unfinished(x) ? "" : "No unfinished take" }
        if c == "ReadSelectionKey" { return "" }
        if ["CheckUpdates", "HistoryCopy", "HistoryNavigate", "RequestDelete"].contains(c) { return "" }
        if presentationSet.contains(c) {
            if c == "Hide" && unfinished(x) { return "Finish or cancel this take before hiding VoiceBar" }
            if tabSet.contains(c) && x.drawer != "settings" { return "Open Settings first" }
            return ""
        }
        if microphoneSet.contains(c) {
            if capturing(x) { return "Finish recording to change microphones" }
            return x.micEligible ? "" : "No microphone move is available"
        }
        if c == "RestartListener" {
            return capturing(x) || x.gesture ? "Finish recording or release F5 before restarting the listener" : ""
        }
        if c == "Update" {
            if x.pending { return "An update operation is in progress" }
            if unfinished(x) || mode(x) != "idle" || x.gesture { return "Finish the active operation before updating" }
            return x.gate == "closed" ? "An update owns VoiceBar" : ""
        }
        if c == "Quit" { return x.gate == "closed" ? "An update owns VoiceBar" : "" }
        if c == "RecordF5" {
            if !x.connected { return "VoiceLayer is disconnected" }
            if x.hidden { return "Show VoiceBar before recording" }
            if x.gate == "closed" { return "An update owns VoiceBar" }
            if x.agentAsk { return "An agent Ask owns the microphone" }
            if x.queued { return "The next recording is already queued" }
            if capturing(x) { return "A recording owns the microphone" }
            return unfinished(x) && !x.capable ? "This connection cannot queue another recording" : ""
        }
        if c == "CancelDownload" { return x.downloading ? "" : "No download is active" }
        if cloneSet.contains(c) {
            if capturing(x) { return "Finish recording to change the clone engine" }
            if x.pending { return "Waiting for the clone engine" }
            if c != "CloneStart" && x.foreign { return "Another process owns this engine" }
            return speech(x) ? "Finish playback before changing the clone engine" : ""
        }
        if archiveSet.contains(c) {
            if !x.connected { return "VoiceLayer is disconnected" }
            if x.gate == "closed" { return "An update owns VoiceBar" }
            if unfinished(x) { return "Finish or cancel the current take and re-transcription first" }
            if speech(x) || x.agentAsk { return "Finish speech or Ask before re-transcribing" }
            return mode(x) != "idle" ? "Recover VoiceBar before re-transcribing" : ""
        }
        if recognizerFamily.contains(c) {
            if !x.connected { return "VoiceLayer is disconnected" }
            if x.gate == "closed" { return "An update owns VoiceBar" }
            if unfinished(x) { return "Finish the current take before changing recognizers" }
            if x.transition { return "Wait for the recognizer transition" }
            if c == "SelectRecognizer" && x.choice == "same" { return "Already selected and healthy" }
            if c == "SelectRecognizer" && !x.assets { return "Download this recognizer first" }
            if c == "ConfirmDelete" && (x.choice != "other" || x.resident) {
                return "Choose another recognizer and unload this model first"
            }
            return ""
        }
        if mediaSet.contains(c) {
            if !x.connected && c != "HistoryPlay" { return "VoiceLayer is disconnected" }
            if x.gate == "closed" { return "An update owns VoiceBar" }
            if unfinished(x) || x.agentAsk { return "Finish capture or transcription before reading" }
            return c != "ReadClipboard" && speech(x) ? "Finish the current playback first" : ""
        }
        if transportSet.contains(c) {
            if c != "PausePlayback" && unfinished(x) { return "Finish capture or transcription before playback" }
            if !x.connected { return "VoiceLayer is disconnected" }
            if c != "PausePlayback" && x.gate == "closed" { return "An update owns VoiceBar" }
            if c == "Previous" && !x.previous { return "No previous read in this queue" }
            if c == "NextRead" && !x.next { return "Nothing queued" }
            if c == "ResumePlayback" && x.playback != "paused" { return "Playback is not paused" }
            if c == "PausePlayback" && !["playing", "previous", "preparing", "paused"].contains(x.playback) {
                return "No live playback to pause"
            }
            return c == "Seek" && x.playback == "preparing" ? "Preparing audio; seeking is not ready" : ""
        }
        return "Unknown control"
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func localGuard(_ c: String, _ x: ModelState) -> Bool {
        if emergencySet.contains(c) { return unfinished(x) }
        if c == "Hide" { return !unfinished(x) }
        if microphoneSet.contains(c) { return x.micEligible && !capturing(x) }
        if c == "RestartListener" { return !capturing(x) && !x.gesture }
        if c == "Update" { return mode(x) == "idle" && !x.gesture && !x.pending && !unfinished(x) }
        if archiveSet.contains(c) { return c != "ArchiveDrawer" || mode(x) == "idle" }
        if c == "RecordF5" {
            return !x.hidden && !x.agentAsk && !capturing(x) && !x.queued && (x.capable || !unfinished(x))
        }
        if c == "ReadSelectionKey" { return true }
        if tabSet.contains(c) { return x.drawer == "settings" && drawerAllowed(x) }
        if ["OpenHistory", "OpenSettings"].contains(c) { return drawerAllowed(x) }
        if c == "CloseDrawer" { return x.drawer != "none" }
        if c == "Show" { return x.hidden }
        if recognizerSet.contains(c) {
            return !unfinished(x) && !x.transition && x.assets && (c != "SelectRecognizer" || x.choice != "same")
        }
        if c == "DownloadRecognizer" { return !unfinished(x) && !x.transition && !x.assets }
        if c == "CancelDownload" { return x.downloading }
        if c == "ConfirmDelete" { return !unfinished(x) && !x.transition && x.choice == "other" && !x.resident }
        if cloneSet.contains(c) {
            return !x.pending && !capturing(x) && !speech(x)
                && (c == "CloneStart" ? x.clone == "stopped" : x.clone == "running" && !x.foreign)
        }
        if mediaSet.contains(c) { return !unfinished(x) && !x.agentAsk && (c == "ReadClipboard" || !speech(x)) }
        if transportSet.contains(c) {
            return (c == "PausePlayback" || !unfinished(x)) && (c != "Previous" || x.previous)
                && (c != "NextRead" || x.next) && (c != "ResumePlayback" || x.playback == "paused")
                && (c != "PausePlayback" || speech(x)) && (c != "Seek" || x.playback != "preparing")
        }
        return true
    }

    static func daemonGuard(_ c: String, _ x: ModelState) -> Bool {
        if archiveSet.contains(c) {
            return x.connected && x.gate == "open" && !unfinished(x) && !speech(x) && !x.agentAsk && mode(x) == "idle"
        }
        if (recognizerMutations + ["DownloadRecognizer", "ConfirmDelete", "RecordF5"]).contains(c) {
            return x.connected && x.gate == "open"
        }
        if mediaSet.contains(c) { return x.gate == "open" && (c == "HistoryPlay" || x.connected) }
        if transportSet.contains(c) { return x.connected && (c == "PausePlayback" || x.gate == "open") }
        if ["Update", "Quit"].contains(c) { return x.gate == "open" }
        return true
    }

    static func handler(_ c: String, _ x: ModelState) -> Bool { visible(c, x) && localGuard(c, x) && daemonGuard(c, x) }
    static func enabled(_ c: String, _ x: ModelState) -> Bool { visible(c, x) && uiReason(c, x).isEmpty }
    static func selectionCanRead(_ x: ModelState) -> Bool {
        x.connected && x.gate == "open" && !unfinished(x) && !x.agentAsk
    }
    static func selectionReason(_ x: ModelState) -> String {
        if !x.connected { return "VoiceLayer is disconnected" }
        if x.gate == "closed" { return "An update owns VoiceBar" }
        return "Finish capture or transcription before reading"
    }

    /// The model's `Seeds`: the union of its five factor products (exhaustive per factor, not the full product).
    static var seeds: Set<ModelState> {
        let bools = [false, true], gates = ["open", "closed"]
        var out = Set<ModelState>()
        func add(_ edit: (inout ModelState) -> Void) { var x = ModelState(); edit(&x); out.insert(x) }
        for cn in bools { for g in gates { for p in phases { for o in bools { for a in bools { for b in playbacks {
            add { $0.connected = cn; $0.gate = g; $0.phase = p; $0.older = o; $0.agentAsk = a; $0.playback = b }
        } } } } } }
        for p in phases { for o in bools { for a in bools { for h in bools { for m in bools {
            for d in ["none", "history", "settings"] { for b in ["none", "paused", "playing"] {
                add { $0.phase = p; $0.older = o; $0.agentAsk = a; $0.hidden = h; $0.modal = m; $0.drawer = d; $0.playback = b }
            } }
        } } } } }
        for p in phases { for o in bools { for t in bools { for c in ["same", "other", "retry"] { for a in bools {
            for r in bools { for cn in bools { for g in gates {
                add { $0.phase = p; $0.older = o; $0.transition = t; $0.choice = c; $0.assets = a; $0.resident = r
                    $0.connected = cn; $0.gate = g }
            } } }
        } } } } }
        for p in phases { for b in playbacks { for l in ["stopped", "running", "transition"] { for f in bools { for n in bools {
            add { $0.phase = p; $0.playback = b; $0.clone = l; $0.foreign = f; $0.pending = n }
        } } } } }
        for cn in bools { for g in gates { for p in phases { for o in bools {
            add { $0.historyBusy = true; $0.connected = cn; $0.gate = g; $0.phase = p; $0.older = o }
        } } } }
        for p in phases { for q in bools { for c in bools { add { $0.phase = p; $0.queued = q; $0.capable = c; $0.older = true } } } }
        for p in phases { for e in bools { for d in bools { add { $0.phase = p; $0.micEligible = e; $0.downloading = d } } } }
        for b in playbacks { for p in bools { for n in bools { add { $0.playback = b; $0.previous = p; $0.next = n } } } }
        for r in ["derived", "error", "disconnected"] { for g in bools { for n in bools { for a in bools {
            add { $0.reported = r; $0.gesture = g; $0.pending = n; $0.audio = a }
        } } } }
        return out
    }

    /// The canonical table model-table.py hashes: every line sorted bytewise. Seed keys share one fixed field
    /// layout and control names are distinct, so ordering keys, then "name|" per key, is that same order.
    static func canonicalTable() -> String {
        let names = (controls + ["#Selection"]).sorted { ($0 + "|").utf8.lexicographicallyPrecedes(($1 + "|").utf8) }
        let keyed = seeds.map { ($0.key, $0) }.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        var out = ""
        out.reserveCapacity(keyed.count * names.count * 480)
        for (key, x) in keyed {
            for c in names {
                if c == "#Selection" {
                    out += "\(key)|#Selection|\(selectionCanRead(x) ? 1 : 0)|-|\(selectionReason(x))\n"
                } else {
                    out += "\(key)|\(c)|\(visible(c, x) ? 1 : 0)|\(handler(c, x) ? 1 : 0)|\(uiReason(c, x))\n"
                }
            }
        }
        return out
    }
}
