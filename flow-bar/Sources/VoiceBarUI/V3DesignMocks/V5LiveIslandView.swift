import SwiftUI

public struct V5LiveIslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var projection: V5IslandProjection
    public var notchWidth: CGFloat
    public var stripHeight: CGFloat
    public var viewportWidth: CGFloat
    public var isHovering: Bool
    @Binding public var isMenuPresented: Bool
    public var onPrimaryTap: () -> Void
    public var onStop: () -> Void

    @State private var menu: V3IslandMenu = .history
    @State private var openShellHeight: CGFloat = V3Theme.previewNotchHeight + 120

    public init(
        projection: V5IslandProjection,
        notchWidth: CGFloat,
        stripHeight: CGFloat,
        viewportWidth: CGFloat,
        isHovering: Bool,
        isMenuPresented: Binding<Bool>,
        onPrimaryTap: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.projection = projection
        self.notchWidth = notchWidth
        self.stripHeight = stripHeight
        self.viewportWidth = viewportWidth
        self.isHovering = isHovering
        _isMenuPresented = isMenuPresented
        self.onPrimaryTap = onPrimaryTap
        self.onStop = onStop
    }

    private var islandState: V3IslandState {
        if isMenuPresented { return .menuOpen(menu) }
        if projection.allowsHoverReveal, isHovering { return .hover }
        switch projection.renderKind {
        case .idle:
            return .idle
        case .recording, .speaking, .error:
            return .recording
        case .transcribing:
            return .transcribing
        }
    }

    private var layout: V3IslandLayout {
        V3IslandModel.layout(
            for: islandState,
            closedNotchWidth: notchWidth,
            stripHeight: stripHeight,
            measuredMenuHeight: openShellHeight,
            viewportWidth: viewportWidth
        )
    }

    public var body: some View {
        let layout = layout
        ZStack(alignment: .topLeading) {
            stripTapLayer(width: layout.shellFrame.width)

            if isMenuPresented {
                menuMaterialSheet(width: layout.shellFrame.width, height: layout.shellFrame.height)
                menuLayer(menu: menu)
            }

            leftSlot(layout: layout)
                .allowsHitTesting(false)

            if projection.allowsHoverReveal, isHovering, !isMenuPresented {
                hoverButtons(layout: layout)
            }

            if projection.renderKind == .recording || projection.renderKind == .speaking {
                rightBars(layout: layout)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: layout.shellFrame.width, height: layout.shellFrame.height, alignment: .topLeading)
        .background(background(layout: layout))
        .clipShape(clipShape(layout: layout))
        .animation(animationForCurrentState, value: projection.renderKind)
        .animation(animationForCurrentState, value: isMenuPresented)
        .offset(x: horizontalAnchorOffset(layout: layout))
    }

    private func stripTapLayer(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: width, height: stripHeight)
            .onTapGesture {
                if isMenuPresented {
                    isMenuPresented = false
                } else if projection.renderKind == .recording || projection.renderKind == .speaking {
                    onStop()
                } else if projection.renderKind == .idle || projection.renderKind == .error {
                    onPrimaryTap()
                }
            }
    }

    private func leftSlot(layout: V3IslandLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55 * projection.micOpacity))
                .frame(width: layout.micFrame.width, height: layout.micFrame.height)
                .position(x: layout.micFrame.midX, y: layout.micFrame.midY)
                .opacity(projection.renderKind == .idle ? 1 : 0)

            HStack(spacing: 5) {
                if projection.renderKind == .speaking {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(V3Theme.wingText)
                        .contentTransition(.interpolate)
                } else if projection.renderKind == .error {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(V3Theme.micLiveDot.opacity(0.72))
                } else {
                    Circle()
                        .fill(V3Theme.micLiveDot)
                        .frame(width: 7, height: 7)
                        .opacity(reduceMotion ? 1 : 0.72)
                }

                if projection.renderKind == .recording {
                    V5ElapsedRecordingLabel(startedAt: projection.recordingStartedAt)
                }
            }
            .frame(width: layout.leftSlotFrame.width, height: stripHeight)
            .offset(x: layout.topCornerRadius)
            .opacity((projection.renderKind == .recording || projection.renderKind == .speaking || projection
                    .renderKind == .error) ? 1 : 0)

            V3Spinner()
                .frame(width: V3IslandModel.spinnerSize.width, height: V3IslandModel.spinnerSize.height)
                .frame(width: layout.leftSlotFrame.width, height: stripHeight)
                .offset(x: layout.topCornerRadius, y: 0)
                .opacity(projection.renderKind == .transcribing ? 1 : 0)
        }
    }

    private func rightBars(layout: V3IslandLayout) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: layout.leftSlotFrame.width)
            Color.clear
                .frame(width: notchWidth)
            V5RMSBars(
                audioLevel: projection.audioLevel,
                staticFrozen: projection.usesStaticSpeakingBars
            )
            .frame(width: layout.waveformFrame.width)
            .frame(width: V3IslandModel.recordingRightEarWidth)
        }
        .frame(width: layout.visualWidth, height: stripHeight)
        .offset(x: layout.topCornerRadius)
    }

    private func hoverButtons(layout: V3IslandLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if layout.buttonFrames.count == 2 {
                v5Button(systemName: "clock.arrow.circlepath", label: "History", frame: layout.buttonFrames[0]) {
                    menu = .history
                    isMenuPresented = true
                }
                v5Button(systemName: "character.book.closed", label: "Terms", frame: layout.buttonFrames[1]) {
                    menu = .terms
                    isMenuPresented = true
                }
            }
        }
    }

    private func v5Button(
        systemName: String,
        label: String,
        frame: CGRect,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: frame.width, height: frame.height)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel(label)
    }

    private func menuLayer(menu: V3IslandMenu) -> some View {
        let content = Group {
            switch menu {
            case .history:
                V5HistoryMenuView(rows: projection.historyRows)
            case .terms:
                V5TermsMenuView(
                    preservedRows: projection.preservedTerms,
                    correctedRows: projection.correctedTerms
                )
            }
        }

        return content
            .padding(.top, stripHeight)
            .padding(.horizontal, 19)
            .padding(.bottom, V3Theme.radiiExpanded.top)
            .frame(width: min(640, max(280, viewportWidth - 76)), alignment: .top)
            .frame(width: viewportWidth, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { measured in
                openShellHeight = max(stripHeight, measured)
            }
    }

    private func menuMaterialSheet(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.72))
                .background(.ultraThinMaterial)
                .frame(width: width, height: height)

            V3NotchShape(
                topCornerRadius: V3Theme.radiiClosed.top,
                bottomCornerRadius: V3Theme.radiiClosed.bottom
            )
            .fill(V3Theme.islandBlack)
            .frame(width: notchWidth + 2 * V3Theme.radiiClosed.top, height: stripHeight)
        }
    }

    private func background(layout: V3IslandLayout) -> some View {
        Group {
            if isMenuPresented {
                Color.clear
            } else {
                V3NotchShape(
                    topCornerRadius: layout.topCornerRadius,
                    bottomCornerRadius: layout.bottomCornerRadius
                )
                .fill(V3Theme.islandBlack)
                .shadow(
                    color: .black.opacity(isHovering && projection.allowsHoverReveal ? 0.28 : 0),
                    radius: isHovering && projection.allowsHoverReveal ? 12 : 0,
                    y: isHovering && projection.allowsHoverReveal ? 3 : 0
                )
            }
        }
    }

    private func clipShape(layout: V3IslandLayout) -> some Shape {
        if isMenuPresented {
            return V5AnyShape(RoundedRectangle(cornerRadius: 0))
        }
        return V5AnyShape(V3NotchShape(
            topCornerRadius: layout.topCornerRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        ))
    }

    private func horizontalAnchorOffset(layout: V3IslandLayout) -> CGFloat {
        if isMenuPresented { return 0 }
        return layout.shellFrame.width / 2 - layout.hardwareNotchRect.midX
    }

    private var animationForCurrentState: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        if isMenuPresented { return V3Theme.springOpen }
        switch projection.renderKind {
        case .idle, .transcribing, .error:
            return V3Theme.springClose
        case .recording, .speaking:
            return V3Theme.springOpen
        }
    }
}

