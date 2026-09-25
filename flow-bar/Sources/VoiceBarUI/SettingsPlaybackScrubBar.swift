import SwiftUI

/// The timeline under a playing History clip: current/total time, drag to seek, ←/→ to step,
/// and a VoiceOver adjustable value.
///
/// AIDEV-NOTE: This is its own View on purpose. It samples the clip's position on a timer; if
/// that read happened inside SettingsView's body, every tick would re-render the whole Settings
/// window. Keep position reads in here.
struct SettingsPlaybackScrubBar: View {
    let playback: SettingsAudioPlayback
    let url: URL
    let accessibilityNoun: String

    static let tickInterval: TimeInterval = 0.25
    static let trackHeight: CGFloat = 4
    static let knobDiameter: CGFloat = 12

    /// Where the finger is while dragging, so the knob follows it rather than the sampled clock.
    @State private var dragFraction: Double?
    @FocusState private var isFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tickInterval)) { _ in
            let position = playback.position(of: url)
                ?? SettingsAudioPlaybackPosition(currentTime: 0, duration: 0)
            let shownTime = dragFraction.map(position.time(atFraction:)) ?? position.currentTime
            let shown = SettingsAudioPlaybackPosition(currentTime: shownTime, duration: position.duration)

            HStack(spacing: 8) {
                Text(SettingsAudioPlaybackPosition.clockLabel(shown.currentTime))
                    .frame(minWidth: 34, alignment: .trailing)
                track(shown)
                Text(SettingsAudioPlaybackPosition.clockLabel(shown.duration))
                    .frame(minWidth: 34, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position, \(accessibilityNoun)")
            .accessibilityValue(shown.spokenValue)
            .accessibilityAdjustableAction { direction in
                playback.skip(url, by: Self.seekDelta(for: direction))
            }
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let delta = Self.seekDelta(for: press.key) else { return .ignored }
            playback.skip(url, by: delta)
            return .handled
        }
        .help("Drag to seek; ← and → step \(Int(SettingsAudioPlayback.keyboardSeekStep)) seconds")
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
                        let fraction = Double(value.location.x / width)
                        dragFraction = min(max(fraction, 0), 1)
                        playback.seek(url, to: position.time(atFraction: fraction))
                    }
                    .onEnded { value in
                        playback.seek(url, to: position.time(atFraction: Double(value.location.x / width)))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: Self.knobDiameter + 4)
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
