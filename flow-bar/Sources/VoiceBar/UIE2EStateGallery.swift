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
            virtualNotchIdleCoreHeight: geometry.virtualNotchIdleCoreHeight,
            transientNoteWidth: base.transientNoteWidth)
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

    func show() {
        guard let screen = NSScreen.main else { return }
        controls = NSWindow(contentRect: CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 10,
            width: min(1000, screen.visibleFrame.width - 40), height: 96),
            styleMask: [.titled], backing: .buffered, defer: false)
        controls?.title = "VoiceBar QA Settings"
        prepare(controls: controls!, metrics: .init(frame: screen.frame, visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top, auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea))
        controls?.makeKeyAndOrderFront(nil)
        pinTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self else { return }
                self.refreshPinnedStates()
            }
        }
        observe(reason: "launch")
    }

    /// Also permits isolated offscreen hosting without starting the QA app or its pin loop.
    func prepare(controls: NSWindow, metrics: VoiceBarNotchScreenMetrics) {
        self.controls = controls
        screenMetrics = metrics
        screenGeometry = .resolve(metrics: metrics)
        rebuildVisiblePanels()
    }

    func hide() {
        pinTask?.cancel(); pinTask = nil
        panels.forEach { $0.orderOut(nil) }
        familyPanel?.orderOut(nil)
        controls?.orderOut(nil)
    }

    static func captureArea(for metrics: VoiceBarNotchScreenMetrics) -> CGRect {
        let area = metrics.visibleFrame.insetBy(dx: 20, dy: 20)
        let top = min(area.maxY, metrics.frame.maxY - 150)
        let bottom = area.minY + 120
        precondition(top > bottom, "QA display too small for gallery capture area; use a larger display")
        return CGRect(x: area.minX, y: bottom, width: area.width, height: top - bottom)
    }

    private func bar(for item: Item, geometry: VoiceBarNotchScreenGeometry? = nil) -> PillHostingView<AnyView> {
        let presentationModel: VoiceBarNotchPresentationModel? = geometry.map {
            let model = VoiceBarNotchPresentationModel()
            Self.update(model, state: item.renderedVoice, base: UIE2EHost.panelLayout(for: item.renderedVoice).presentation, geometry: $0)
            return model
        }
        let view = PillHostingView(rootView: AnyView(BarView(state: item.renderedVoice,
            commandRouter: VoiceBarCommandRouter(voiceState: item.renderedVoice), onOpenSettings: {}, onOpenHistory: {},
            presentationModel: presentationModel, includesPanelOutsets: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("qa-gallery-bar-\(item.spec.id)")))
        let layout = geometry.map { Self.layout(for: item.renderedVoice, screenGeometry: $0) } ?? UIE2EHost.panelLayout(for: item.renderedVoice)
        view.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        view.renderedSurfaceHitTestProvider = { layout.containsVisibleSurface($0) }
        view.hoverExpansionHitTestProvider = { layout.containsHoverExpansion($0) }
        view.hoverRetentionHitTestProvider = { layout.containsHoverRetention($0) }
        view.frame = CGRect(origin: .zero, size: layout.panelSize)
        return view
    }

    private func rebuildVisiblePanels() {
        guard let screenMetrics, controls != nil else { return }
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        for item in items {
            let bar = bar(for: item)
            let content = NSView(frame: bar.frame)
            var cardHeight: CGFloat = 0
            if item.spec.hasCard {
                let card = NSHostingView(rootView: DictationCard(
                    entry: .init(text: item.voice.latestReusableTranscript, createdAt: Date(timeIntervalSince1970: 1_790_000_000)),
                    insertionStatus: item.voice.latestDictationInsertionStatus,
                    onCopy: { self.copyFromCard(item, text: $0) })
                    .padding(10).frame(width: bar.frame.width)
                    .accessibilityIdentifier(item.spec.id == "paste-not-inserted" ? "qa-gallery-copy" : "qa-gallery-card-\(item.spec.id)"))
                cardHeight = card.fittingSize.height
                card.frame = CGRect(x: 0, y: bar.frame.height, width: bar.frame.width, height: cardHeight)
                content.addSubview(card)
            }
            content.addSubview(bar)
            content.setFrameSize(CGSize(width: bar.frame.width, height: bar.frame.height + cardHeight))
            let panel = NSPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // XCTest otherwise sees these ordinary fixture surfaces as modal AX dialogs and
            // raises interruption alerts while the real notch family panel remains visible.
            panel.setAccessibilityRole(.window)
            panel.setAccessibilitySubrole(.standardWindow)
            panel.title = "VoiceBar QA Gallery \(item.spec.id)"
            panel.contentView = content; panel.isReleasedWhenClosed = false
            panel.level = .floating
            panels.append(panel)
            if item.renderedVoice.onPanelLayoutChange == nil {
                item.renderedVoice.onPanelLayoutChange = { [weak self] in
                    // Bind once per model, including its later production expiry callback.
                    // Defer because a layout notification may arrive mid-transition.
                    DispatchQueue.main.async { [weak self] in self?.rebuildVisiblePanels() }
                }
            }
        }
        let captureArea = Self.captureArea(for: screenMetrics)
        let measured = panels.map { $0.frame.size }
        if pages.isEmpty {
            measuredSlots = measured
            pages = Self.pack(sizes: measuredSlots, in: captureArea)
        } else {
            // The first production measurements define both page membership and controls.
            // Expiry may shrink surfaces, but must never repack or recreate their controls.
            precondition(zip(measuredSlots, measured).allSatisfy {
                $1.width <= $0.width && $1.height <= $0.height
            }, "QA view exceeds its reserved gallery slot; use a larger display")
        }
        page = min(page, pages.count - 1)
        if familyID == nil {
            for placement in pages[page] {
                let panel = panels[placement.index]
                Self.place(panel, in: placement.frame); panel.orderFront(nil)
            }
        }
        updateFamilyPanel()
        installControlsIfNeeded()
    }

    private func installControlsIfNeeded() {
        guard controlsHost == nil else { return }
        let pageIndices = Array(pages.indices)
        let host = NSHostingView(rootView: AnyView(VStack {
            HStack {
                ForEach(pageIndices, id: \.self) { [weak self] index in
                    Button("Page \(index + 1)") { [weak self] in self?.selectPage(index) }.accessibilityIdentifier("qa-gallery-page-\(index)")
                }
                Button("Start all clocks") { [weak self] in self?.startClocks() }.accessibilityIdentifier("qa-gallery-start-clocks")
                Button("End sessions") { [weak self] in self?.endSessions() }.accessibilityIdentifier("qa-gallery-end-sessions")
                Button("Observe") { [weak self] in self?.observe(reason: "read-current") }.accessibilityIdentifier("qa-gallery-observe")
            }
            HStack {
                ForEach(["paste-feedback", "terminal", "busy", "selection-error"], id: \.self) { [weak self] family in
                    Button(family) { [weak self] in self?.selectFamily(family) }.accessibilityIdentifier("qa-gallery-family-\(family)")
                }
            }
        }.padding(8)))
        controlsHost = host
        controls?.contentView = host
    }
    private static func place(_ panel: NSPanel, in slot: CGRect) {
        panel.setFrameOrigin(CGPoint(x: slot.minX, y: slot.maxY - panel.frame.height))
    }
    func selectPage(_ index: Int) {
        page = index; familyID = nil; familyPanel?.orderOut(nil)
        panels.forEach { $0.orderOut(nil) }
        for placement in pages.indices.contains(page) ? pages[page] : [] {
            Self.place(panels[placement.index], in: placement.frame)
            panels[placement.index].orderFront(nil)
        }
        observe(reason: "page")
    }
    func selectFamily(_ family: String) {
        familyID = items.first { $0.spec.family == family }?.spec.id
        panels.forEach { $0.orderOut(nil) }
        updateFamilyPanel(); observe(reason: "family")
    }
    private func updateFamilyPanel() {
        familyPanel?.orderOut(nil)
        guard let familyID, let geometry = screenGeometry else { return }
        let item = item(familyID)
        let layout = Self.layout(for: item.renderedVoice, screenGeometry: geometry)
        let panel = FloatingPillPanel(content: bar(for: item, geometry: geometry))
        panel.title = "VoiceBar QA Pill"
        panel.setFrame(layout.windowFrame(anchoredTo: geometry), display: true)
        panel.orderFront(nil); familyPanel = panel
    }

    /// This is the real DictationCard action. Only an explicit native button click writes
    /// the clipboard; automatic delivery and offscreen tests retain the synthetic sinks.
    private func copyFromCard(_ item: Item, text: String) -> Bool {
        let writer = item.voice.pasteboardWriter, reader = item.voice.pasteboardStringProvider
        defer { item.voice.pasteboardWriter = writer; item.voice.pasteboardStringProvider = reader }
        item.voice.pasteboardWriter = { text in
            item.effects.clipboardWrites += 1
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        item.voice.pasteboardStringProvider = { NSPasteboard.general.string(forType: .string) }
        let result = item.voice.copyTranscript(text)
        observe(reason: "copy")
        return result
    }

    /// AppKit global coordinates -> primary-display-top-left accessibility coordinates.
    static func axFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    func observe(reason: String) {
        observationGeneration += 1
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let observations: [[String: Any]] = items.enumerated().map { index, item in
            ["id": item.spec.id, "family": item.spec.family, "expectedText": item.spec.expectedText,
             "mode": item.renderedVoice.mode.rawValue, "note": item.actualNote as Any? ?? NSNull(),
             "confirmation": item.renderedVoice.confirmationText as Any? ?? NSNull(),
             "showsBusy": item.renderedVoice.showsSelectionBusyNote, "captureLive": item.voice.captureLive,
             "expirySeconds": item.spec.expiry, "clockGeneration": item.clockGeneration,
             "clockOrigin": item.clockOrigin?.timeIntervalSince1970 as Any? ?? NSNull(),
             "renderer": "production BarView", "fontSize": 12, "fontWeight": "medium",
             "fontSource": "a3dbd792 BarView.compactStatusLabel; recheck after product font changes",
             "cardFont": item.spec.hasCard ? "default body (not 12 medium)" : "none",
             "frame": panels.indices.contains(index) ? NSStringFromRect(panels[index].frame) : "not-mounted",
             "axFrame": panels.indices.contains(index) ? NSStringFromRect(Self.axFrame(panels[index].frame, primaryTop: primaryTop)) : "not-mounted",
             "commandCount": item.effects.commands.count, "selectionCaptures": item.effects.selectionCaptures,
             "typedCount": item.effects.typed.count, "clipboardWrites": item.effects.clipboardWrites,
             "pasteShortcuts": item.effects.pasteShortcuts,
             "effects": ["commands": item.effects.commands, "commandCount": item.effects.commands.count,
                "selectionCaptures": item.effects.selectionCaptures, "typedCount": item.effects.typed.count,
                "clipboardWrites": item.effects.clipboardWrites, "pasteShortcuts": item.effects.pasteShortcuts,
                "captureLive": item.voice.captureLive]]
        }
        let familyLayout = familyID.flatMap { id in screenGeometry.map { Self.layout(for: item(id).renderedVoice, screenGeometry: $0) } }
        sandbox.writeObject(["scenario": "focused-338", "page": page, "currentPage": page, "pageCount": pages.count,
            "states": observations, "reason": reason, "observationGeneration": observationGeneration,
            "sessionEndBefore": sessionEndBefore, "sessionEndBeforeModes": sessionEndModes,
            "sessionEndGeneration": sessionEndGeneration,
            "pages": pages.enumerated().map { ["index": $0.offset, "states": $0.element.map { items[$0.index].spec.id }] },
            "pinned": isPinned, "lifetime": isPinned ? "synthetic fixture hold" : "production timers",
            "clockGeneration": clockGeneration, "clockOrigin": clockOrigin?.timeIntervalSince1970 as Any? ?? NSNull(),
            "clockStartedAt": clockOrigin?.timeIntervalSince1970 as Any? ?? NSNull(),
            "observedAt": Date().timeIntervalSince1970, "familyState": familyID as Any? ?? NSNull(),
            "familyStateID": familyID as Any? ?? NSNull(),
            "activeFamily": familyID.map { item($0).spec.family } as Any? ?? NSNull(),
            "familyFrame": familyID == nil ? "not-mounted" : familyPanel.map { NSStringFromRect($0.frame) } ?? "not-mounted",
            "familyAXFrame": familyID == nil ? "not-mounted" : familyPanel.map { NSStringFromRect(Self.axFrame($0.frame, primaryTop: primaryTop)) } ?? "not-mounted",
            "familyExpectedFrame": familyLayout.flatMap { layout in screenGeometry.map { NSStringFromRect(layout.windowFrame(anchoredTo: $0)) } } as Any? ?? NSNull(),
            "hardwareCoreFrame": screenGeometry.map { NSStringFromRect($0.housingFrame) } as Any? ?? NSNull(),
            "visibleCoreOcclusionInset": screenGeometry.map { Double($0.visibleCoreOcclusionInset) } as Any? ?? NSNull(),
            "screenKind": screenGeometry.map { String(describing: $0.kind) } ?? "not-observed",
            "screenAXBounds": screenGeometry.map { NSStringFromRect(Self.axFrame($0.screenFrame, primaryTop: primaryTop)) } ?? "not-observed",
            "copyStateID": "paste-not-inserted", "copyControlLabel": "Copy last dictation", "copyExpectedText": Self.transcript,
            "noAudio": true, "dependencies": "synthetic transport/capture/typing/activation; no AppDelegate, sockets or hardware; clipboard only on explicit Copy",
            "visualTextProven": false,
            "copyControl": "DictationCard Copy last dictation; qa-gallery-copy scopes the representative card"], file: "gallery.json")
    }
}
#endif
