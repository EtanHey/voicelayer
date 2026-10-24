import AppKit
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

    /// The held seek target, independent of the sampled clock and duration growth.
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
        let shown = drag.previewPosition(position)

        return HStack(spacing: isTeleprompter ? Self.teleprompterLabelSpacing : 8) {
            Text(SettingsAudioPlaybackPosition.clockLabel(shown.currentTime))
                .font(isTeleprompter ? .system(size: 10, design: .monospaced) : .caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: isTeleprompter ? Self.teleprompterLabelWidth(for: position.duration) : nil,
                       alignment: .trailing)
                .frame(minWidth: 34, alignment: .trailing)
                .opacity(labelOpacity(duration: position.duration))
            track(shown)
            durationText(shown.duration)
                .font(isTeleprompter ? .system(size: 10, design: .monospaced) : .caption.monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // "so far" fits inside this slot, which stays equal to the leading one, so the track stays on
                // the panel's centre axis and keeps its length when the total turns final.
                .frame(width: isTeleprompter ? Self.teleprompterLabelWidth(for: position.duration) : nil,
                       alignment: .leading)
                .frame(minWidth: 34, alignment: .leading)
                .opacity(labelOpacity(duration: position.duration))
        }
        .font(isTeleprompter ? .system(size: 10, design: .monospaced) : .caption.monospacedDigit())
        .foregroundStyle(isTeleprompter ? Color(red: 154/255, green: 154/255, blue: 163/255) : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position, \(accessibilityNoun)")
        .accessibilityValue(shown.spokenValue + (isGrowing ? ", synthesized so far; duration growing" : ""))
    }

    /// Equal teleprompter label slots keep the track centred on the panel's axis. NOTCH2: each slot fits the
    /// widest "<total> so far" of its duration's clock format (under an hour, under ten hours, longer), so the
    /// growing label never clips and the track keeps its length when the total turns final. A read that grows
    /// past an hour widens the slots once, when its clock format changes.
    static func teleprompterLabelWidth(for duration: TimeInterval) -> CGFloat {
        let widestTotal = switch duration {
        case ..<3600: "59:59"
        case ..<36000: "9:59:59"
        default: "99:59:59"
        }
        return ceil(teleprompterTextWidth(widestTotal, size: 10) + teleprompterTextWidth(" \(growingNote)", size: 9)) + 2
    }

    /// Matches `.system(size:design: .monospaced)`, the labels' font.
    static func teleprompterTextWidth(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)]).width
    }
    /// Wider than the knob radius, so the knob at either extreme never touches a label.
    static let teleprompterLabelSpacing: CGFloat = 12

    /// Teleprompter labels only describe a real duration; a row that cannot seek dims them.
    private func labelOpacity(duration: TimeInterval) -> Double {
        guard isTeleprompter else { return 1 }
        guard duration > 0 else { return 0 }
        return allowsSeeking ? 1 : 0.45
    }

    /// A sub-second agent reply reads `0:01`, never the `0:00` QA logged as a broken scrubber.
    static func teleprompterDurationLabel(_ duration: TimeInterval) -> String {
        SettingsAudioPlaybackPosition.clockLabel(duration > 0 ? max(duration, 1) : 0)
    }

    /// The only growing affordance (Etan, NOTCH2: "Solid bar + 'so far'", and no ellipsis): "so far" next to
    /// the total while synthesis is still adding audio. The track is the normal solid bar either way.
    static let growingNote = "so far"

    private func durationText(_ duration: TimeInterval) -> Text {
        guard isTeleprompter else {
            return Text(SettingsAudioPlaybackPosition.clockLabel(duration) + (isGrowing ? " \(Self.growingNote)" : ""))
        }
        let total = Text(Self.teleprompterDurationLabel(duration))
        guard isGrowing else { return total }
        return total + Text(" \(Self.growingNote)").font(.system(size: 9, design: .monospaced))
    }

    private func track(_ position: SettingsAudioPlaybackPosition) -> some View {
        GeometryReader { geometry in
            // One solid track for the audio synthesized so far; it is the whole bar whether or not the
            // total is final. "so far" beside the total carries the growing state, never a dotted tail.
            let availableWidth = max(geometry.size.width, 1)
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
                        .offset(x: min(max(knobX - 18, 0), availableWidth - 36), y: -19)
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
                            duration: self.position().duration
                        )
                    }
                    .onEnded { value in
                        drag.ended(
                            atFraction: Double(value.location.x / availableWidth),
                            duration: self.position().duration,
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

    /// Absolute target and the duration that defined the track when this gesture began.
    private var preview: SettingsAudioPlaybackPosition?
    var fraction: Double? { preview?.fraction }
    private(set) var hidesFocusRing = false

    func previewPosition(_ position: SettingsAudioPlaybackPosition) -> SettingsAudioPlaybackPosition {
        guard let preview else { return position }
        return SettingsAudioPlaybackPosition(
            currentTime: Self.clampedTime(preview.currentTime, duration: position.duration),
            duration: position.duration
        )
    }

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
        let gestureDuration = preview?.duration ?? duration
        preview = SettingsAudioPlaybackPosition(
            currentTime: Self.clampedTime(raw * gestureDuration, duration: gestureDuration),
            duration: gestureDuration
        )
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
        defer { preview = nil }
        guard duration.isFinite, duration > 0, raw.isFinite else { return }
        let gestureDuration = preview?.duration ?? duration
        let target = Self.clampedTime(raw * gestureDuration, duration: gestureDuration)
        seek(Self.clampedTime(target, duration: duration))
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
