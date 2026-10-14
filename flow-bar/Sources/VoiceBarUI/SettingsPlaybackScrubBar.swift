import SwiftUI

/// The timeline under a playing History clip: current/total time, drag to seek, ←/→ to step,
/// and a VoiceOver adjustable value.
///
/// AIDEV-NOTE: This is its own View on purpose. It samples the clip's position on a timer; if
/// that read happened inside SettingsView's body, every tick would re-render the whole Settings
/// window. Keep position reads in here.
struct SettingsPlaybackScrubBar: View {
    let position: () -> SettingsAudioPlaybackPosition
    let seek: (TimeInterval) -> Void
    let accessibilityNoun: String
    var isPlaying = true
    var isGrowing = false
    var allowsSeeking = true
    var isTeleprompter = false

    init(playback: SettingsAudioPlayback, url: URL, accessibilityNoun: String) {
        self.init(
            position: { playback.position(of: url) ?? SettingsAudioPlaybackPosition(currentTime: 0, duration: 0) },
            seek: { playback.seek(url, to: $0) },
            accessibilityNoun: accessibilityNoun
        )
    }

    init(position: @escaping () -> SettingsAudioPlaybackPosition,
         seek: @escaping (TimeInterval) -> Void, accessibilityNoun: String,
         isPlaying: Bool = true, isGrowing: Bool = false,
         allowsSeeking: Bool = true, isTeleprompter: Bool = false) {
        self.position = position
        self.seek = seek
        self.accessibilityNoun = accessibilityNoun
        self.isPlaying = isPlaying
        self.isGrowing = isGrowing
        self.allowsSeeking = allowsSeeking
        self.isTeleprompter = isTeleprompter
    }

    static let tickInterval: TimeInterval = 0.25
    static let trackHeight: CGFloat = 4
    static let knobDiameter: CGFloat = 12

    /// Where the finger is while dragging, so the knob follows it rather than the sampled clock.
    @State private var drag = SettingsScrubDrag()
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if allowsSeeking {
                tickingContent.accessibilityAdjustableAction { direction in
                    step(by: Self.seekDelta(for: direction))
                }
            } else {
                tickingContent
            }
        }
        .focusable(allowsSeeking)
        .focused($isFocused)
        .focusEffectDisabled(drag.hidesFocusRing)
        .onChange(of: isFocused) { _, focused in drag.focusChanged(to: focused) }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard allowsSeeking, let delta = Self.seekDelta(for: press.key) else { return .ignored }
            step(by: delta)
            return .handled
        }
        .help(allowsSeeking ? "Drag to seek; ← and → step \(Int(SettingsAudioPlayback.keyboardSeekStep)) seconds" : "No word timing available")
    }

    private var tickingContent: some View {
        Group {
            if isPlaying {
                TimelineView(.periodic(from: .now, by: Self.tickInterval)) { _ in
                    content(position())
                }
            } else {
                content(position())
            }
        }
    }

    private func content(_ position: SettingsAudioPlaybackPosition) -> some View {
        let shownTime = drag.fraction.map(position.time(atFraction:)) ?? position.currentTime
        let shown = SettingsAudioPlaybackPosition(currentTime: shownTime, duration: position.duration)

        return HStack(spacing: 8) {
            Text(SettingsAudioPlaybackPosition.clockLabel(shown.currentTime))
                .font(isTeleprompter ? .system(size: 10, design: .monospaced) : .caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: isTeleprompter ? 42 : nil, alignment: .trailing)
                .frame(minWidth: 34, alignment: .trailing)
                .opacity(isTeleprompter && !allowsSeeking && position.duration > 0 ? 0 : 1)
            track(shown)
            Text(SettingsAudioPlaybackPosition.clockLabel(shown.duration) + (isGrowing ? " so far…" : ""))
                .font(isTeleprompter ? .system(size: 10, design: .monospaced) : .caption.monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: isTeleprompter ? 90 : nil, alignment: .leading)
                .frame(minWidth: 34, alignment: .leading)
                .opacity(isTeleprompter && !allowsSeeking && position.duration > 0 ? 0 : 1)
        }
        .font(isTeleprompter ? .system(size: 10, design: .monospaced) : .caption.monospacedDigit())
        .foregroundStyle(isTeleprompter ? Color(red: 154/255, green: 154/255, blue: 163/255) : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position, \(accessibilityNoun)")
        .accessibilityValue(shown.spokenValue + (isGrowing ? ", synthesized so far; duration growing" : ""))
    }

    private func track(_ position: SettingsAudioPlaybackPosition) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            // Reserve a dashed, explicitly unknown tail. This is not an estimated total duration.
            let availableWidth = isGrowing && allowsSeeking ? width * 0.75 : width
            let knobX = CGFloat(position.fraction) * availableWidth
            let diameter = drag.fraction == nil ? Self.knobDiameter : 16

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(width: availableWidth, height: allowsSeeking ? Self.trackHeight : 2)
                if allowsSeeking {
                    Capsule()
                        .fill(isTeleprompter
                            ? AnyShapeStyle(LinearGradient(colors: [Color(red: 157/255, green: 184/255, blue: 1), Color(red: 92/255, green: 124/255, blue: 1)], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.accentColor))
                        .frame(width: knobX, height: Self.trackHeight)
                }
                if isGrowing && allowsSeeking {
                    Path { path in
                        path.move(to: CGPoint(x: availableWidth + 4, y: 12))
                        path.addLine(to: CGPoint(x: width, y: 12))
                    }
                    .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                }
                if allowsSeeking {
                    Circle()
                        .fill(Color.white.opacity(isTeleprompter ? 0.75 : 1))
                        .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: diameter, height: diameter)
                        .offset(x: knobX - diameter / 2)
                }
                if drag.fraction != nil {
                    Text(SettingsAudioPlaybackPosition.clockLabel(position.currentTime))
                        .font(.system(size: 10, design: .monospaced))
                        .padding(3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: min(max(knobX - 18, 0), width - 36), y: -19)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isFocused = true
                        drag.changed(
                            toFraction: Double(value.location.x / availableWidth),
                            duration: position.duration
                        )
                    }
                    .onEnded { value in
                        drag.ended(
                            atFraction: Double(value.location.x / availableWidth),
                            duration: position.duration,
                            seek: seek
                        )
                    },
                including: allowsSeeking ? .all : .none
            )
        }
        .frame(height: 24)
    }

    private func step(by delta: TimeInterval) {
        let current = position()
        guard allowsSeeking, current.duration > 0 else { return }
        seek(SettingsScrubDrag.clampedTime(current.currentTime + delta, duration: current.duration))
    }

    static func seekDelta(for key: KeyEquivalent) -> TimeInterval? {
        switch key {
        case .leftArrow: -SettingsAudioPlayback.keyboardSeekStep
        case .rightArrow: SettingsAudioPlayback.keyboardSeekStep
        default: nil
        }
    }

    static func seekDelta(for direction: AccessibilityAdjustmentDirection) -> TimeInterval {
        switch direction {
        case .increment: SettingsAudioPlayback.keyboardSeekStep
        case .decrement: -SettingsAudioPlayback.keyboardSeekStep
        @unknown default: 0
        }
    }
}

