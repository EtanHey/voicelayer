#if VOICEBAR_QA && VOICEBAR_UIE2E_FOCUSED_338
import AppKit
import SwiftUI
import VoiceBarUI

/// Synthetic inputs, production state transitions/renderers. Never constructs AppDelegate.
@MainActor
final class UIE2EStateGallery {
    static let transcript = "QA terminal transcript שלום 👋"
    struct Spec {
        let id: String
        let family: String
        let expectedText: String // Oracle only; never passed to a renderer.
        let expiry: TimeInterval
        var hasCard: Bool { family == "paste-feedback" || family == "terminal" }
    }
    static let specs: [Spec] = [
        .init(id: "paste-not-inserted", family: "paste-feedback", expectedText: "Not pasted\nIn History", expiry: 5),
        .init(id: "paste-unverified", family: "paste-feedback", expectedText: "Unverified\nIn History", expiry: 5),
        .init(id: "paste-partial", family: "paste-feedback", expectedText: "Part pasted\nHistory: full", expiry: 5),
        .init(id: "terminal-confirmation", family: "terminal", expectedText: transcript, expiry: 5),
        .init(id: "busy-recording", family: "busy", expectedText: "Busy recording. Selection not read", expiry: 2),
        .init(id: "busy-transcribing", family: "busy", expectedText: "Busy transcribing. Selection not read", expiry: 2),
        .init(id: "busy-f5-preview", family: "busy", expectedText: "Busy with F5. Selection not read", expiry: 2),
        .init(id: "selection-clipboard-changed", family: "selection-error", expectedText: "Clipboard\nReselect", expiry: 1.5),
        .init(id: "selection-copy-timeout", family: "selection-error", expectedText: "Timed out\nReselect", expiry: 1.5),
        .init(id: "selection-copy-empty", family: "selection-error", expectedText: "No text\nReselect", expiry: 1.5),
        .init(id: "selection-copy-failed", family: "selection-error", expectedText: "Can't copy\nCheck A11y", expiry: 1.5),
    ]
    final class Effects {
        var commands: [String] = []
        var typed: [String] = []
        var clipboardWrites = 0
        var pasteShortcuts = 0
        var selectionCaptures = 0
        var activations = 0
        var clipboard: String?
    }
    final class Item {
        let spec: Spec
        let voice: VoiceState
        let effects: Effects
        var heldPresentation: VoiceState?
        var renderedVoice: VoiceState { heldPresentation ?? voice }
        var clockOrigin: Date?
        var clockGeneration = 0
        init(spec: Spec, voice: VoiceState, effects: Effects) {
            self.spec = spec; self.voice = voice; self.effects = effects
        }
        var actualNote: String? {
            VoiceBarPresentation.selectionBusyNote(isRequested: renderedVoice.showsSelectionBusyNote,
                mode: renderedVoice.mode, hotkeyPhase: renderedVoice.hotkeyPhase)
        }
        var actualText: String? { actualNote ?? renderedVoice.confirmationText }
    }
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
        let identifier: String
        init(_ identifier: String) { self.identifier = identifier; super.init() }
        override var bundleIdentifier: String? { identifier }
        override var processIdentifier: pid_t { 51515 }
    }
    struct Placement { let index: Int; let frame: CGRect }
    let sandbox: UIE2ESandbox
    private(set) var items: [Item] = []
    private(set) var isPinned = true
    private(set) var clockGeneration = 0
    private(set) var clockOrigin: Date?
    private(set) var sessionEndBefore: [String: String] = [:]
    private(set) var sessionEndGeneration = 0
    private var sessionEndModes: [String: String] = [:]
    private var pinTask: Task<Void, Never>?
    private(set) var panels: [NSPanel] = []
    private(set) var familyPanel: FloatingPillPanel?
    private var familyID: String?
    private var pages: [[Placement]] = []
    private var measuredSlots: [CGSize] = []
    private var page = 0
    private var observationGeneration = 0
    private var controls: NSWindow?
    private var controlsHost: NSHostingView<AnyView>?
    private var screenGeometry: VoiceBarNotchScreenGeometry?
    private var screenMetrics: VoiceBarNotchScreenMetrics?

    init(sandbox: UIE2ESandbox) {
        self.sandbox = sandbox
        items = Self.specs.map(Self.makeItem)
        items.forEach(Self.holdPresentation)
    }
    func item(_ id: String) -> Item { items.first { $0.spec.id == id }! }

    private static func emptyVoice() -> VoiceState {
        VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
    }

    /// Capture the real outcome once; this separate visual fixture has no confirmation or
    /// transcribing watchdog. Lifetime models retain every unchanged production timer.
    /// expectedText is an independent oracle and is never an input here.
    private static func holdPresentation(_ item: Item) {
        let held = emptyVoice(), effects = item.effects
        held.controlLayerEventWriter = { _, _ in }
        held.frontmostAppProvider = { nil }
        held.sendCommand = { effects.commands.append($0["cmd"] as? String ?? "unknown") }
        held.pasteHandler = { _ in false }
        held.pasteboardWriter = { effects.clipboardWrites += 1; effects.clipboard = $0 }
        held.pasteboardStringProvider = { effects.clipboard }
        held.setConnectionStatus(true)
        held.mode = item.voice.mode
        held.hotkeyPhase = item.voice.hotkeyPhase
        if item.spec.family == "busy" { held.speakSelection() }
        held.confirmationText = item.voice.confirmationText
        held.keepsPasteFlowEnvelope = item.voice.keepsPasteFlowEnvelope
        held.beginModalInteraction()
        item.heldPresentation = held
    }

    private static func makeItem(_ spec: Spec) -> Item {
        let voice = emptyVoice()
        let effects = Effects()
        let app = FakeApp(spec.family == "terminal" ? "com.apple.Terminal" : "com.example.QAFixture")
        voice.controlLayerEventWriter = { _, _ in }
        voice.sendCommand = { effects.commands.append($0["cmd"] as? String ?? "unknown") }
        voice.frontmostAppProvider = { app }
        voice.targetAppActivator = { _ in effects.activations += 1 }
        voice.pasteScheduler = { _, work in work() }
        voice.textTypingHandler = { effects.typed.append($0); return true }
        voice.guardedTextTypingHandler = { text, _ in effects.typed.append(text); return .posted }
        voice.simulatedPasteHandler = { effects.pasteShortcuts += 1; return false }
        voice.pasteboardWriter = { effects.clipboardWrites += 1; effects.clipboard = $0 }
        voice.pasteboardStringProvider = { effects.clipboard }
        voice.pasteboardSnapshotter = { nil }
        voice.pasteboardSnapshotRestorer = { _ in }
        voice.pasteboardChangeCountProvider = { 0 }
        voice.accessibilityTrustChecker = { _ in false }
        voice.minimumTranscribingDisplayDuration = 0
        voice.pasteConfirmationDelay = 0
        voice.selectionTextCaptureHandler = { done in
            effects.selectionCaptures += 1
            switch spec.id {
            case "selection-clipboard-changed": done(.clipboardChanged)
            case "selection-copy-timeout": done(.copyTimedOut)
            case "selection-copy-empty": done(.copyEmpty)
            case "selection-copy-failed": done(.copyFailed)
            default: done(.completed(nil))
            }
        }
        voice.setConnectionStatus(true)
        if spec.hasCard {
            let result: DictationInsertionResult = switch spec.id {
            case "paste-not-inserted": .notApplied
            case "paste-partial": .partiallyApplied
            default: .appliedUnverified
            }
            voice.asyncDictationInsertionHandlerProvider = { { _, completion in completion(result); return true } }
            voice.record()
            voice.handleEvent(["type": "transcription", "text": transcript])
        } else {
            switch spec.id {
            case "busy-recording": voice.handleEvent(["type": "state", "state": "recording"])
            case "busy-transcribing": voice.handleEvent(["type": "state", "state": "transcribing"])
            case "busy-f5-preview": voice.hotkeyPhase = .pressing
            default: break
            }
            voice.speakSelection()
        }
        voice.beginModalInteraction() // Synthetic presentation hold; does not replace product expiry.
        return Item(spec: spec, voice: voice, effects: effects)
    }

    /// Re-admit the static busy presentation; its lifetime model and watchdog are untouched.
    func refreshPinnedStates() {
        guard isPinned else { return }
        for item in items where item.spec.family == "busy" { item.renderedVoice.speakSelection() }
    }
    func startClocks() {
        pinTask?.cancel(); pinTask = nil; isPinned = false
        clockGeneration += 1
        let origin = Date(); clockOrigin = origin
        // One uninterrupted MainActor batch; each product timer is scheduled here, not per page.
        items = Self.specs.map { spec in
            let next = Self.makeItem(spec)
            next.voice.endModalInteraction()
            next.clockOrigin = origin; next.clockGeneration = clockGeneration
            return next
        }
        rebuildVisiblePanels(); observe(reason: "start-clocks")
    }
    func endSessions() {
        pinTask?.cancel(); pinTask = nil; isPinned = false
        sessionEndGeneration += 1; sessionEndBefore = [:]; sessionEndModes = [:]
        // Atomic admission -> before readback -> session end. Works even after the expiry phase.
        for index in items.indices where items[index].spec.family == "busy" {
            items[index].heldPresentation = nil
            if VoiceBarPresentation.selectionBusyReason(mode: items[index].voice.mode,
                    hotkeyPhase: items[index].voice.hotkeyPhase) == nil {
                let old = items[index], fresh = Self.makeItem(old.spec)
                fresh.clockOrigin = old.clockOrigin; fresh.clockGeneration = old.clockGeneration
                items[index] = fresh
            }
            let item = items[index]
            item.voice.speakSelection()
            sessionEndBefore[item.spec.id] = item.actualNote
            sessionEndModes[item.spec.id] = item.voice.mode.rawValue
            item.voice.handleEvent(["type": "state", "state": "idle", "source": "recording"])
            item.voice.hotkeyPhase = .idle
        }
        rebuildVisiblePanels(); observe(reason: "end-sessions")
    }

    static func layout(for state: VoiceState, screenGeometry: VoiceBarNotchScreenGeometry) -> VoiceBarPanelLayout {
        let base = UIE2EHost.panelLayout(for: state).presentation
        let model = VoiceBarNotchPresentationModel()
        update(model, state: state, base: base, geometry: screenGeometry)
        let presentation = model.presentation
        return VoiceBarPanelLayout.make(presentation: presentation,
            interactionConfiguration: AppDelegate.notchInteractionConfiguration(for: state, visualState: presentation.visualState),
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry)
    }
    private static func update(_ model: VoiceBarNotchPresentationModel, state: VoiceState,
                               base: VoiceBarNotchPresentation, geometry: VoiceBarNotchScreenGeometry) {
        model.updateOperationalEnvelope(hasTeleprompter: base.visualState == .teleprompter,
            isRecording: base.visualState == .recording, hasCompactStatus: base.visualState == .compactStatus,
            compactStatusLeadingWingWidth: base.geometry.leadingWingWidth,
            compactStatusTrailingWingWidth: base.geometry.trailingWingWidth,
            recordingLeadingWingWidth: base.geometry.leadingWingWidth,
            recordingTrailingWingWidth: base.geometry.trailingWingWidth,
            keepsIdleExpanded: state.mode == .idle && !state.isCollapsed,
            coreWidth: geometry.housingFrame.width, visibleCoreOcclusionInset: geometry.visibleCoreOcclusionInset,
            virtualNotchIdleCoreHeight: geometry.virtualNotchIdleCoreHeight)
        model.setHovered(state.isHovering)
    }

    /// Variable sizes are measured from the production views. At most six cells per page.
    static func pack(sizes: [CGSize], in area: CGRect) -> [[Placement]] {
        var pages: [[Placement]] = [[]], x = area.minX, top = area.maxY, rowHeight: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            precondition(size.width <= area.width && size.height <= area.height, "QA view exceeds capture area; use a larger display")
            if x + size.width > area.maxX { x = area.minX; top -= rowHeight + 16; rowHeight = 0 }
            if top - size.height < area.minY || pages[pages.count - 1].count == 6 {
                pages.append([]); x = area.minX; top = area.maxY; rowHeight = 0
            }
            pages[pages.count - 1].append(.init(index: index,
                frame: CGRect(x: x, y: top - size.height, width: size.width, height: size.height)))
            x += size.width + 16; rowHeight = max(rowHeight, size.height)
        }
        return pages
    }

    private func rebuildVisiblePanels() {}
    func selectPage(_ index: Int) { page = index; observe(reason: "page") }
    func observe(reason: String) {
        observationGeneration += 1
        sandbox.writeObject(["scenario": "focused-338", "reason": reason,
            "observationGeneration": observationGeneration, "clockGeneration": clockGeneration], file: "gallery.json")
    }
}
#endif