private struct V5ElapsedRecordingLabel: View {
    var startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startedAt ?? context.date))
            Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(V3Theme.wingText)
                .contentTransition(.numericText())
        }
    }
}

private struct V5RMSBars: View {
    var audioLevel: Double?
    var staticFrozen: Bool

    private let baseHeights: [CGFloat] = [4, 8, 13, 10, 14, 7, 5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let t = staticFrozen ? 0 : context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(audioLevel ?? 0.35)
            HStack(spacing: 1.5) {
                ForEach(baseHeights.indices, id: \.self) { index in
                    let phase = t * 2.2 + Double(index) * 0.85
                    let live = staticFrozen ? 0.45 : (sin(phase) * 0.5 + 0.5)
                    let scaled = baseHeights[index] * (0.55 + min(max(level, 0), 1) * 0.7) * (0.82 + 0.32 * live)
                    Capsule()
                        .fill(V3Theme.barColor)
                        .frame(width: 2, height: min(14, max(4, scaled)))
                }
            }
            .frame(width: V3Theme.barSlotWidth, height: 16)
        }
    }
}

private struct V5HistoryMenuView: View {
    var rows: [V5IslandHistoryRow]

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text("No recent transcripts")
                    .font(.callout)
                    .foregroundStyle(V3Theme.wingTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, V3Theme.menuRowHPad)
                    .padding(.vertical, 14)
            } else {
                ForEach(rows) { row in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.text)
                                .font(.callout)
                                .foregroundStyle(V3Theme.wingText)
                                .lineLimit(1)
                            Text(row.id == 0 ? "latest" : "recent")
                                .font(.footnote)
                                .foregroundStyle(V3Theme.wingTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, V3Theme.menuRowHPad)
                        .padding(.vertical, V3Theme.menuRowVPad)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()

                    if row.id != rows.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                            .padding(.leading, V3Theme.menuRowHPad)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .background(V3Theme.menuContentSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct V5TermsMenuView: View {
    var preservedRows: [V5IslandPreservedTerm]
    var correctedRows: [V5IslandCorrectedTerm]

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader("Preserved")
            if preservedRows.isEmpty {
                emptyRow("No preserved terms")
            } else {
                ForEach(preservedRows) { row in
                    preservedRow(row)
                    Divider().overlay(Color.white.opacity(0.06))
                        .padding(.leading, V3Theme.menuRowHPad)
                }
            }

            sectionHeader("Corrected")
            if correctedRows.isEmpty {
                emptyRow("No learned corrections")
            } else {
                ForEach(correctedRows) { row in
                    correctedRow(row)
                    if row.id != correctedRows.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                            .padding(.leading, V3Theme.menuRowHPad)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .background(V3Theme.menuContentSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(V3Theme.wingTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, V3Theme.menuRowHPad)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(V3Theme.wingTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, V3Theme.menuRowHPad)
            .padding(.vertical, V3Theme.menuRowVPad)
    }

    private func preservedRow(_ row: V5IslandPreservedTerm) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.term)
                    .font(.callout)
                    .foregroundStyle(V3Theme.wingText)
                    .lineLimit(1)
                Text("preserve spelling")
                    .font(.footnote)
                    .foregroundStyle(V3Theme.wingTextSecondary)
            }
            Spacer()
            Text(row.term)
                .font(.caption.weight(.medium))
                .foregroundStyle(V3Theme.wingTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, V3Theme.menuRowHPad)
        .padding(.vertical, V3Theme.menuRowVPad)
    }

    private func correctedRow(_ row: V5IslandCorrectedTerm) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.from)
                    .font(.callout)
                    .foregroundStyle(V3Theme.wingText)
                    .lineLimit(1)
                Text("correct to")
                    .font(.footnote)
                    .foregroundStyle(V3Theme.wingTextSecondary)
            }
            Spacer()
            Text(row.to)
                .font(.caption.weight(.medium))
                .foregroundStyle(V3Theme.wingTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, V3Theme.menuRowHPad)
        .padding(.vertical, V3Theme.menuRowVPad)
    }
}

private struct V5AnyShape: Shape {
    private let makePath: @Sendable (CGRect) -> Path

    init(_ shape: some Shape) {
        makePath = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        makePath(rect)
    }
}
