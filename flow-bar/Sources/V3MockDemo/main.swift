// V3MockDemo — runnable functional-mock harness (R3 redo, Etan 16:25).
//
// Presents the FUNCTIONAL v3 island (V3IslandContainerView) top-flush on the
// built-in notched display: tap = idle⇄recording, drag down = transcript menu.
// No daemon/socket wiring — pure visual/interaction layer for screenshots and
// screen-recordings of the RUNNING app.
//
// Run: swift run V3MockDemo            (auto-quits after 10 min as a guard)
// Env: V3DEMO_SCREEN=flat to force the flat-display preview geometry.
//
// Window recipe per steal S11 (+ FB16484811: .nonactivatingPanel must be set
// in init(styleMask:)). KeyablePanel: canBecomeKey=true so the inline-fix
// TextField is editable despite the nonactivating style (Clicky pattern).

import AppKit
import SwiftUI
import VoiceBarUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

final class DemoDelegate: NSObject, NSApplicationDelegate {
    var backdrop: NSWindow?
    var panel: KeyablePanel?
    var screen: NSScreen?
    var demoState: V3IslandState = .idle
    var showOutline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pick the built-in notched screen; fall back to main.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        self.screen = screen
        let notchWidth = V3Theme.closedNotchWidth(for: screen)
        let stripHeight = resolvedStripHeight(for: screen)

        installBackdrop(on: screen)

        // Panel envelope: full width so V5.1 sheets can render edge-to-edge.
        let panelWidth = screen.frame.width
        let panelHeight = min(screen.frame.height, stripHeight + V3Theme.menuContentHeight + 180)
        let origin = NSPoint(
            x: screen.frame.minX,
            y: screen.frame.maxY - panelHeight
        )

        let panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // shadow lives in SwiftUI, active states only (S11)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle, .moveToActiveSpace]
        panel.isMovableByWindowBackground = false

        // Deterministic capture states:
        // V3DEMO_STATE=idle|hover|recording|transcribing|menu|terms
        let demoStateName = ProcessInfo.processInfo.environment["V3DEMO_STATE"] ?? "idle"
        let initialState: V3IslandState = switch demoStateName {
        case "hover":
            .hover
        case "recording":
            .recording
        case "transcribing":
            .transcribing
        case "menu":
            .menuOpen(.history)
        case "terms":
            .menuOpen(.terms)
        default:
            .idle
        }
        demoState = initialState
        // G1-v2 QA overlay: 1pt green hairline at the measured notch rect.
        // NEVER in product captures for Etan — self-check artifacts only.
        showOutline = ProcessInfo.processInfo.environment["VOICELAYER_QA_NOTCH_OUTLINE"] == "1"
        let hosting = NSHostingView(rootView: AnyView(rootView(
            screen: screen,
            notchWidth: notchWidth,
            stripHeight: stripHeight,
            panelWidth: panelWidth
        )))
        hosting.frame = panel.contentLayoutRect
        panel.contentView = hosting

        panel.orderFrontRegardless()
        self.panel = panel
        refreshPanelGeometry()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.refreshPanelGeometry()
        }

        // Demo guard: never leave a stray panel running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func resolvedStripHeight(for screen: NSScreen) -> CGFloat {
        V3IslandModel.resolvedStripHeight(
            actualScreenSafeAreaTop: screen.safeAreaInsets.top,
            visibleMenuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY
        )
    }

    private func rootView(
        screen: NSScreen,
        notchWidth: CGFloat,
        stripHeight: CGFloat,
        panelWidth: CGFloat
    ) -> some View {
        let island = V3IslandContainerView(
            notchWidth: notchWidth,
            stripHeight: stripHeight,
            viewportWidth: panelWidth,
            initialState: demoState
        )
        let outlineWidth = notchWidth

        return ZStack(alignment: .top) {
            island
            if showOutline {
                Rectangle()
                    .strokeBorder(Color.green, lineWidth: 1)
                    .frame(width: outlineWidth, height: stripHeight)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @MainActor
    private func refreshPanelGeometry() {
        guard let panel else { return }
        let actualScreen = panel.screen ?? screen ?? NSScreen.main!
        screen = actualScreen
        let notchWidth = V3Theme.closedNotchWidth(for: actualScreen)
        let stripHeight = resolvedStripHeight(for: actualScreen)
        let panelWidth = actualScreen.frame.width
        let panelHeight = min(actualScreen.frame.height, stripHeight + V3Theme.menuContentHeight + 180)
        panel.setFrame(
            NSRect(
                x: actualScreen.frame.minX,
                y: actualScreen.frame.maxY - panelHeight,
                width: panelWidth,
                height: panelHeight
            ),
            display: true
        )
        installBackdrop(on: actualScreen)
        if let hosting = panel.contentView as? NSHostingView<AnyView> {
            hosting.rootView = AnyView(rootView(
                screen: actualScreen,
                notchWidth: notchWidth,
                stripHeight: stripHeight,
                panelWidth: panelWidth
            ))
            hosting.frame = panel.contentLayoutRect
        }
        backdrop?.orderFrontRegardless()
        panel.orderFrontRegardless()
    }

    private func installBackdrop(on screen: NSScreen) {
        let mode = ProcessInfo.processInfo.environment["V3DEMO_BACKDROP"] ?? "dark"
        let state = ProcessInfo.processInfo.environment["V3DEMO_STATE"] ?? "idle"
        let isSheetState = state == "menu" || state == "terms"
        let requestedHeight = ProcessInfo.processInfo.environment["V3DEMO_BACKDROP_HEIGHT"]
            .flatMap(Double.init)
            .map { CGFloat($0) }
        let height: CGFloat = requestedHeight ?? (isSheetState ? 560 : 140)
        let rect = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        )
        let color = mode == "light"
            ? NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.97, alpha: 1)
            : NSColor(calibratedRed: 0.04, green: 0.045, blue: 0.055, alpha: 1)
        if let backdrop {
            backdrop.setFrame(rect, display: true)
            backdrop.backgroundColor = color
            backdrop.orderFrontRegardless()
            return
        }
        let backdrop = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backdrop.isOpaque = true
        backdrop.backgroundColor = color
        backdrop.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        backdrop.collectionBehavior = [.stationary, .ignoresCycle, .moveToActiveSpace]
        backdrop.ignoresMouseEvents = true
        backdrop.orderFrontRegardless()
        self.backdrop = backdrop
    }

    @MainActor
    @objc private func activeSpaceDidChange() {
        refreshPanelGeometry()
        backdrop?.orderFrontRegardless()
        panel?.orderFrontRegardless()
    }

    @MainActor
    @objc private func screenParametersDidChange() {
        refreshPanelGeometry()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // LSUIElement-style: no dock icon (A17)
let delegate = DemoDelegate()
app.delegate = delegate
app.run()
