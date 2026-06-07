// V3MockGallery.swift — contact-sheet harness for the v3 functional views.
//
// For typography/affordance review only — interaction and the island blend
// are judged on the RUNNING demo (V3MockDemo executable). The gallery renders
// each surface in a fixed state via ImageRenderer.

import SwiftUI

public struct V3MockGallery: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 28) {
            section("idle — bare silhouette (S7, refs/f_01)") {
                V3MockIdleIsland()
            }
            section("recording — wings, 1.35x notch (S6, refs/f_05)") {
                V3MockRecordingIsland()
            }
            section("recording — flat-display pill (S1, strip-height)") {
                V3MockFlatRecordingPill()
            }
            section("transcript menu content (functional view, static frame)") {
                V3TranscriptMenuView()
                    .frame(width: V3Theme.menuWidth - 2 * V3Theme.radiiExpanded.top)
                    .padding(V3Theme.radiiExpanded.top)
                    .background(
                        V3NotchShape(
                            topCornerRadius: V3Theme.radiiExpanded.top,
                            bottomCornerRadius: V3Theme.radiiExpanded.bottom
                        )
                        .fill(V3Theme.islandBlack)
                    )
            }
        }
        .padding(36)
        .frame(width: 560)
        .background(Color(red: 0.16, green: 0.13, blue: 0.35)) // wallpaper-dark stand-in
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            content()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

#Preview("V3 Mock Gallery") {
    V3MockGallery()
}