/// The scrub bar's drag and step logic, kept out of the view so it can be tested without a drag session.
///
/// AIDEV-NOTE: #199: a drag focuses the bar (so ←/→ step right after it) but must not leave the system focus
/// ring, like a click on a native slider. `hidesFocusRing` feeds `.focusEffectDisabled`; it is set by the drag
/// and cleared once focus leaves, so focus that arrives by Tab or VoiceOver shows the ring.
///
/// AIDEV-NOTE: #160 review: a drag that overshot the end seeked to the duration, which finishes the clip, which
/// unmounts this bar mid-drag. So a drag moves only the knob, clamped short of the end, and seeks once on
/// release; ←/→ and VoiceOver steps clamp the same way. The clip ends only by playing to its end.
struct SettingsScrubDrag {
    /// How far short of the end a drag or step can seek.
    static let endMargin: TimeInterval = 0.1

    private(set) var fraction: Double?
    private(set) var hidesFocusRing = false

    static func clampedTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(max(time, 0), max(duration - endMargin, 0))
    }

    @MainActor
    mutating func changed(
        toFraction raw: Double,
        duration: TimeInterval,
        playback _: SettingsAudioPlayback,
        url _: URL
    ) {
        changed(toFraction: raw, duration: duration)
    }

    mutating func changed(toFraction raw: Double, duration: TimeInterval) {
        hidesFocusRing = true
        guard duration.isFinite, duration > 0, raw.isFinite else { return }
        fraction = Self.clampedTime(raw * duration, duration: duration) / duration
    }

    @MainActor
    mutating func ended(
        atFraction raw: Double,
        duration: TimeInterval,
        playback: SettingsAudioPlayback,
        url: URL
    ) {
        ended(atFraction: raw, duration: duration, seek: { playback.seek(url, to: $0) })
    }

    mutating func ended(atFraction raw: Double, duration: TimeInterval, seek: (TimeInterval) -> Void) {
        defer { fraction = nil }
        guard duration.isFinite, duration > 0, raw.isFinite else { return }
        seek(Self.clampedTime(raw * duration, duration: duration))
    }

    mutating func focusChanged(to focused: Bool) {
        if !focused { hidesFocusRing = false }
    }

    @MainActor
    static func step(playback: SettingsAudioPlayback, url: URL, by delta: TimeInterval) {
        guard let position = playback.position(of: url) else { return }
        playback.seek(url, to: clampedTime(position.currentTime + delta, duration: position.duration))
    }
}
