/// FlowBarApp.swift — Entry point for Flow Bar.
///
/// Wires together: VoiceState, SocketClient, FloatingPillPanel, BarView.
/// No Dock icon (.accessory activation policy). Menu bar icon for status + quit.

import SwiftUI
import AppKit

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    let voiceState = VoiceState()
    private var socketClient: SocketClient?
    private var panel: FloatingPillPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {

        // No Dock icon (LSUIElement equivalent)
        NSApp.setActivationPolicy(.accessory)

        // Socket client
        let client = SocketClient(
            socketPath: "/tmp/voicelayer.sock",
            state: voiceState
        )
        self.socketClient = client

        // Wire the send-command closure so BarView buttons -> socket
        voiceState.sendCommand = { [weak client] cmd in
            client?.send(command: cmd)
        }

        client.connect()

        // Floating pill
        let barView = BarView(state: voiceState)
        let hosting  = NSHostingView(rootView: barView)
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.pillWidth, height: Theme.pillHeight)

        let pill = FloatingPillPanel(content: hosting)
        pill.positionAtBottom()
        pill.orderFront(nil)
        self.panel = pill
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketClient?.disconnect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false        // keep running as a menu-bar agent
    }
}

// MARK: - SwiftUI App entry point

@main
struct FlowBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {

        // Menu bar icon + dropdown
        MenuBarExtra("FlowBar", systemImage: "waveform.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appDelegate.voiceState.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(appDelegate.voiceState.isConnected ? "Connected" : "Disconnected")
                        .font(.system(.caption, weight: .medium))
                }
                Divider()
                Button("Quit Flow Bar") {
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
