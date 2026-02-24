// FlowBarApp.swift — Entry point for Voice Bar.
//
// Wires together: VoiceState, SocketClient, FloatingPillPanel, BarView.
// No Dock icon (.accessory activation policy). Menu bar icon for status + quit.
// Tracks mouse across screens — pill follows the cursor.

import AppKit
import SwiftUI

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let voiceState = VoiceState()
    private var socketClient: SocketClient?
    private var panel: FloatingPillPanel?
    private var mouseMonitor: Any?
    private var moveObserver: Any?
    /// Track which screen the pill is on to avoid unnecessary repositioning.
    private var currentScreenIndex: Int = -1
    /// Saved horizontal offset (0.0–1.0) for pill positioning.
    private var horizontalOffset: CGFloat = Theme.horizontalOffset

    private static let horizontalOffsetKey = "voicebar.horizontalOffset"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon (LSUIElement equivalent)
        NSApp.setActivationPolicy(.accessory)

        // Socket client
        let client = SocketClient(
            socketPath: "/tmp/voicelayer.sock",
            state: voiceState
        )
        socketClient = client

        // Wire the send-command closure so BarView buttons -> socket
        voiceState.sendCommand = { [weak client] cmd in
            client?.send(command: cmd)
        }

        client.connect()

        // Floating pill
        let barView = BarView(state: voiceState)
        let hosting = NSHostingView(rootView: barView)
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: Theme.pillMaxWidth + Theme.panelPadding * 2,
            height: Theme.pillExpandedHeight + Theme.panelPadding * 2
        )

        // Load saved horizontal offset
        if let saved = UserDefaults.standard.object(forKey: Self.horizontalOffsetKey) as? Double {
            horizontalOffset = max(0.05, min(0.95, CGFloat(saved)))
        }

        let pill = FloatingPillPanel(content: hosting)
        pill.positionOnScreen(horizontalOffset: horizontalOffset)
        pill.orderFront(nil)
        panel = pill

        // Save position when user drags the pill
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: pill,
            queue: .main
        ) { [weak self] _ in
            self?.savePanelPosition()
        }

        // Track mouse across screens — move pill to whichever monitor the cursor is on
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketClient?.disconnect()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running as a menu-bar agent
    }

    // MARK: - Mouse tracking

    /// Reposition pill when mouse moves to a different screen.
    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        // Capture screens array once to avoid TOCTOU race if a display disconnects.
        let screens = NSScreen.screens
        guard let targetScreen = screens.firstIndex(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) else { return }

        // Only reposition when the screen actually changes
        if targetScreen != currentScreenIndex {
            currentScreenIndex = targetScreen
            panel?.positionOnScreen(
                screens[targetScreen],
                horizontalOffset: horizontalOffset
            )
        }
    }

    // MARK: - Drag persistence

    /// Save the pill's horizontal offset as a percentage of screen width.
    private func savePanelPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let offset = (panel.frame.midX - visible.origin.x) / visible.width
        let clamped = max(0.05, min(0.95, offset))
        horizontalOffset = CGFloat(clamped)
        UserDefaults.standard.set(Double(clamped), forKey: Self.horizontalOffsetKey)
    }
}

// MARK: - SwiftUI App entry point

@main
struct FlowBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar icon + dropdown
        MenuBarExtra("VoiceBar", systemImage: "waveform.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appDelegate.voiceState.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(appDelegate.voiceState.isConnected ? "Connected" : "Disconnected")
                        .font(.system(.caption, weight: .medium))
                }
                Divider()
                Button("Quit Voice Bar") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(8)
        }

        // Empty Settings scene satisfies the "at least one Scene" requirement
        Settings {
            EmptyView()
        }
    }
}
