// V3IslandView.swift — V5 functional idle-interaction state machine.
//
// Functional SwiftUI only: real hover intent, clicks, timer, drag-to-menu,
// and mock transcribe delay. No daemon/socket wiring. Geometry constants
// trace to the notch-app steal-list: S2 frame formula, S3 one morphing shape,
// S4 springs, S6 wings, S9 fixed-slot waveform, S13 hover affordance,
// S14 morph-not-stack interrupts, A2/A4 avoid-list.

import SwiftUI

public struct V3IslandContainerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var micNamespace
    @State private var state: V3IslandState
    @State private var recordingStartedAt: Date?
    @State private var menuProgress: CGFloat
    @State private var dragMenu: V3IslandMenu = .history
    @State private var hoverTask: Task<Void, Never>?
    @State private var transcribeTask: Task<Void, Never>?
    /// R4 fix stays: open shell height is measured from mounted content.
    @State private var openShellHeight: CGFloat = V3Theme.previewNotchHeight + 120

    public var notchWidth: CGFloat
    public var stripHeight: CGFloat
    public var viewportWidth: CGFloat

    public init(
        notchWidth: CGFloat = V3Theme.previewNotchWidth,
        stripHeight: CGFloat = V3Theme.previewNotchHeight,
        viewportWidth: CGFloat = V3Theme.menuWidth + 2 * V3Theme.radiiExpanded.top,
        initialState: V3IslandState = .idle,
        initialMenuOpen: Bool = false
    ) {
        self.notchWidth = notchWidth
        self.stripHeight = stripHeight
        self.viewportWidth = viewportWidth
        let resolvedState: V3IslandState = initialMenuOpen ? .menuOpen(.history) : initialState
        _state = State(initialValue: resolvedState)
        _recordingStartedAt = State(initialValue: resolvedState == .recording ? Date(timeIntervalSinceNow: -42) : nil)
        _menuProgress = State(initialValue: resolvedState.menu == nil ? 0 : 1)
    }

    private var layout: V3IslandLayout {
        V3IslandModel.layout(
            for: renderState,
            closedNotchWidth: notchWidth,
            stripHeight: stripHeight,
            measuredMenuHeight: openShellHeight,
            viewportWidth: viewportWidth
        )
    }

    private var renderState: V3IslandState {
        if let menu = state.menu {
            return .menuOpen(menu)
        }
        if menuProgress > 0 {
            return .menuOpen(dragMenu)
        }
        return state
    }

    public var body: some View {
        let layout = layout
        let dragP = min(max(menuProgress, 0), 1)
        let draggingMenu = menuProgress > 0 && state.menu == nil
        let closedWidth = V3IslandModel.layout(
            for: state == .hover ? .hover : .idle,
            closedNotchWidth: notchWidth,
            stripHeight: stripHeight,
            measuredMenuHeight: openShellHeight,
            viewportWidth: viewportWidth
        ).shellFrame.width
        let shellWidth = draggingMenu ? V3Theme.lerp(closedWidth, layout.shellFrame.width, dragP) : layout.shellFrame
            .width
        let shellHeight = draggingMenu ? V3Theme.lerp(stripHeight, layout.shellFrame.height, dragP) : layout.shellFrame
            .height

        ZStack(alignment: .topLeading) {
            stripGestureLayer(width: shellWidth)

            if menuProgress > 0 {
                menuMaterialSheet(width: shellWidth, height: shellHeight)
                    .opacity(Double(menuProgress))
                    .allowsHitTesting(false)
            }

            menuLayer(menu: .terms)
                .opacity(state == .menuOpen(.terms) ? Double(menuProgress) : 0)
                .allowsHitTesting(state == .menuOpen(.terms))

            menuLayer(menu: .history)
                .opacity((state == .menuOpen(.history) || (state.menu == nil && menuProgress > 0)) ?
                    Double(menuProgress) : 0)
                .allowsHitTesting(state == .menuOpen(.history))

            leftSlotMountedContent(layout: layout)
                .allowsHitTesting(false)

            hoverButtons(layout: layout)
                .opacity(state == .hover ? 1 : 0)
                .blur(radius: state == .hover ? 0 : 20)
                .allowsHitTesting(state == .hover)

            recordingWaveformLayer(layout: layout)
                .opacity(state == .recording ? 1 : 0)
                .blur(radius: state == .recording ? 0 : 20)
                .allowsHitTesting(false)
        }
        .frame(width: shellWidth, height: shellHeight, alignment: .topLeading)
        .background(shellBackground(layout: layout))
        .clipShape(shellClipShape(layout: layout))
        .onHover(perform: handleHover)
        .animation(animationForStateChange, value: state)
        .onDisappear {
            hoverTask?.cancel()
            transcribeTask?.cancel()
        }
        .offset(x: horizontalAnchorOffset)
    }

    // MARK: - Mounted content layers

    private func menuLayer(menu: V3IslandMenu) -> some View {
        let content = Group {
            switch menu {
            case .history:
                V3TranscriptMenuView()
            case .terms:
                V3TermsMenuView()
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
                if state.menu == menu {
                    openShellHeight = max(stripHeight, measured)
                } else if state.menu == nil, menuProgress > 0, menu == .history {
                    openShellHeight = max(stripHeight, measured)
                }
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

    private func shellBackground(layout: V3IslandLayout) -> some View {
        Group {
            if menuProgress > 0 {
                Color.clear
            } else {
                V3NotchShape(topCornerRadius: layout.topCornerRadius, bottomCornerRadius: layout.bottomCornerRadius)
                    .fill(V3Theme.islandBlack)
                    .shadow(
                        color: .black.opacity(state == .hover ? 0.28 : 0),
                        radius: state == .hover ? 12 : 0,
                        y: state == .hover ? 3 : 0
                    )
            }
        }
    }

    private func shellClipShape(layout: V3IslandLayout) -> some Shape {
        if menuProgress > 0 {
            return AnyShape(RoundedRectangle(cornerRadius: 0))
        }
        return AnyShape(V3NotchShape(
            topCornerRadius: layout.topCornerRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        ))
    }

    private func stripGestureLayer(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: width, height: stripHeight)
            .onTapGesture { handleStripTap() }
            .gesture(pullGesture, including: state.menu == nil ? .gesture : .none)
    }

    private func leftSlotMountedContent(layout: V3IslandLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .matchedGeometryEffect(id: "mic", in: micNamespace)
                .frame(width: layout.micFrame.width, height: layout.micFrame.height)
                .position(x: layout.micFrame.midX, y: layout.micFrame.midY)
                .opacity((state == .idle || state == .hover) ? 1 : 0)
                .accessibilityLabel("Record")

            HStack(spacing: 5) {
                Circle()
                    .fill(V3Theme.micLiveDot)
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 1 : 0.72)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.0), value: state)
                elapsedLabel
            }
            .frame(width: layout.leftSlotFrame.width, height: stripHeight)
            .offset(x: layout.topCornerRadius)
            .opacity(state == .recording ? 1 : 0)

            V3Spinner()
                .frame(width: V3IslandModel.spinnerSize.width, height: V3IslandModel.spinnerSize.height)
                .frame(width: layout.leftSlotFrame.width, height: stripHeight)
                .offset(x: layout.topCornerRadius, y: 0)
                .opacity(state == .transcribing ? 1 : 0)
        }
    }

    private func hoverButtons(layout: V3IslandLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if layout.buttonFrames.count == 2 {
                hoverButton(
                    systemName: "clock.arrow.circlepath",
                    label: "History",
                    frame: layout.buttonFrames[0],
                    delay: 0,
                    event: .historyClick
                )
                hoverButton(
                    systemName: "character.book.closed",
                    label: "Terms",
                    frame: layout.buttonFrames[1],
                    delay: 0.04,
                    event: .termsClick
                )
            }
        }
    }

    private func hoverButton(
        systemName: String,
        label: String,
        frame: CGRect,
        delay: Double,
        event: V3IslandEvent
    ) -> some View {
        Button {
            transition(event)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: frame.width, height: frame.height)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .scaleEffect(state == .hover ? 1 : 0.92)
        .animation(.easeOut(duration: 0.15).delay(delay), value: state)
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel(label)
    }

    private func recordingWaveformLayer(layout: V3IslandLayout) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: layout.leftSlotFrame.width)

            Color.clear
                .frame(width: notchWidth)

            V3ModernWaveform()
                .frame(width: layout.waveformFrame.width)
                .frame(width: V3IslandModel.recordingRightEarWidth)
        }
        .frame(width: layout.visualWidth, height: stripHeight)
        .offset(x: layout.topCornerRadius)
    }

    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = recordingStartedAt.map { Int(context.date.timeIntervalSince($0)) } ?? 0
            Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(V3Theme.wingText)
                .contentTransition(.numericText())
        }
    }

    private var horizontalAnchorOffset: CGFloat {
        if menuProgress > 0 {
            return 0
        }
        return layout.shellFrame.width / 2 - layout.hardwareNotchRect.midX
    }

    // MARK: - Interaction

    private var animationForStateChange: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        switch state {
        case .idle:
            return V3Theme.springClose
        case .hover:
            return V3Theme.springInteractive
        case .recording, .menuOpen:
            return V3Theme.springOpen
        case .transcribing:
            return V3Theme.springClose
        }
    }

    @MainActor
    private func transition(_ event: V3IslandEvent) {
        let next = V3IslandModel.reduce(state, event: event)
        guard next != state else { return }
        apply(next)
    }

    @MainActor
    private func apply(_ next: V3IslandState) {
        hoverTask?.cancel()
        transcribeTask?.cancel()
        withAnimation(animation(for: state, next: next)) {
            state = next
            if next == .recording {
                recordingStartedAt = .now
            } else if next != .transcribing {
                recordingStartedAt = nil
            }
            menuProgress = next.menu == nil ? 0 : 1
        }
        if next == .transcribing {
            startMockTranscribe()
        }
    }

    private func animation(for old: V3IslandState, next: V3IslandState) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        if next == .hover { return V3Theme.springInteractive }
        if next == .idle { return V3Theme.springClose }
        if old == .recording, next == .transcribing { return V3Theme.springClose }
        return V3Theme.springOpen
    }

    @MainActor
    private func handleStripTap() {
        if state.menu != nil {
            transition(.closeSheet)
        } else {
            transition(.micClick)
        }
    }

    @MainActor
    private func handleHover(_ inside: Bool) {
        hoverTask?.cancel()
        guard state == .idle || state == .hover else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            transition(inside ? .hoverEnter : .hoverExit)
        }
    }

    /// Grab-down is 1:1 to the detent; springs only fire on release (§7.7).
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let travel = max(openShellHeight - stripHeight, 1)
                let raw = max(value.translation.height / travel, 0)
                let progress = raw <= 1 ? raw : 1 + ((raw - 1) * 0.18)
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    dragMenu = .history
                    menuProgress = min(progress, 1.04)
                }
            }
            .onEnded { _ in
                if menuProgress >= V3Theme.menuOpenThreshold {
                    transition(.grabDown(progress: menuProgress))
                } else if state.menu != nil {
                    transition(.closeSheet)
                } else {
                    withAnimation(V3Theme.springClose) { menuProgress = 0 }
                }
            }
    }

    @MainActor
    private func startMockTranscribe() {
        transcribeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            transition(.transcribeDone)
        }
    }
}

