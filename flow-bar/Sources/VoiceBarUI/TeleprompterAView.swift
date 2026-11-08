import SwiftUI

/// Live reading surface. Readback keeps `TeleprompterView`; this view never starts, stops or records anything:
/// a click is a playback-only `speech_seek` (or the legacy offset seek on an old daemon).
public struct TeleprompterAView: View {
    public let text: String
    public var wordBoundaries: [TeleprompterBoundary] = []
    public var displayBlocks: [TeleprompterDisplayBlock] = []
    public var hasCompleteDisplay = false
    public var speechWords: SpeechWordTable?
    public var isPaused = false
    public var queuedCount = 0
    public var visibleLines = 3
    /// Nil hides the handle (the shell cannot grow yet).
    public var onVisibleLinesChange: ((Int) -> Void)?
    /// True while the handle owns the pointer (the panel must keep its mouse events), false on release.
    public var onHandleDrag: ((Bool) -> Void)?
    public var columnWidth = TeleprompterA.columnWidth
    public let playbackElapsedMilliseconds: () -> Int
    public var onSpeechSeek: ((String, Int) -> Void)?
    public var onSeek: ((Int) -> Void)?
    /// T3: drawn between the text and the handle (the live scrubber), so the handle sits under it.
    public var accessory: AnyView?

    public init(text: String, wordBoundaries: [TeleprompterBoundary] = [], displayBlocks: [TeleprompterDisplayBlock] = [],
                hasCompleteDisplay: Bool = false, speechWords: SpeechWordTable? = nil, isPaused: Bool = false,
                queuedCount: Int = 0, visibleLines: Int = 3,
                onVisibleLinesChange: ((Int) -> Void)? = nil, onHandleDrag: ((Bool) -> Void)? = nil, columnWidth: CGFloat = TeleprompterA.columnWidth,
                playbackElapsedMilliseconds: @escaping () -> Int,
                onSpeechSeek: ((String, Int) -> Void)? = nil, onSeek: ((Int) -> Void)? = nil,
                accessory: AnyView? = nil) {
        self.text = text
        self.wordBoundaries = wordBoundaries
        self.displayBlocks = displayBlocks
        self.hasCompleteDisplay = hasCompleteDisplay
        self.speechWords = speechWords
        self.isPaused = isPaused
        self.queuedCount = queuedCount
        self.visibleLines = TeleprompterA.clamp(visibleLines)
        self.onVisibleLinesChange = onVisibleLinesChange
        self.onHandleDrag = onHandleDrag
        self.columnWidth = columnWidth
        self.playbackElapsedMilliseconds = playbackElapsedMilliseconds
        self.onSpeechSeek = onSpeechSeek
        self.onSeek = onSeek
        self.accessory = accessory
    }

