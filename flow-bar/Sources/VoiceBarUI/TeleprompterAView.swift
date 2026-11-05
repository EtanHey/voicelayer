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
    public var footerState = TeleprompterA.footerState(isPaused: false, isPausedForDictation: false)
    public var queuedCount = 0
    public var visibleLines = 3
    /// Nil hides the handle (the shell cannot grow yet).
    public var onVisibleLinesChange: ((Int) -> Void)?
    public var columnWidth = TeleprompterA.columnWidth
    public let playbackElapsedMilliseconds: () -> Int
    public var onSpeechSeek: ((String, Int) -> Void)?
    public var onSeek: ((Int) -> Void)?

    public init(text: String, wordBoundaries: [TeleprompterBoundary] = [], displayBlocks: [TeleprompterDisplayBlock] = [],
                hasCompleteDisplay: Bool = false, speechWords: SpeechWordTable? = nil, isPaused: Bool = false,
                footerState: String? = nil, queuedCount: Int = 0, visibleLines: Int = 3,
                onVisibleLinesChange: ((Int) -> Void)? = nil, columnWidth: CGFloat = TeleprompterA.columnWidth,
                playbackElapsedMilliseconds: @escaping () -> Int,
                onSpeechSeek: ((String, Int) -> Void)? = nil, onSeek: ((Int) -> Void)? = nil) {
        self.text = text
        self.wordBoundaries = wordBoundaries
        self.displayBlocks = displayBlocks
        self.hasCompleteDisplay = hasCompleteDisplay
        self.speechWords = speechWords
        self.isPaused = isPaused
        self.footerState = footerState ?? TeleprompterA.footerState(isPaused: isPaused, isPausedForDictation: false)
        self.queuedCount = queuedCount
        self.visibleLines = TeleprompterA.clamp(visibleLines)
        self.onVisibleLinesChange = onVisibleLinesChange
        self.columnWidth = columnWidth
        self.playbackElapsedMilliseconds = playbackElapsedMilliseconds
        self.onSpeechSeek = onSpeechSeek
        self.onSeek = onSeek
    }

    @State private var cache = TeleprompterAModelCache()
    @State private var dragStartLines: Int?
    @State private var dragHeight: CGFloat?
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
            .frame(width: columnWidth, height: dragHeight ?? CGFloat(visibleLines) * TeleprompterA.lineHeight,
                   alignment: .topLeading)
            .clipped()
            footer.frame(width: columnWidth, height: TeleprompterA.footerHeight)
            if onVisibleLinesChange != nil { handle }
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(TeleprompterA.slide(reduceMotion: reduceMotion), value: scrolled)
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

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerState)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary.color)
            Spacer(minLength: 0)
            if let chip = TeleprompterA.queuedChip(queuedCount) {
                Text(chip)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondary.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(palette.subtleTrack.color))
                    .accessibilityLabel("\(queuedCount) queued")
            }
        }
        .lineLimit(1)
    }

    private var handle: some View {
        Capsule()
            .fill(palette.tertiary.color)
            .frame(width: TeleprompterA.handleSize.width, height: TeleprompterA.handleSize.height)
            .frame(width: 64, height: 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartLines ?? visibleLines
                    dragStartLines = start
                    dragHeight = TeleprompterA.draggedHeight(startLines: start, translation: value.translation.height)
                }
                .onEnded { value in
                    let lines = TeleprompterA.snappedLines(startLines: dragStartLines ?? visibleLines,
                                                           translation: value.translation.height)
                    dragStartLines = nil
                    withAnimation(reduceMotion ? nil : TeleprompterA.pull) {
                        dragHeight = nil
                        onVisibleLinesChange?(lines)
                    }
                })
            .focusable()
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .accessibilityElement()
            .accessibilityLabel("Teleprompter height")
            .accessibilityValue("\(visibleLines) lines")
            .accessibilityAdjustableAction { direction in
                _ = step(direction == .increment ? 1 : -1)
            }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let lines = TeleprompterA.clamp(visibleLines + delta)
        guard lines != visibleLines else { return .handled }
        onVisibleLinesChange?(lines)
        return .handled
    }
}