// MARK: - Terms mock sheet

public struct V3TermsMenuView: View {
    private let preservedRows: [(term: String, spelling: String)] = [
        ("VoiceLayer", "VoiceLayer"),
        ("repoGolem", "repoGolem"),
        ("Etan Heyman", "Etan Heyman"),
    ]
    private let correctedRows: [(got: String, expected: String)] = [
        ("voice layer", "VoiceLayer"),
        ("rapporteur golem", "repoGolem"),
        ("eaten hayman", "Etan Heyman"),
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            sectionHeader("Preserved")
            ForEach(preservedRows.indices, id: \.self) { index in
                preservedRow(preservedRows[index])
                Divider().overlay(Color.white.opacity(0.06))
                    .padding(.leading, V3Theme.menuRowHPad)
            }

            sectionHeader("Corrected")
            ForEach(correctedRows.indices, id: \.self) { index in
                correctedRow(correctedRows[index])
                if index != correctedRows.indices.last {
                    Divider().overlay(Color.white.opacity(0.06))
                        .padding(.leading, V3Theme.menuRowHPad)
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

    private func preservedRow(_ row: (term: String, spelling: String)) -> some View {
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
            Text(row.spelling)
                .font(.caption.weight(.medium))
                .foregroundStyle(V3Theme.wingTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, V3Theme.menuRowHPad)
        .padding(.vertical, V3Theme.menuRowVPad)
    }

    private func correctedRow(_ row: (got: String, expected: String)) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.got)
                    .font(.callout)
                    .foregroundStyle(V3Theme.wingText)
                    .lineLimit(1)
                Text("correct to")
                    .font(.footnote)
                    .foregroundStyle(V3Theme.wingTextSecondary)
            }
            Spacer()
            Text(row.expected)
                .font(.caption.weight(.medium))
                .foregroundStyle(V3Theme.wingTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, V3Theme.menuRowHPad)
        .padding(.vertical, V3Theme.menuRowVPad)
    }
}

