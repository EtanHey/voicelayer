// LiveBarStatesSurface.swift — pass-2 qa-video capture surface.
//
// Renders the ACTUAL live `BarView` (post Capsule→NotchShape/FunnelPanelShape swap) for
// every voice state over a wallpaper. Hosted on-screen in a `.nonactivatingPanel` by the
// VoiceBarV9Preview executable (--live-states), so the real `.ultraThinMaterial` glass +
// black→glass gradient composite for the qa-video gate — the honest artifact, the SAME
// view code Etan's bar runs, not a stand-in preview. No socket / daemon; pure SwiftUI.

import SwiftUI

public struct LiveBarStatesSurface: View {
    public init() {}

    private final class PreviewRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
    }

    private static func state(for mode: VoiceMode) -> VoiceState {
        let s = VoiceState()
        s.mode = mode
        s.isConnected = true
        s.hotkeyEnabled = true
        s.isCollapsed = false
        switch mode {
        case .idle: s.transcript = ""
        case .recording: s.audioLevel = 0.5
            s.speechDetected = true
        case .transcribing: s.transcript = "Draft transcript"
        case .speaking:
            s.statusText = "Okay, I cropped it and everything looks right — want me to ship it?"
            s.wordBoundaries = [(0, 400, "Okay,"), (450, 300, "I"), (800, 400, "cropped")]
        case .error: s.errorMessage = "Try again"
        case .disconnected: break
        }
        return s
    }

    public var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.15, green: 0.20, blue: 0.35),
                    Color(red: 0.22, green: 0.16, blue: 0.35),
                    Color(red: 0.31, green: 0.17, blue: 0.30),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 30) {
                row("idle — bare notch band hugs the island", .idle)
                row("recording — flush to top, legible stop", .recording)
                row("transcribing — shimmer in the band", .transcribing)
                row("speaking — funnel panel grows OUT of the notch", .speaking)
                row("error — transient wake on the band", .error)
            }
            .padding(.top, 30)
        }
        .frame(width: 520, height: 560)
    }

    private func row(_ caption: String, _ mode: VoiceMode) -> some View {
        VStack(spacing: 8) {
            BarView(state: Self.state(for: mode), commandRouter: PreviewRouter())
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.62))
        }
    }
}
