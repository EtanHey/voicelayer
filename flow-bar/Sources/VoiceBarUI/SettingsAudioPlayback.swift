import AVFoundation
import Foundation

/// Play/stop state for the Settings → History Ask rows.
///
/// AIDEV-NOTE: One clip plays at a time across the whole list — starting the response stops the
/// question and vice versa. The AVAudioPlayer is injected so the state machine is testable
/// without touching real audio hardware; this surface is playback only and never touches the
/// capture path.
@MainActor
@Observable
public final class SettingsAudioPlayback {
    public private(set) var playingURL: URL?

    private let start: @MainActor (URL) -> Bool
    private let stopBackend: @MainActor () -> Void

    public init(
        start: @escaping @MainActor (URL) -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        self.start = start
        stopBackend = stop
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
            stop: { holder.stop() }
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