// MARK: - Modernized waveform and spinner

struct V3ModernWaveform: View {
    private let baseHeights: [CGFloat] = [4, 8, 13, 10, 14, 7, 5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1.5) {
                ForEach(baseHeights.indices, id: \.self) { i in
                    let phase = t * 2.2 + Double(i) * 0.85
                    let live = (sin(phase) * 0.5 + 0.5)
                    let h = min(14, max(4, baseHeights[i] * (0.72 + 0.42 * live)))
                    Capsule()
                        .fill(V3Theme.barColor)
                        .frame(width: 2, height: h)
                }
            }
            .frame(width: V3Theme.barSlotWidth, height: 16)
        }
    }
}

struct V3Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 240
            Circle()
                .trim(from: 0.18, to: 0.82)
                .stroke(
                    Color.white.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
                .rotationEffect(.degrees(angle))
        }
    }
}

private struct AnyShape: Shape {
    private let makePath: @Sendable (CGRect) -> Path

    init(_ shape: some Shape) {
        makePath = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        makePath(rect)
    }
}

// MARK: - Compatibility static menu wrapper

public struct V3MockTranscriptMenu: View {
    public var notchWidth: CGFloat

    public init(notchWidth: CGFloat = V3Theme.previewNotchWidth) {
        self.notchWidth = notchWidth
    }

    public var body: some View {
        V3TranscriptMenuView()
            .padding(.top, V3Theme.previewNotchHeight)
            .padding(.horizontal, V3Theme.radiiExpanded.top)
            .padding(.bottom, V3Theme.radiiExpanded.top)
            .frame(width: V3Theme.menuWidth, alignment: .top)
            .background(
                V3NotchShape(
                    topCornerRadius: V3Theme.radiiExpanded.top,
                    bottomCornerRadius: V3Theme.radiiExpanded.bottom
                )
                .fill(V3Theme.islandBlack)
            )
    }
}

#Preview("V5 Functional island") {
    V3IslandContainerView(initialState: .hover)
        .padding(40)
        .frame(width: 520, height: 520, alignment: .top)
        .background(Color(red: 0.25, green: 0.2, blue: 0.5))
}
