import AVFoundation
import Foundation

/// Where the playing clip is. A snapshot pulled from the backend on demand, never stored, so a
/// ticking clock does not invalidate every view that reads the playback model.
public struct SettingsAudioPlaybackPosition: Equatable, Sendable {
    public let currentTime: TimeInterval
    public let duration: TimeInterval

    public init(currentTime: TimeInterval, duration: TimeInterval) {
        self.currentTime = currentTime
        self.duration = duration
    }

    /// 0...1 along the clip; 0 when the duration is unknown.
    public var fraction: Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    public func time(atFraction fraction: Double) -> TimeInterval {
        guard duration.isFinite, duration > 0, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1) * duration
    }

    /// The adjustable value VoiceOver reads; "0:12" would be read digit by digit.
    public var spokenValue: String {
        "\(Self.spokenDuration(currentTime)) of \(Self.spokenDuration(duration))"
    }

    /// "m:ss", or "h:mm:ss" past an hour. Fractions are floored, so the label never runs ahead.
    public static func clockLabel(_ time: TimeInterval) -> String {
        let (hours, minutes, seconds) = components(time)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func spokenDuration(_ time: TimeInterval) -> String {
        let (hours, minutes, seconds) = components(time)
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if seconds > 0 || parts.isEmpty { parts.append(unit(seconds, "second")) }
        return parts.joined(separator: " ")
    }

    private static func unit(_ value: Int, _ name: String) -> String {
        "\(value) \(name)\(value == 1 ? "" : "s")"
    }

    /// Labels stop here (2777:46:39). A corrupt, huge-but-finite duration would otherwise trap converting to Int.
    static let largestLabelledSeconds: TimeInterval = 9_999_999

    private static func components(_ time: TimeInterval) -> (Int, Int, Int) {
        let total = time.isFinite ? Int(min(max(time, 0), largestLabelledSeconds).rounded(.down)) : 0
        return (total / 3600, total % 3600 / 60, total % 60)
    }
}

/// Play/stop/seek state shared by Recording, Ask Question, and Ask Response History rows.
///
/// AIDEV-NOTE: One clip plays at a time across both scopes. The AVAudioPlayer is injected so the
/// state machine is testable
/// without touching real audio hardware; this surface is playback only and never touches the
/// capture path.
/// AIDEV-NOTE: This is THE player model for History audio. The scrub bar drives `seek`/`skip`;
/// word-level click-to-seek should call `play(_:from:)` (it starts the clip when needed)
/// rather than growing a second player.
@MainActor
@Observable
public final class SettingsAudioPlayback {
    /// ←/→ and the VoiceOver increment/decrement step.
    public static let keyboardSeekStep: TimeInterval = 5

    public private(set) var playingURL: URL?

    private let start: @MainActor (URL) -> Bool
    private let stopBackend: @MainActor () -> Void
    private let positionBackend: @MainActor () -> SettingsAudioPlaybackPosition?
    private let seekBackend: @MainActor (TimeInterval) -> Void

    public init(
        start: @escaping @MainActor (URL) -> Bool,
        stop: @escaping @MainActor () -> Void,
        position: @escaping @MainActor () -> SettingsAudioPlaybackPosition? = { nil },
        seek: @escaping @MainActor (TimeInterval) -> Void = { _ in }
    ) {
        self.start = start
        stopBackend = stop
        positionBackend = position
        seekBackend = seek
    }

    public func isPlaying(_ url: URL) -> Bool {
        playingURL == url
    }

    /// Starts `url`, or stops it when it is already the clip playing.
    public func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        if playingURL != nil {
            stop()
        }
        if start(url) {
            playingURL = url
        }
    }

    public func stop() {
        guard playingURL != nil else { return }
        stopBackend()
        playingURL = nil
    }

    /// The playing clip's position, or nil when `url` is not the clip playing.
    public func position(of url: URL) -> SettingsAudioPlaybackPosition? {
        guard playingURL == url else { return nil }
        return positionBackend()
    }

    /// Moves the playing clip to `time`; a no-op for a clip that is not playing, so a drag that
    /// outlives its clip can never restart it. At or past the end, the clip finishes.
    public func seek(_ url: URL, to time: TimeInterval) {
        guard playingURL == url else { return }
        let target = time.isFinite ? max(time, 0) : 0
        if let duration = positionBackend()?.duration, duration.isFinite, duration > 0,
           target >= duration {
            // AVAudioPlayer parked at its duration stops without reliably calling its delegate,
            // which would strand the row in "playing" with a frozen bar.
            stop()
            return
        }
        seekBackend(target)
    }

    /// Plays `url` from `time`, starting it when it is not the clip playing. The entry point for
    /// word-level click-to-seek.
    public func play(_ url: URL, from time: TimeInterval) {
        if playingURL != url {
            toggle(url)
            guard playingURL == url else { return }
        }
        seek(url, to: time)
    }

    /// Steps the playing clip by `delta` seconds; a no-op for a clip that is not playing.
    public func skip(_ url: URL, by delta: TimeInterval) {
        guard let position = position(of: url) else { return }
        seek(url, to: position.currentTime + delta)
    }

    /// Called when the backend reports a clip finished on its own.
    public func playbackDidFinish(_ url: URL) {
        guard playingURL == url else { return }
        playingURL = nil
    }
}

public extension SettingsAudioPlayback {
    /// The real AVAudioPlayer-backed playback used by the app.
    static func system() -> SettingsAudioPlayback {
        let holder = SystemPlayerHolder()
        let playback = SettingsAudioPlayback(
            start: { url in holder.play(url) },
            stop: { holder.stop() },
            position: { holder.position },
            seek: { time in holder.seek(to: time) }
        )
        holder.onFinish = { [weak playback] url in
            playback?.playbackDidFinish(url)
        }
        return playback
    }
}

@MainActor
private final class SystemPlayerHolder: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((URL) -> Void)?
    private var player: AVAudioPlayer?
    private var currentURL: URL?

    func play(_ url: URL) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.delegate = self
        guard player.play() else { return false }
        self.player = player
        currentURL = url
        return true
    }

    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
    }

    var position: SettingsAudioPlaybackPosition? {
        guard let player else { return nil }
        return SettingsAudioPlaybackPosition(currentTime: player.currentTime, duration: player.duration)
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
    }

    // AIDEV-NOTE: AVAudioPlayer calls this on its own thread, so the whole body must hop before
    // touching `player`/`currentURL` — they are MainActor state and a finish racing play/stop
    // would otherwise inspect or clear the wrong player. Hopping only the onFinish callback is
    // not enough; the identity check itself reads shared state.
    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor [weak self] in
            guard let self, finished === player, let url = currentURL else { return }
            player = nil
            currentURL = nil
            onFinish?(url)
        }
    }
}
