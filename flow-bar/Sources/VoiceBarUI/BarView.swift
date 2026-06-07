// BarView.swift — Main pill UI for Voice Bar.
//
// Solid dark pill with dynamic width — shrink-wraps content per state.
// No vibrancy blur (eliminates dark edge artifacts on light backgrounds).
//
// Phase 5 polish: recording pulse, speaking waveform,
// state border glow, right-click context menu.

import AppKit
import SwiftUI

// MARK: - Pulsing recording dot

public struct PulsingDot: View {
    @State private var isPulsing = false

    public var body: some View {
        Circle()
            .fill(Theme.recordingColor)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(
                .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

public struct PulsingStatusLabel: View {
    public let text: String
    @State private var isPulsing = false

    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isPulsing ? 0.55 : 1.0)
            .animation(
                .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

public struct ProcessingSpinner: View {
    private let size: CGFloat = 14

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let angle = timeline.date.timeIntervalSinceReferenceDate * 360

            Circle()
                .trim(from: 0.08, to: 0.74)
                .stroke(
                    Theme.speakingColor.opacity(0.98),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(angle))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Bar View

public struct BarView: View {
    public var state: VoiceState
    public var commandRouter: BarCommandRouting
    public var surfaceStyle: VoiceBarSurfaceStyle
    public var menuBarProfile: VoiceBarMenuBarDisplayProfile
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isHistoryPresented = false
    @State private var isVocabularyPresented = false

    public var body: some View {
        switch surfaceStyle {
        case .floatingPill:
            pillContent
        case .menuBarIsland:
            menuBarIslandContent
        case .v5Island:
            v5IslandContent
        }
    }

    public init(
        state: VoiceState,
        commandRouter: BarCommandRouting,
        surfaceStyle: VoiceBarSurfaceStyle = .floatingPill,
        menuBarProfile: VoiceBarMenuBarDisplayProfile = .flat
    ) {
        self.state = state
        self.commandRouter = commandRouter
        self.surfaceStyle = surfaceStyle
        self.menuBarProfile = menuBarProfile
    }

    // MARK: - Pill content (collapsed or expanded)

    private var pillContent: some View {
        Group {
            if state.isCollapsed {
                collapsedPill
                    .transition(.scale.combined(with: .opacity))
            } else {
                expandedPill
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.pillTransition, value: state.isCollapsed)
        .onHover { hovering in
            state.setHovering(hovering)
        }
    }

    private var menuBarIslandContent: some View {
        VStack(spacing: 0) {
            Button {
                state.isTranscriptMenuPresented.toggle()
                state.setHovering(true)
            } label: {
                menuBarIslandBody
                    .frame(width: menuBarIslandWidth, height: menuBarIslandHeight)
                    .background(menuBarIslandBackground, in: menuBarIslandShape)
                    .overlay {
                        if menuBarProfile.isNotched {
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.black)
                                    .frame(height: VoiceBarMenuBarGeometry.notchTopSealHeight)
                                Spacer(minLength: 0)
                            }
                            .allowsHitTesting(false)
                        } else {
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        menuBarIslandShape
                            .stroke(menuBarIslandAccent, lineWidth: menuBarIslandBorderWidth)
                            .allowsHitTesting(false)
                            .animation(Theme.modeTransition, value: state.mode)
                    }
            }
            .buttonStyle(.plain)
            .contentShape(menuBarIslandShape)

            if state.isTranscriptMenuPresented {
                transcriptMenuShelf
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(
            width: menuBarSurfaceWidth,
            height: menuBarSurfaceHeight,
            alignment: .top
        )
        .onHover { hovering in
            state.setHovering(hovering)
        }
        .animation(Theme.pillTransition, value: state.mode)
        .animation(Theme.pillTransition, value: state.isTranscriptMenuPresented)
    }

    private var v5IslandContent: some View {
        let projection = V5IslandProjection.make(
            mode: state.mode,
            audioLevel: state.audioLevel,
            recordingStartedAt: state.recordingStartedAt,
            recentTranscriptions: state.recentTranscriptions,
            vocabularyTerms: state.transcriptionVocabularyTerms,
            vocabularyAliases: state.transcriptionVocabularyAliases,
            errorMessage: state.errorMessage
        )
        let notchWidth = menuBarProfile.notchRect?.width ?? V3Theme.previewNotchWidth
        let stripHeight = menuBarProfile.islandHeight
        let viewportWidth = state.isTranscriptMenuPresented
            ? max(716, notchWidth + 2 * V3Theme.radiiExpanded.top)
            : V3IslandModel.layout(
                for: projection.renderKind == .transcribing
                    ? .transcribing
                    : (projection.renderKind == .idle
                        ? (projection.allowsHoverReveal && state.isHovering ? .hover : .idle)
                        : .recording),
                closedNotchWidth: notchWidth,
                stripHeight: stripHeight,
                measuredMenuHeight: stripHeight
            ).shellFrame.width

        return V5LiveIslandView(
            projection: projection,
            notchWidth: notchWidth,
            stripHeight: stripHeight,
            viewportWidth: viewportWidth,
            isHovering: state.isHovering,
            isMenuPresented: Binding(
                get: { state.isTranscriptMenuPresented },
                set: { state.isTranscriptMenuPresented = $0 }
            ),
            onPrimaryTap: { commandRouter.handlePrimaryTap() },
            onStop: { commandRouter.handleStop() }
        )
        .onHover { hovering in
            state.setHovering(hovering)
        }
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
    }

    private var menuBarIslandBody: some View {
        let layout = menuBarIslandLayout
        return HStack(spacing: 0) {
            menuBarLeadingWing
                .frame(width: layout.leadingWing.width, height: layout.leadingWing.height)

            Rectangle()
                .fill(Color.black)
                .frame(width: layout.cameraSpacer.width, height: layout.cameraSpacer.height)
                .accessibilityHidden(true)

            menuBarTrailingWing
                .frame(width: layout.trailingWing.width, height: layout.trailingWing.height)
        }
        .clipShape(menuBarIslandShape)
    }

    private var menuBarLeadingWing: some View {
        HStack(spacing: 5) {
            switch state.mode {
            case .recording:
                Image(systemName: "mic.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.recordingColor)
                Text("0:00")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.speakingColor)
            case .transcribing:
                ProcessingSpinner()
                    .scaleEffect(0.72)
                    .frame(width: 10, height: 10)
            case .disconnected, .error:
                Circle()
                    .fill(Theme.errorColor)
                    .frame(width: 5, height: 5)
            case .idle:
                EmptyView()
            }
        }
        .padding(.leading, menuBarProfile.isNotched ? 6 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuBarTrailingWing: some View {
        HStack(spacing: 6) {
            if state.mode == .recording {
                menuBarWaveformMark
            } else if state.mode == .transcribing {
                Text("...")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            } else if state.mode == .speaking {
                Circle()
                    .fill(Theme.speakingColor)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.trailing, menuBarProfile.isNotched ? 6 : 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var menuBarIslandBackground: some ShapeStyle {
        if menuBarProfile.isNotched {
            return AnyShapeStyle(Color.black)
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    private var menuBarIslandShape: AnyShape {
        if menuBarProfile.isNotched {
            return AnyShape(state.mode == .idle || state.mode == .disconnected
                ? VoiceBarNotchShape.closed
                : VoiceBarNotchShape.open)
        }
        return AnyShape(Capsule())
    }

    private var menuBarWaveformMark: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array([11.0, 17.0, 13.0, 19.0].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 3, height: height)
            }
        }
        .frame(width: 27, height: 20)
        .accessibilityHidden(true)
    }

    private var menuBarIslandWidth: CGFloat {
        menuBarProfile.islandWidth(for: state.mode, isCollapsed: state.isCollapsed)
    }

    private var menuBarIslandHeight: CGFloat {
        menuBarProfile.islandHeight
    }

    private var menuBarSurfaceWidth: CGFloat {
        state.isTranscriptMenuPresented
            ? max(Theme.menuBarTranscriptMenuWidth, menuBarIslandWidth)
            : menuBarIslandWidth
    }

    private var menuBarSurfaceHeight: CGFloat {
        state.isTranscriptMenuPresented
            ? menuBarIslandHeight + Theme.menuBarTranscriptMenuHeight
            : menuBarIslandHeight
    }

    private var transcriptMenuShelf: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.black)
                .frame(width: max(92, menuBarIslandWidth - 44), height: 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Recent Transcripts")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(height: 18)

                VStack(spacing: 6) {
                    TranscriptMenuRow(
                        title: "Make the VoiceBar feel like it shipped with macOS.",
                        detail: "2 min ago",
                        leadingSystemImage: "text.quote",
                        primaryAction: "Fix",
                        secondaryAction: "Retry"
                    )
                    TranscriptMenuRow(
                        title: "The menu should rise from the island, not pop as a context menu.",
                        detail: "8 min ago",
                        leadingSystemImage: "text.bubble.fill",
                        primaryAction: "Fix",
                        secondaryAction: "Retry"
                    )
                    TranscriptMenuRow(
                        title: "Use the built-in notched display for every notched capture.",
                        detail: "14 min ago",
                        leadingSystemImage: "display",
                        primaryAction: "Fix",
                        secondaryAction: "Retry"
                    )
                    TranscriptMenuRow(
                        title: "Untranscribed recording",
                        detail: "0:47 retained audio",
                        leadingSystemImage: "waveform",
                        primaryAction: "Transcribe now",
                        secondaryAction: nil,
                        isPending: true
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 12)
            .frame(width: Theme.menuBarTranscriptMenuWidth, height: Theme.menuBarTranscriptMenuHeight - 8)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.62))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        }
        .frame(width: Theme.menuBarTranscriptMenuWidth, height: Theme.menuBarTranscriptMenuHeight)
    }

    private var menuBarIslandLayout: VoiceBarMenuBarIslandContentLayout {
        menuBarProfile.islandContentLayout(for: state.mode, isCollapsed: state.isCollapsed)
    }

    private var menuBarIslandAccent: Color {
        switch state.mode {
        case .recording:
            Theme.recordingColor.opacity(0.42)
        case .transcribing, .speaking:
            Theme.speakingColor.opacity(0.32)
        case .disconnected, .error:
            Theme.errorColor.opacity(0.24)
        case .idle:
            Color.white.opacity(0.08)
        }
    }

    private var menuBarIslandBorderWidth: CGFloat {
        switch state.mode {
        case .idle:
            0.5
        default:
            0.8
        }
    }

    // MARK: - Collapsed pill (just dot)

    private var collapsedPill: some View {
        Button {
            state.setHovering(true) // expand on tap
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.green) // VoiceBar is always alive — dot is always green
                    .frame(width: 10, height: 10)
                    .padding(8)
                    .background(Theme.pillBackground)
                    .clipShape(Capsule())

                if state.queueDepth > 1 {
                    queueBadge
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    // MARK: - Expanded pill (full content)

    private var expandedPill: some View {
        HStack(spacing: 8) {
            leadingIndicator
            stateContent
            if state.queueDepth > 1 {
                queueBadge
            }
            if !transcriptPreviewIsVisible {
                actionButtons
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, pillVerticalPadding)
        .frame(
            minWidth: state.mode == .speaking ? Theme.pillMinWidth : Theme.pillCompactWidth,
            alignment: .leading
        )
        .frame(width: pillFixedWidth, height: pillFixedHeight, alignment: .leading)
        .background(Theme.pillBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .fill(stateWashColor)
                .allowsHitTesting(false)
                .animation(Theme.modeTransition, value: state.mode)
        }
        .overlay {
            // State-dependent border glow
            Capsule()
                .strokeBorder(borderColor, lineWidth: borderWidth)
                .allowsHitTesting(false)
                .animation(Theme.modeTransition, value: state.mode)
        }
        .overlay {
            // Subtle inner edge for depth
            Capsule()
                .strokeBorder(Theme.pillInnerEdge, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // No drop shadow — clean edges like Wispr Flow
        .opacity(1.0)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Theme.pillTransition, value: state.mode)
        .animation(Theme.connectionTransition, value: state.isConnected)
        .animation(Theme.pillTransition, value: state.queueDepth)
        .animation(Theme.modeTransition, value: state.hotkeyPhase)
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
        .onChange(of: state.recentTranscriptions.count) { _, count in
            if count == 0 {
                isHistoryPresented = false
            }
        }
        .onChange(of: state.transcriptionVocabularyTerms.count) { _, count in
            if count == 0 {
                isVocabularyPresented = false
            }
        }
        .contentShape(Capsule())
    }

    // MARK: - Error state

    private func handleModeChange(_ newMode: VoiceMode) {
        errorDismissTask?.cancel()
        if newMode == .error {
            errorDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                state.dismissError()
            }
        }
        if newMode != .idle {
            isHistoryPresented = false
            isVocabularyPresented = false
        }
    }

    // MARK: - Border glow

    private var borderColor: Color {
        switch state.mode {
        case .recording: Theme.recordingColor.opacity(0.50)
        case .transcribing: Theme.speakingColor.opacity(0.48)
        case .speaking: Theme.speakingColor.opacity(0.3)
        case .error: Theme.errorColor.opacity(0.5)
        case .disconnected: Theme.errorColor.opacity(0.35)
        default: .clear
        }
    }

    private var borderWidth: CGFloat {
        switch state.mode {
        case .recording, .error, .disconnected: 1.5
        case .speaking, .transcribing: 1.0
        default: 0
        }
    }

    private var stateWashColor: Color {
        switch state.mode {
        case .recording:
            Theme.recordingColor.opacity(0.12)
        case .transcribing:
            Theme.speakingColor.opacity(0.10)
        default:
            .clear
        }
    }

    // MARK: - Leading indicator

    @ViewBuilder
    private var leadingIndicator: some View {
        if state.mode == .recording {
            PulsingDot()
        } else if state.mode == .transcribing {
            ProcessingSpinner()
        } else {
            Circle()
                .fill(state.mode == .disconnected ? Theme.errorColor : Color.green)
                .frame(width: 6, height: 6)
        }
    }

    private var queueBadge: some View {
        Text("\(state.queueDepth)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.speakingColor.opacity(0.22))
            .clipShape(Capsule())
            .contentTransition(.numericText())
    }

    // MARK: - State content (icon + label OR waveform)

    private var stateContent: some View {
        Group {
            switch state.mode {
            case .recording:
                let recordingContent = VoiceBarPresentation.recordingContent(
                    hotkeyPhase: state.hotkeyPhase
                )
                HStack(spacing: 8) {
                    if recordingContent.showsWaveform {
                        WaveformView(
                            mode: state.speechDetected ? .speechDetected : .listening,
                            audioLevel: state.audioLevel
                        )
                    }
                    if !recordingContent.statusText.isEmpty {
                        if recordingContent.usesPulsingLabelOpacity {
                            PulsingStatusLabel(text: recordingContent.statusText)
                        } else {
                            Text(recordingContent.statusText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    recordingContent.statusText.isEmpty ? "Recording" : recordingContent.statusText
                )
            case .speaking:
                if state.queueItems.count > 1 {
                    queueVisualization
                } else {
                    // Shimmer waveform + teleprompter during speaking
                    WaveformView(mode: .idle, audioLevel: state.audioLevel)
                    if !state.statusText.isEmpty {
                        TeleprompterView(
                            text: state.statusText,
                            wordBoundaries: state.wordBoundaries
                        )
                        .frame(
                            width: Theme.teleprompterViewportWidth,
                            height: Theme.teleprompterViewportHeight
                        )
                    } else {
                        statusLabel
                    }
                }
            case .transcribing:
                HStack(spacing: 8) {
                    WaveformView(mode: .processing)
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(statusText.isEmpty ? "Transcribing" : statusText)
            default:
                statusIcon
                statusLabel
            }
        }
        // Force a clean view identity swap on mode change — prevents glitchy
        // partial animations when SwiftUI tries to morph between different
        // view hierarchies (e.g., PulsingDot → TeleprompterView).
        .id(state.mode)
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    private var queueVisualization: some View {
        let preview = VoiceBarPresentation.queuePreview(from: state.queueItems)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Queue")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                if preview.overflowCount > 0 {
                    Text("+\(preview.overflowCount) more")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Text(preview.currentText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)
                .truncationMode(.tail)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Theme.speakingColor.opacity(0.95))
                        .frame(width: max(10, geo.size.width * preview.progress))
                }
                .animation(Theme.queueProgressTransition, value: preview.progress)
            }
            .frame(height: 4)

            if let nextText = preview.nextText {
                HStack(spacing: 6) {
                    Text("Up next")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(nextText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(width: Theme.pillQueueWidth, alignment: .leading)
    }

    // MARK: - Status icon

    @ViewBuilder
    private var statusIcon: some View {
        if state.mode == .idle || state.mode == .error {
            Button {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                commandRouter.handlePrimaryTap()
            } label: {
                statusIconImage
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.mode == .error ? "Retry voice recording" : "Start voice recording")
        } else {
            statusIconImage
        }
    }

    private var statusIconImage: some View {
        Image(systemName: iconName)
            .font(.system(size: transcriptPreviewIsVisible ? 16 : 14, weight: .semibold))
            .foregroundStyle(Theme.stateColor(for: state.mode))
            .frame(width: transcriptPreviewIsVisible ? 22 : 18)
            .fixedSize()
            .layoutPriority(2)
            .contentTransition(.interpolate)
    }

    private var iconName: String {
        switch state.mode {
        case .idle: "mic.fill"
        case .disconnected: "bolt.horizontal.circle.fill"
        case .speaking: "speaker.wave.2.fill"
        case .recording: "waveform"
        case .transcribing: "waveform"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Status text

    private var statusLabel: some View {
        Group {
            if transcriptPreviewIsVisible {
                Text(statusText)
                    .frame(width: transcriptPreviewWidth, alignment: .center)
            } else {
                Text(statusText)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .multilineTextAlignment(transcriptPreviewIsVisible ? .center : .leading)
        .lineLimit(statusLineLimit)
        .truncationMode(.tail)
        .contentTransition(.opacity)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var statusText: String {
        if let transcriptPreviewText {
            return transcriptPreviewText
        }

        return VoiceBarPresentation.liveStatusText(
            mode: state.mode,
            transcript: state.transcript,
            confirmationText: state.confirmationText,
            hotkeyPhase: state.hotkeyPhase,
            hotkeyEnabled: state.hotkeyEnabled,
            errorMessage: state.errorMessage,
            transcribingStatusText: state.transcribingStatusText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker
        )
    }

    /// Whether the displayed text was trimmed (needs leading fade).
    private var textIsTrimmed: Bool {
        transcriptPreviewIsVisible
    }

    private var compactPillUsesFixedHeight: Bool {
        state.mode != .speaking && !transcriptPreviewIsVisible && state.queueDepth <= 1
    }

    private var pillFixedHeight: CGFloat? {
        if let transcriptPreviewLayout {
            return transcriptPreviewLayout.height
        }
        if compactPillUsesFixedHeight {
            return Theme.pillCompactHeight
        }
        return nil
    }

    private var pillFixedWidth: CGFloat? {
        if state.keepsPasteFlowEnvelope {
            return Theme.panelWidth - (Theme.panelPadding * 2)
        }

        if let transcriptPreviewText {
            return Theme.transcriptPreviewPillWidth(for: transcriptPreviewText)
        }

        return Theme.pillContentWidth(
            for: state.mode,
            statusText: statusText,
            idleAccessoryButtonCount: idleAccessoryButtonCount,
            queueItemCount: state.queueItems.count
        )
    }

    private var pillVerticalPadding: CGFloat {
        transcriptPreviewLayout?.isMultiline == true ? 8 : 0
    }

    private var statusLineLimit: Int {
        transcriptPreviewLayout?.lineLimit ?? 1
    }

    private var transcriptPreviewWidth: CGFloat {
        Theme.transcriptPreviewWidth(for: statusText)
    }

    private var transcriptPreviewIsVisible: Bool {
        transcriptPreviewText != nil
    }

    private var transcriptPreviewLayout: VoiceBarTranscriptPreviewLayout? {
        transcriptPreviewText.map(VoiceBarPresentation.transcriptPreviewLayout(for:))
    }

    private var transcriptPreviewText: String? {
        VoiceBarPresentation.transcriptPreviewText(
            mode: state.mode,
            confirmationText: state.confirmationText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker
        )
    }

    private var idleAccessoryButtonCount: Int {
        VoiceBarPresentation.idleAccessoryButtonCount(
            recentTranscriptions: state.recentTranscriptions,
            transcriptionVocabularyTerms: state.transcriptionVocabularyTerms,
            transcriptionVocabularyAliases: state.transcriptionVocabularyAliases,
            canReplay: state.canReplay
        )
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if state.mode == .recording {
                pillButton(icon: "xmark") { commandRouter.handleCancel() }
                pillButton(icon: "stop.fill") { commandRouter.handleStop() }
            }
            if state.mode == .transcribing {
                pillButton(icon: "xmark") { commandRouter.handleCancel() }
            }
            if state.mode == .speaking {
                pillButton(icon: "stop.fill") { commandRouter.handleStop() }
            }
            if state.mode == .error {
                pillButton(icon: "xmark") { state.dismissError() }
            }
            if state.mode == .idle, !state.recentTranscriptions.isEmpty {
                historyButton
            }
            if state.mode == .idle,
               !state.transcriptionVocabularyTerms.isEmpty || !state.transcriptionVocabularyAliases.isEmpty {
                vocabularyButton
            }
            if state.mode == .idle, state.canReplay {
                pillButton(icon: "arrow.counterclockwise") { commandRouter.handleReplay() }
            }
        }
    }

    private var historyButton: some View {
        pillButton(icon: "clock.arrow.circlepath") {
            isHistoryPresented.toggle()
        }
        .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
            historyPopover
        }
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Transcriptions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.recentTranscriptions.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                if index == 0 {
                                    Text("Latest")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                HStack(spacing: 6) {
                                    historyActionButton(title: "Copy") {
                                        state.copyTranscript(item)
                                        isHistoryPresented = false
                                    }
                                    historyActionButton(title: "Paste") {
                                        state.repasteTranscript(item)
                                        isHistoryPresented = false
                                    }
                                }
                            }
                            Text(item)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)

                        if index < state.recentTranscriptions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(width: 320, height: 220)
        }
        .padding(14)
    }

    private var vocabularyButton: some View {
        pillButton(icon: "text.book.closed") {
            isVocabularyPresented.toggle()
        }
        .popover(isPresented: $isVocabularyPresented, arrowEdge: .bottom) {
            vocabularyPopover
        }
    }

    private var vocabularyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription Vocabulary")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Built-ins plus Wispr-derived hints used by local STT cleanup.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !state.transcriptionVocabularyTerms.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preserved Terms (\(state.transcriptionVocabularyTerms.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(state.transcriptionVocabularyTerms.enumerated()),
                                    id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 4) {
                                    if index == 0 {
                                        Text("Highest priority")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(item)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)

                                if index < state.transcriptionVocabularyTerms.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }

                    if !state.transcriptionVocabularyAliases.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Learned Corrections (\(state.transcriptionVocabularyAliases.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(state.transcriptionVocabularyAliases.enumerated()),
                                    id: \.offset) { index, alias in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(alias.to)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(alias.from)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)

                                if index < state.transcriptionVocabularyAliases.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 320, height: 260)
        }
        .padding(14)
    }

    private func historyActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pillButton(icon: String, action: @escaping () -> Void) -> some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}

private struct TranscriptMenuRow: View {
    let title: String
    let detail: String
    let leadingSystemImage: String
    let primaryAction: String
    let secondaryAction: String?
    var isPending: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: leadingSystemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPending ? Theme.transcribingColor : Color.white.opacity(0.76))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                transcriptMenuAction(primaryAction, prominent: isPending)
                if let secondaryAction {
                    transcriptMenuAction(secondaryAction, prominent: false)
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 42)
        .background(
            Color.white.opacity(isPending ? 0.085 : 0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(isPending ? 0.16 : 0.08), lineWidth: 0.5)
        }
    }

    private func transcriptMenuAction(_ title: String, prominent: Bool) -> some View {
        Button {} label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(prominent ? Color.black.opacity(0.88) : Color.white.opacity(0.78))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, prominent ? 8 : 7)
                .frame(height: 22)
                .background(
                    prominent ? Color.white.opacity(0.92) : Color.white.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}
