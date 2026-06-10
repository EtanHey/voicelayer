// NotchV9Preview.swift — v9 silhouette + material preview surface.
//
// Renders the TESTED v9 geometry (NotchShape / FunnelPanelShape from NotchGeometry.swift)
// with the v9 material treatment so the Swift-rendered shapes can be screenshot natively
// and held against the mock (docs.local/design/notch-v9.html) before the live BarView
// silhouette swap. This is the "geometry spike + headline transition" artifact.
//
// Material per the mock:
//   - the notch band itself is opaque #000 (steal-list S5 / A3 — never glass on the island)
//   - the funnel panel gradients from near-black at the neck DOWN into glass
//     (linear-gradient #000 → rgba(20,20,27,.82) → rgba(13,13,18,.92)), over a blur
//   - reverse/inverse-radius shoulders so the panel "grows out of the notch"

import SwiftUI

// MARK: - v9 material tokens

public enum NotchV9Style {
    /// Opaque black for the camera-island band (never translucent — reveals the bezel).
    public static let bandFill = Color.black

    /// The black→glass vertical gradient the panel fills with (mock .gp.fun / .dpanel.fun9).
    public static let panelGradient = LinearGradient(
        stops: [
            .init(color: Color.black.opacity(0.98), location: 0.0),
            .init(color: Color(red: 0.078, green: 0.078, blue: 0.105, opacity: 0.86), location: 0.16),
            .init(color: Color(red: 0.055, green: 0.055, blue: 0.075, opacity: 0.93), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Hairline top-edge highlight + border (mock: border .5px #ffffff22, inset 0 1px 0 #ffffff14).
    public static let panelStroke = Color.white.opacity(0.13)

    /// Closed-notch idle radii (steal-list S3): top flares out 6, bottom 14.
    public static let closedTopRadius: CGFloat = 6
    public static let closedBottomRadius: CGFloat = 14
}

// MARK: - The notch band (idle / recording silhouette)

/// The black notch band: NotchShape filled opaque, with the camera dot centered. Used as
/// the idle silhouette and the top of every active state.
public struct NotchBandView: View {
    public var width: CGFloat
    public var height: CGFloat
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(
        width: CGFloat,
        height: CGFloat,
        topRadius: CGFloat = NotchV9Style.closedTopRadius,
        bottomRadius: CGFloat = NotchV9Style.closedBottomRadius
    ) {
        self.width = width
        self.height = height
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public var body: some View {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            .fill(NotchV9Style.bandFill)
            .frame(width: width, height: height)
            .overlay(alignment: .center) {
                // camera dot
                Circle()
                    .fill(Color(white: 0.04))
                    .frame(width: 5, height: 5)
                    .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1))
            }
    }
}

// MARK: - The funnel panel (grows OUT of the notch)

/// The v9 panel: FunnelPanelShape filled with the black→glass gradient over a blur, with a
/// hairline stroke. Content is laid inside, clipped to the funnel silhouette.
public struct FunnelPanelView<Content: View>: View {
    public var width: CGFloat
    public var height: CGFloat
    public var neckWidth: CGFloat
    public var shoulderDrop: CGFloat
    public var bottomRadius: CGFloat
    private let content: Content

    public init(
        width: CGFloat,
        height: CGFloat,
        neckWidth: CGFloat,
        shoulderDrop: CGFloat = 22,
        bottomRadius: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.height = height
        self.neckWidth = neckWidth
        self.shoulderDrop = shoulderDrop
        self.bottomRadius = bottomRadius
        self.content = content()
    }

    private var shape: FunnelPanelShape {
        FunnelPanelShape(neckWidth: neckWidth, shoulderDrop: shoulderDrop, bottomRadius: bottomRadius)
    }

    public var body: some View {
        content
            .frame(width: width, height: height)
            .background {
                ZStack {
                    // glass behind the gradient — the part below the neck reads as blur
                    shape.fill(.ultraThinMaterial)
                    shape.fill(NotchV9Style.panelGradient)
                    shape.stroke(NotchV9Style.panelStroke, lineWidth: 0.5)
                }
            }
            .clipShape(shape)
    }
}

// MARK: - Glass runtime-verify probe

/// ONLY the funnel panel over a CLEAR background, so `.ultraThinMaterial` blurs the real
/// desktop wallpaper behind the window. Screenshot this in an unfocused .nonactivatingPanel
/// to verify whether Liquid Glass survives (v3 research §Q2 unfocused-glass caveat). If the
/// panel shows the wallpaper blurred → glass works; if it's a flat slab → it degraded.
public struct GlassProbeSurface: View {
    public init() {}
    public var body: some View {
        FunnelPanelView(width: 300, height: 150, neckWidth: 128, shoulderDrop: 22, bottomRadius: 18) {
            VStack {
                Spacer()
                Text("glass probe — wallpaper should blur through")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Spacer()
            }
        }
        .frame(width: 340, height: 200, alignment: .top)
        .background(Color.clear)
    }
}

// MARK: - Composite preview surface (all v9 states on one wallpaper)

/// One surface rendering the v9 idle band, recording wings, and the speaking funnel panel
/// over a representative wallpaper gradient — the screenshot artifact for the qa-video gate.
public struct NotchV9PreviewSurface: View {
    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            // representative "wallpaper" so the glass/gradient reads honestly
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

            VStack(spacing: 34) {
                // --- idle band ---
                labeled("idle — bare notch silhouette") {
                    NotchBandView(width: 128, height: 26)
                }

                // --- recording: band with red dot + timer + waveform + stop ---
                labeled("recording — flush to top, stop button legible") {
                    NotchBandView(width: 230, height: 26)
                        .overlay {
                            HStack {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 7, height: 7)
                                    Text("0:07").font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                                Spacer()
                                HStack(spacing: 7) {
                                    waveBars
                                    stopSquare
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                }

                // --- speaking: funnel panel grows out of the notch ---
                labeled("speaking — funnel panel grows OUT of the notch") {
                    ZStack(alignment: .top) {
                        FunnelPanelView(width: 300, height: 150, neckWidth: 128, shoulderDrop: 22, bottomRadius: 18) {
                            VStack(spacing: 10) {
                                Text("“Okay, I cropped it and everything looks right — want me to ship it?”")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 18)
                                    .padding(.top, 30)
                                Spacer()
                            }
                        }
                        // the opaque black band sits ON TOP of the funnel neck (one shape illusion)
                        NotchBandView(width: 128, height: 26, bottomRadius: 0)
                    }
                }
            }
            .padding(.top, 26)
        }
        .frame(width: 460, height: 470)
    }

    private var waveBars: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 5, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.62, green: 0.72, blue: 1), Color(red: 0.36, green: 0.49, blue: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 2.3, height: [11, 6, 15, 8, 13][i])
            }
        }
    }

    private var stopSquare: some View {
        // v9 legible stop: 17px red button, 8px white square, ring (mock .sq)
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(red: 1, green: 0.27, blue: 0.23))
            .frame(width: 17, height: 17)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.2), lineWidth: 1.5))
            .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 8, height: 8))
    }

    private func labeled(_ caption: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 8) {
            content()
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.62))
        }
    }
}
