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

    init(playback: SettingsAudioPlayback, url: URL, accessibilityNoun: String) {
        self.init(
            position: { playback.position(of: url) ?? SettingsAudioPlaybackPosition(currentTime: 0, duration: 0) },
            seek: { playback.seek(url, to: $0) },
            accessibilityNoun: accessibilityNoun
        )
    }

    init(position: @escaping () -> SettingsAudioPlaybackPosition,
         seek: @escaping (TimeInterval) -> Void, accessibilityNoun: String,
         isPlaying: Bool = true, isGrowing: Bool = false) {
        self.position = position
        self.seek = seek
        self.accessibilityNoun = accessibilityNoun
        self.isPlaying = isPlaying
        self.isGrowing = isGrowing
    }

    static let tickInterval: TimeInterval = 0.25
    static let trackHeight: CGFloat = 4
    static let knobDiameter: CGFloat = 12

    /// Where the finger is while dragging, so the knob follows it rather than the sampled clock.
    @State private var drag = SettingsScrubDrag()
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(.periodic(from: .now, by: Self.tickInterval)) { _ in
                    content(position())
                }
            } else {
                content(position())
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled(drag.hidesFocusRing)
        .onChange(of: isFocused) { _, focused in drag.focusChanged(to: focused) }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let delta = Self.seekDelta(for: press.key) else { return .ignored }
            step(by: delta)
            return .handled
        }
        .help("Drag to seek; ← and → step \(Int(SettingsAudioPlayback.keyboardSeekStep)) seconds")
    }

    private func content(_ position: SettingsAudioPlaybackPosition) -> some View {
        let shownTime = drag.fraction.map(position.time(atFraction:)) ?? position.currentTime
        let shown = SettingsAudioPlaybackPosition(currentTime: shownTime, duration: position.duration)

        return HStack(spacing: 8) {
            Text(SettingsAudioPlaybackPosition.clockLabel(shown.currentTime))
                .fixedSize()
                .frame(minWidth: 34, alignment: .trailing)
            track(shown)
            Text(SettingsAudioPlaybackPosition.clockLabel(shown.duration) + (isGrowing ? "+" : ""))
                .fixedSize()
                .frame(minWidth: 34, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position, \(accessibilityNoun)")
        .accessibilityValue(shown.spokenValue + (isGrowing ? ", synthesized so far; duration growing" : ""))
        .accessibilityAdjustableAction { direction in
            step(by: Self.seekDelta(for: direction))
        }
    }

    private func track(_ position: SettingsAudioPlaybackPosition) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let knobX = CGFloat(position.fraction) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: knobX, height: Self.trackHeight)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .offset(x: knobX - Self.knobDiameter / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isFocused = true
                        drag.changed(
                            toFraction: Double(value.location.x / width),
                            duration: position.duration
                        )
                    }
                    .onEnded { value in
                        drag.ended(
                            atFraction: Double(value.location.x / width),
                            duration: position.duration,
                            seek: seek
                        )
                    }
            )
        }
        .frame(height: Self.knobDiameter + 4)
    }

    private func step(by delta: TimeInterval) {
        let current = position()
        guard current.duration > 0 else { return }
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
