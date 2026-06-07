import SwiftUI

public struct V5LiveIslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var projection: V5IslandProjection
    public var notchWidth: CGFloat
    public var stripHeight: CGFloat
    public var viewportWidth: CGFloat
    public var maxShellHeight: CGFloat
    public var isHovering: Bool
    public var uiState: V5IslandUIState
    public var onPrimaryTap: () -> Void
    public var onStop: () -> Void

    public init(
        projection: V5IslandProjection,
        notchWidth: CGFloat,
        stripHeight: CGFloat,
        viewportWidth: CGFloat,
        maxShellHeight: CGFloat = V3Theme.menuContentHeight + V3Theme.previewNotchHeight,
        isHovering: Bool,
        uiState: V5IslandUIState,
        onPrimaryTap: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.projection = projection
        self.notchWidth = notchWidth
        self.stripHeight = stripHeight
        self.viewportWidth = viewportWidth
        self.maxShellHeight = maxShellHeight
        self.isHovering = isHovering
        self.uiState = uiState
        self.onPrimaryTap = onPrimaryTap
        self.onStop = onStop
    }

    private var islandState: V3IslandState {
        if let menu = uiState.presentedMenu { return .menuOpen(menu) }
        if uiState.menuProgress > 0 { return .menuOpen(.history) }
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
            measuredMenuHeight: V5IslandPanelEnvelope.clampedShellHeight(
                measuredMenuHeight: uiState.measuredMenuHeight,
                stripHeight: stripHeight,
                maxShellHeight: maxShellHeight,
                isMenuPresented: uiState.isMenuPresented
            ),
            viewportWidth: viewportWidth
        )
    }

    public var body: some View {
        let layout = layout
        let dragP = min(max(uiState.menuProgress, 0), 1)
        let menuVisible = uiState.menuProgress > 0
        let draggingMenu = menuVisible && uiState.presentedMenu == nil
        let closedState = projection.renderKind == .idle && projection.allowsHoverReveal && isHovering
            ? V3IslandState.hover
            : V3IslandState.idle
        let closedWidth = V3IslandModel.layout(
            for: closedState,
            closedNotchWidth: notchWidth,
            stripHeight: stripHeight,
            measuredMenuHeight: stripHeight,
            viewportWidth: viewportWidth
        ).shellFrame.width
        let shellWidth = draggingMenu ? V3Theme.lerp(closedWidth, layout.shellFrame.width, dragP) : layout.shellFrame
            .width
        let shellHeight = draggingMenu ? V3Theme.lerp(stripHeight, layout.shellFrame.height, dragP) : layout.shellFrame
            .height
        ZStack(alignment: .topLeading) {
            stripTapLayer(layout: layout)

            if menuVisible {
                menuMaterialSheet(width: shellWidth, height: shellHeight)
                    .opacity(Double(dragP))
                    .allowsHitTesting(false)
            }

            if let menu = uiState.presentedMenu {
                menuLayer(menu: menu)
                    .opacity(Double(dragP))
                    .allowsHitTesting(true)
            } else if uiState.menuProgress > 0 {
                menuLayer(menu: .history)
                    .opacity(Double(dragP))
                    .allowsHitTesting(false)
            }

            leftSlot(layout: layout)
                .allowsHitTesting(false)

            if projection.allowsHoverReveal, isHovering, !uiState.isMenuPresented {
                hoverButtons(layout: layout)
            }

            if projection.renderKind == .recording || projection.renderKind == .speaking {
                rightBars(layout: layout)
                    .allowsHitTesting(false)
            }

            if uiState.isMenuPresented {
                closeHandleLayer(layout: layout)
            }
        }
        .frame(width: shellWidth, height: shellHeight, alignment: .topLeading)
        .background(background(layout: layout))
        .clipShape(clipShape(layout: layout))
        .animation(animationForCurrentState, value: projection.renderKind)
        .animation(animationForCurrentState, value: uiState.presentedMenu)
        .offset(x: menuVisible ? 0 : horizontalAnchorOffset(layout: layout))
        .gesture(dragUpGesture, including: uiState.isMenuPresented ? .gesture : .none)
    }

    private func stripTapLayer(layout: V3IslandLayout) -> some View {
        let hitRect = V5IslandHitRegion.primaryStripRect(layout: layout)
        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: hitRect.width, height: hitRect.height)
            .position(x: hitRect.midX, y: hitRect.midY)
            .gesture(pullDownGesture, including: uiState.isMenuPresented ? .none : .gesture)
            .onTapGesture {
                if uiState.isMenuPresented {
                    uiState.close(.islandTap)
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
            V5WaveformBars(
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
                    uiState.open(.history)
                }
                v5Button(systemName: "character.book.closed", label: "Terms", frame: layout.buttonFrames[1]) {
                    uiState.open(.terms)
                }
            }
        }
    }

    private func closeHandleLayer(layout: V3IslandLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(V5IslandCloseAffordance.closeHandleRects(layout: layout).enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .onTapGesture {
                        uiState.close(.islandTap)
                    }
            }
        }
        .frame(width: layout.shellFrame.width, height: stripHeight, alignment: .topLeading)
        .accessibilityLabel("Close VoiceBar sheet")
    }

    private var dragUpGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                if value.translation.height < -8 {
                    uiState.close(.dragUp)
                }
            }
    }

    private var pullDownGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let travel = max(maxShellHeight - stripHeight, 1)
                let raw = max(value.translation.height / travel, 0)
                let progress = raw <= 1 ? raw : 1 + ((raw - 1) * 0.18)
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    uiState.setDragProgress(progress)
                }
            }
            .onEnded { _ in
                if uiState.menuProgress >= V3Theme.menuOpenThreshold {
                    uiState.open(.history)
                } else {
                    withAnimation(V3Theme.springClose) {
                        uiState.setDragProgress(0)
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

        return ScrollView(.vertical) {
            content
                .padding(.top, stripHeight)
                .padding(.horizontal, 19)
                .padding(.bottom, V3Theme.radiiExpanded.top)
                .frame(width: min(640, max(280, viewportWidth - 76)), alignment: .top)
                .frame(width: viewportWidth, alignment: .top)
        }
            .scrollIndicators(.hidden)
            .frame(maxHeight: max(1, maxShellHeight - stripHeight), alignment: .top)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { proxy in
                min(maxShellHeight, proxy.size.height + stripHeight)
            } action: { measured in
                uiState.updateMeasuredMenuHeight(max(stripHeight, measured))
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
            if uiState.menuProgress > 0 {
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
        if uiState.menuProgress > 0 {
            return V5AnyShape(RoundedRectangle(cornerRadius: 0))
        }
        return V5AnyShape(V3NotchShape(
            topCornerRadius: layout.topCornerRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        ))
    }

    private func horizontalAnchorOffset(layout: V3IslandLayout) -> CGFloat {
        if uiState.isMenuPresented { return 0 }
        return layout.shellFrame.width / 2 - layout.hardwareNotchRect.midX
    }

    private var animationForCurrentState: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        if uiState.menuProgress > 0 { return V3Theme.springOpen }
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

enum V5WaveformSkinMetrics {
    static let barCount = 7
    static let minHeight: CGFloat = 2
    static let maxHeight: CGFloat = 16
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 1.5

    static func heights(audioLevel: Double?, time: Double, staticFrozen: Bool = false) -> [CGFloat] {
        let level = staticFrozen ? 0.45 : WaveformMetrics.listeningTargetLevel(from: audioLevel)
        return (0 ..< barCount).map { index in
            let normalized = WaveformMetrics.normalizedLevel(
                mode: .listening,
                audioLevel: level,
                time: time,
                index: index,
                barCount: barCount
            )
            return minHeight + (maxHeight - minHeight) * CGFloat(normalized)
        }
    }
}

private struct V5WaveformBars: View {
    var audioLevel: Double?
    var staticFrozen: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let heights = V5WaveformSkinMetrics.heights(
                audioLevel: audioLevel,
                time: context.date.timeIntervalSinceReferenceDate,
                staticFrozen: staticFrozen
            )
            HStack(spacing: V5WaveformSkinMetrics.barSpacing) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(V3Theme.barColor)
                        .frame(width: V5WaveformSkinMetrics.barWidth, height: heights[index])
                }
            }
            .frame(width: V3Theme.barSlotWidth, height: V5WaveformSkinMetrics.maxHeight)
        }
    }
}

private struct V5HistoryMenuView: View {
    var rows: [V5IslandHistoryRow]

    var body: some View {
        VStack(spacing: 6) {
            if rows.isEmpty {
                Text("No recent transcripts")
                    .font(.callout)
                    .foregroundStyle(V3Theme.wingTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, V3Theme.menuRowHPad)
                    .padding(.vertical, 14)
                    .background(V3Theme.menuContentSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
                        .background(V3Theme.menuContentSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct V5TermsMenuView: View {
    var preservedRows: [V5IslandPreservedTerm]
    var correctedRows: [V5IslandCorrectedTerm]

    var body: some View {
        VStack(spacing: 6) {
            sectionHeader("Preserved")
            if preservedRows.isEmpty {
                emptyRow("No preserved terms")
            } else {
                ForEach(preservedRows) { row in
                    preservedRow(row)
                }
            }

            sectionHeader("Corrected")
            if correctedRows.isEmpty {
                emptyRow("No learned corrections")
            } else {
                ForEach(correctedRows) { row in
                    correctedRow(row)
                }
            }
        }
        .padding(.vertical, 6)
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
            .background(V3Theme.menuContentSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
        .background(V3Theme.menuContentSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        .background(V3Theme.menuContentSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
