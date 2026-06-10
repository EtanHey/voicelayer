// VoiceBarV9Preview — isolated v9 geometry preview window.
//
// Opens a single non-activating panel rendering NotchV9PreviewSurface so the v9 NotchShape
// / FunnelPanelShape render with REAL Liquid Glass (`.ultraThinMaterial`) on screen — which
// the offline ImageRenderer cannot composite. This also serves as the glass runtime-verify
// spike: the panel is `.nonactivatingPanel` and never takes focus, so a screenshot of it
// shows whether glass survives the unfocused state (v3 research §Q2 caveat).
//
// SAFETY: this binary opens NO socket, starts NO daemon, and uses NO shared paths. It cannot
// touch /Applications/VoiceBar.app or its process. It self-quits after a fixed delay so it
// never lingers. Run it, screenshot the window, done.

import AppKit
import SwiftUI
import VoiceBarUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel?

    func applicationDidFinishLaunching(_: Notification) {
        // Accessory app: no Dock icon, no menu-bar takeover.
        NSApp.setActivationPolicy(.accessory)

        // --glass-probe: render ONLY the funnel panel with a CLEAR view background, so
        // `.ultraThinMaterial` blurs the real desktop wallpaper behind the panel — the only
        // honest test of whether Liquid Glass survives in an unfocused .nonactivatingPanel.
        let glassProbe = CommandLine.arguments.contains("--glass-probe")
        // --live-states: render the REAL post-swap BarView for every voice state, so the
        // qa-video gate captures the actual live view code with real on-screen glass.
        let liveStates = CommandLine.arguments.contains("--live-states")
        let rootView: AnyView
        let size: NSSize
        if glassProbe {
            rootView = AnyView(GlassProbeSurface())
            size = NSSize(width: 340, height: 200)
        } else if liveStates {
            rootView = AnyView(LiveBarStatesSurface())
            size = NSSize(width: 520, height: 560)
        } else {
            rootView = AnyView(NotchV9PreviewSurface())
            size = NSSize(width: 460, height: 470)
        }
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Center on the main screen.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: f.midX - hosting.frame.width / 2,
                y: f.midY - hosting.frame.height / 2
            ))
        }

        // Order front WITHOUT activating — the panel stays unfocused, which is exactly
        // the condition under which we must verify glass does not degrade to plain blur.
        panel.orderFrontRegardless()
        self.panel = panel

        // Print the window frame so the screenshot harness can target it.
        let fr = panel.frame
        FileHandle.standardError.write(
            "V9_PANEL_FRAME x=\(Int(fr.minX)) y=\(Int(fr.minY)) w=\(Int(fr.width)) h=\(Int(fr.height))\n"
                .data(using: .utf8)!
        )

        // Self-quit after 25s so a forgotten instance never lingers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
