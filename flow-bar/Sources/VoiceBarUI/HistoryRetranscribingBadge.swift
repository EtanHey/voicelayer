import SwiftUI

/// The "Re-transcribing…" state of one History recording: a spinner and its label, shared by the notch History
/// panel so the notch and Settings › History show one consistent in-flight state (QA 2.2.25 lane B, 04:01).
struct HistoryRetranscribingBadge<Spinner: View>: View {
    static var title: String {
        "Re-transcribing…"
    }

    let fontSize: CGFloat
    let color: Color
    let spinner: Spinner

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            spinner
            Text(Self.title)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Re-transcribing stored audio")
    }
}

/// The badge's spinner, in one place so a test can render the same spinner at any angle.
enum HistoryRetranscribingSpinnerStyle {
    static let diameter = ProcessingSpinner.defaultDiameter
    static let showsTrack = true

    static func frame(angle: Double) -> ProcessingSpinnerFrame {
        ProcessingSpinnerFrame(angle: angle, diameter: diameter, showsTrack: showsTrack)
    }
}

extension HistoryRetranscribingBadge where Spinner == ProcessingSpinner {
    init(fontSize: CGFloat, color: Color) {
        self.init(
            fontSize: fontSize,
            color: color,
            spinner: ProcessingSpinner(
                diameter: HistoryRetranscribingSpinnerStyle.diameter,
                showsTrack: HistoryRetranscribingSpinnerStyle.showsTrack
            )
        )
    }
}

/// A symbol that turns while shown, driven by the clock rather than by a state change, so it spins from its first
/// frame and never animates its own layout (Settings › History's in-flight Re-transcribe icon, QA 2.2.25 C7–C9).
/// Its own view, so each tick re-evaluates only this symbol, never the Settings window around it.
struct HistorySpinningSymbol: View {
    /// One turn every 0.8 s, the speed the old repeatForever rotation had.
    static let degreesPerSecond = 450.0

    let systemName: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Image(systemName: systemName)
                .rotationEffect(.degrees(timeline.date.timeIntervalSinceReferenceDate * Self.degreesPerSecond))
        }
    }
}