    @State private var cache = TeleprompterAModelCache()
    @State private var dragStartLines: Int?
    /// The scroll position the last slide settled on, so a seek's multi-line jump is told from a reading step.
    @State private var settledScrolledLines = 0
    @State private var handleOvershoot: CGFloat = 0
    /// True only between this handle's own `onHandleDrag(true)` and its one matching `false`.
    @State private var ownsPointer = false
    /// Resets to false however the gesture ends: release, cancellation, or the handle going away.
    @GestureState private var isHandleGestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.voiceBarNotchAppearance) private var notchAppearance

    private var palette: VoiceBarNotchContrastPalette { .resolve(for: notchAppearance) }

    public var body: some View {
        let model = cache.model(text: text, boundaries: wordBoundaries, blocks: displayBlocks,
                                complete: hasCompleteDisplay, column: columnWidth)
        VStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { _ in
                column(model, focus: model.focusWord(table: speechWords, clock: playbackElapsedMilliseconds()))
            }
            .frame(width: columnWidth, height: CGFloat(visibleLines) * TeleprompterA.lineHeight, alignment: .topLeading)
            .clipped()
            // T2 (Etan: "Reading is kind of redundant there") and T3: no status line; 1× is in the right wing.
            if let accessory {
                accessory
                    .frame(width: columnWidth, height: TeleprompterA.scrubberRowHeight, alignment: .top)
                    .padding(.top, TeleprompterA.scrubberGap)
            }
            handleRow
                .frame(width: columnWidth, height: TeleprompterA.handleBandHeight)
                .padding(.top, TeleprompterA.handleGap)
        }
    }

    private func column(_ model: TeleprompterAModel, focus: Int?) -> some View {
        let scrolled = TeleprompterA.scrolledLines(focusLine: focus.map { model.lineOfWord[$0] }, visibleLines: visibleLines)
        let focusGroup = focus.map { model.layouts[$0].highlightGroup }
        let window = max(0, scrolled - 1) ..< min(model.lines.count, scrolled + TeleprompterA.lineRange.upperBound + 2)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(window), id: \.self) { line in
                lineView(model, line: line, focusGroup: focusGroup)
                    .offset(y: CGFloat(line - scrolled) * TeleprompterA.lineHeight)
                    // QA 2026-11-08 c07 X1 (Etan R3: Pause seeked back). Lines mounted outside the visible band (the one
                    // above, for the slide; those below) are clipped from sight but not from hits, and the line above sat
                    // under the wing's Pause. Only a line you can see takes a click.
                    .allowsHitTesting(TeleprompterA.isVisible(line: line, scrolledLines: scrolled, visibleLines: visibleLines))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(TeleprompterA.slide(reduceMotion: reduceMotion, fromLine: settledScrolledLines, toLine: scrolled),
                   value: scrolled)
        .onChange(of: scrolled, initial: true) { _, line in settledScrolledLines = line }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(TeleprompterA.showsTopFade(scrolledLines: scrolled) ? 0 : 1), .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: TeleprompterA.topFadeHeight)
                Color.black
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Teleprompter")
        .accessibilityValue(TeleprompterA.sentence(model.layouts.map(\.displayText), around: focus))
    }

    private func lineView(_ model: TeleprompterAModel, line: Int, focusGroup: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.lines[line]), id: \.self) { word in
                let layout = model.layouts[word]
                let target = isPaused ? nil : model.seekTarget(for: word, table: speechWords)
                let ink = palette.primary.color.opacity(TeleprompterA.tier(group: layout.highlightGroup,
                                                                             focusGroup: focusGroup).opacity)
                HStack(spacing: 0) {
                    if let decoration = layout.decoration { Text(decoration + " ").accessibilityHidden(true) }
                    if let separator = layout.separator { Text(separator).accessibilityHidden(true) }
                    Button { seek(target) } label: { Text(layout.displayText) }
                        .buttonStyle(.plain)
                        // Not `.disabled`: that would re-tint the tiers. No target = no hit and no seek.
                        .allowsHitTesting(target != nil)
                        .accessibilityLabel("Jump to: \(layout.displayText)")
                        .accessibilityHint(target == nil ? "Not available right now" : "")
                }
                .foregroundStyle(ink)
                .font(.system(size: TeleprompterA.fontSize, weight: layout.isHeading ? .semibold : .medium))
                .padding(.leading, word == model.lines[line].lowerBound || layout.gluesToPrevious ? 0 : model.spacing)
            }
        }
        .lineLimit(1)
        .frame(height: TeleprompterA.lineHeight)
    }

    private func seek(_ target: TeleprompterAModel.SeekTarget?) {
        switch target {
        case let .word(utteranceID, index): onSpeechSeek?(utteranceID, index)
        case let .offset(milliseconds): onSeek?(milliseconds)
        case nil: break
        }
    }

    /// The home-bar handle centred under the scrubber; a queued-speech chip, when there is one, at the trailing edge.
    private var handleRow: some View {
        ZStack {
            if onVisibleLinesChange != nil { handle }
            if let chip = TeleprompterA.queuedChip(queuedCount) {
                HStack {
                    Spacer(minLength: 0)
                    Text(chip)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.secondary.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(palette.subtleTrack.color))
                        .accessibilityLabel("\(queuedCount) queued")
                }
            }
        }
    }

    private var handle: some View {
        Capsule()
            .fill(palette.secondary.color)
            .frame(width: TeleprompterA.handleSize.width, height: TeleprompterA.handleSize.height)
            .frame(width: TeleprompterA.handleSize.width + 32, height: TeleprompterA.handleBandHeight)
            .contentShape(Rectangle())
            // Icon-only control: the notch's native tooltip, like every wing button.
            .background(PillControlTooltip(text: "Drag to show more or fewer lines"))
            .offset(y: handleOvershoot)
            // Whole lines follow the pointer (the shell settles each with `pull`); past 3 or 8 only the handle
            // stretches. The window already holds eight lines, so nothing resizes under the pointer.
            .gesture(DragGesture(minimumDistance: 1)
                .updating($isHandleGestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    if !ownsPointer {
                        ownsPointer = true
                        onHandleDrag?(true)
                    }
                    let start = dragStartLines ?? visibleLines
                    dragStartLines = start
                    var follow = Transaction()
                    follow.disablesAnimations = true
                    withTransaction(follow) {
                        handleOvershoot = TeleprompterA.handleOvershoot(startLines: start, translation: value.translation.height)
                    }
                    let lines = TeleprompterA.snappedLines(startLines: start, translation: value.translation.height)
                    if lines != visibleLines {
                        withAnimation(reduceMotion ? nil : TeleprompterA.pull) { onVisibleLinesChange?(lines) }
                    }
                }
                .onEnded { value in
                    let lines = TeleprompterA.snappedLines(startLines: dragStartLines ?? visibleLines,
                                                           translation: value.translation.height)
                    withAnimation(reduceMotion ? nil : TeleprompterA.pull) {
                        handleOvershoot = 0
                        onVisibleLinesChange?(lines)
                    }
                    releasePointer()
                })
            // A cancelled gesture or an unmounted handle never delivers onEnded (formal/teleprompter-a-handle Cancel):
            // release on the gesture state's reset and on disappearance too. Idempotent.
            .onChange(of: isHandleGestureActive) { _, active in if !active { releasePointer() } }
            .onDisappear { releasePointer() }
            // Keyboard navigation only: a click must not make the non-activating panel key (R0856-10).
            .focusable(interactions: .activate)
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .accessibilityElement()
            .accessibilityLabel("Teleprompter height")
            .accessibilityValue("\(visibleLines) lines")
            .accessibilityAdjustableAction { direction in
                _ = step(direction == .increment ? 1 : -1)
            }
    }

    /// Lets go of this handle's pointer hold, at most once per drag; clears the drag seed and the stretch.
    private func releasePointer() {
        dragStartLines = nil
        handleOvershoot = 0
        guard ownsPointer else { return }
        ownsPointer = false
        onHandleDrag?(false)
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let lines = TeleprompterA.clamp(visibleLines + delta)
        guard lines != visibleLines else { return .handled }
        onVisibleLinesChange?(lines)
        return .handled
    }
}
