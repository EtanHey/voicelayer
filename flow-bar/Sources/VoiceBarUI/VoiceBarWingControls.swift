import AppKit
import SwiftUI

/// 2.3 U2 (3-wings mock): a setup problem (a missing permission, so the F5 listener cannot start) badges the gear
/// instead of adding a third control to the right wing; the badged gear opens Settings › General › Permissions.
public enum VoiceBarSetupAttention {
    /// SPEC (a): the tooltip names the problem in one sentence and says what a click does. State is never
    /// colour-only, so the label carries the same sentence.
    public static func tooltip(missing: [HotkeyPermission]) -> String {
        let names = missing.map(permissionName)
        guard !names.isEmpty else { return "Settings" }
        let subject: String = switch names.count {
        case 1: "\(names[0]) is off"
        case 2: "\(names[0]) and \(names[1]) are off"
        default: names.dropLast().joined(separator: ", ") + " and \(names[names.count - 1]) are off"
        }
        return "\(subject), so F5 can’t start dictation. Click to fix."
    }

    public static func accessibilityLabel(missing: [HotkeyPermission]) -> String {
        missing.isEmpty ? "Settings" : "Settings. " + tooltip(missing: missing)
    }

    static func permissionName(_ permission: HotkeyPermission) -> String {
        switch permission {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone access"
        }
    }
    /// The mock's `#ff9f0a` (macOS system orange, dark).
    public static let dotColor = Color(red: 1, green: 159.0 / 255, blue: 10.0 / 255)
    /// 7 pt dot with a 1.5 pt ring of the notch fill, so it reads against the glyph under it.
    public static let dotDiameter: CGFloat = 7
    public static let ringWidth: CGFloat = 1.5
    /// The mock puts the dot 4 pt inside a 26 pt button's top-right corner; scaled onto the 20 pt control that
    /// is 1 pt.
    public static let dotInset: CGFloat = 1
}

struct VoiceBarSetupAttentionDot: View {
    @Environment(\.voiceBarNotchAppearance) private var appearance

    var body: some View {
        Circle()
            .fill(VoiceBarSetupAttention.dotColor)
            .frame(width: VoiceBarSetupAttention.dotDiameter, height: VoiceBarSetupAttention.dotDiameter)
            .overlay {
                Circle().strokeBorder(ringColor, lineWidth: VoiceBarSetupAttention.ringWidth)
                    .padding(-VoiceBarSetupAttention.ringWidth)
            }
            .padding(.top, VoiceBarSetupAttention.dotInset)
            .padding(.trailing, VoiceBarSetupAttention.dotInset)
    }

    /// The mock's `--vb-fill` ring (#161618) on the dark notch (orange against it: 8.8:1). On the light glass a
    /// white ring left the orange edge at 2.1:1, under WCAG 1.4.11's 3:1 for a state graphic, so the light glass
    /// rings the dot in the notch's own dark ink instead (9.1:1).
    private var ringColor: Color {
        appearance == .light
            ? Color(red: 0.06, green: 0.07, blue: 0.10)
            : Color(red: 22.0 / 255, green: 22.0 / 255, blue: 24.0 / 255)
    }
}

/// 2.3 U2: the reading-aloud time in the right wing (`.time` in the mocks: 12 pt tabular digits, the secondary
/// ink). Its width fills the fixed wing's content lane beside Stop exactly, so Stop's hit rect is fixed.
public struct VoiceBarReadingTimeLabel: View {
    /// The 31.5 pt lane the fixed wing left beside Stop; T3 keeps it beside Show teleprompter and 1×.
    public static let width: CGFloat = VoiceBarNotchContract.readingTimeLaneWidth

    let elapsedMilliseconds: () -> Int
    let color: Color
    /// T1 (QA 2026-11-08 S1-F6r): "Preparing speech…" has no player, so it shows no counter. The lane keeps its
    /// width so Stop never moves.
    var showsClock: () -> Bool = { true }

    /// "m:ss" up to 9:59. Two-digit minutes with seconds ("10:00", 33.8 pt) overflow the fixed 31.5 pt lane, so a
    /// longer read shows whole minutes ("10m" to "99m"), then whole hours ("1h" to "99h"); all fit the lane.
    public static func text(elapsedMilliseconds: Int) -> String {
        let seconds = max(0, elapsedMilliseconds) / 1000
        if seconds < 600 {
            return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
        }
        let minutes = seconds / 60
        if minutes < 100 { return "\(minutes)m" }
        return "\(min(99, minutes / 60))h"
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            // U2 review R1 (A2): the accessibility value is computed with the visible text on every tick, so
            // VoiceOver never reads a stale time.
            let shows = showsClock()
            let time = shows ? Self.text(elapsedMilliseconds: elapsedMilliseconds()) : ""
            Text(time)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: Self.width)
                .accessibilityElement()
                .accessibilityLabel("Reading time")
                .accessibilityValue(shows ? time : "Preparing")
        }
    }
}

/// 2.3 N1 (Etan, QA round 1, S2-F3): the recording wing's live time, on the notch side of the level meter, with an
/// equal empty region on the outer side so the meter stays centred in the wing's VISIBLE part (review D3). The time
/// shows only once capture has opened (review D1). Etan, real M4 (2026-11-08): the timer must clear the physical
/// notch by at least 8 pt, and a two-line mic name ("MacB / ook…") is never acceptable. A readable single line does
/// not fit beside the 46 pt meter inside the morph canvas, so the capturing microphone is the time's tooltip and
/// VoiceOver value instead of wing text.
public enum VoiceBarRecordingWingLabel {
    /// The time's region: "9:59" / "0:54" at 11 pt is 25.0 pt (26 rounded up to whole points).
    public static let width: CGFloat = 26
    /// The empty region outside the meter: 2 pt narrower than the time's, which keeps the meter within 1 pt of the
    /// visible wing's centre (review D3 allows 2) and the M4 wing inside the 130 pt morph canvas.
    public static let outerRegionWidth: CGFloat = 24
    /// Between each region and the meter.
    public static let meterGap: CGFloat = 4
    public static let timeFontSize: CGFloat = 11
    public static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium)
}

public struct VoiceBarRecordingTimeRegion: View {
    let elapsedMilliseconds: () -> Int
    let isCaptureOpen: Bool
    let microphoneName: String?
    let color: Color

    public init(elapsedMilliseconds: @escaping () -> Int, isCaptureOpen: Bool, microphoneName: String?, color: Color) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.isCaptureOpen = isCaptureOpen
        self.microphoneName = microphoneName
        self.color = color
    }

    public var body: some View {
        Group {
            if isCaptureOpen {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let time = VoiceBarReadingTimeLabel.text(elapsedMilliseconds: elapsedMilliseconds())
                    Text(time)
                        .font(.system(size: VoiceBarRecordingWingLabel.timeFontSize, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityElement()
                        .accessibilityLabel("Recording time")
                        .accessibilityValue(microphoneName.map { "\(time), \($0)" } ?? time)
                }
            }
        }
        .frame(width: VoiceBarRecordingWingLabel.width, alignment: .trailing)
        .background(PillControlTooltip(text: microphoneName))
    }
}
