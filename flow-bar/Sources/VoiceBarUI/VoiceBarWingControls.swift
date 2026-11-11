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

/// X1-30 (Etan QA 2026-11-10: "the indicator is not beautiful ... or not the best located. It's not rounded
/// properly" / "when there is 1 in the queue, it is actually rounded"). The queued count on Forward's corner as a
/// real badge: a true circle for 1-9, an evenly rounded pill beyond, a fixed height whatever the digits, and a ring of
/// the notch's own fill. It never changes layout or hit rects.
/// M4 defects (lead, 2026-11-11): on the glyph it hid Forward; lifted above it, the screen's top edge (the wing's row
/// starts at y 0) shaved its rounding. The 32 pt top row has 6 pt above Forward's ink but 11.75 pt below it, so the
/// count hangs at Forward's bottom-trailing corner: below the ink (0.75 pt clear), 1.75 pt inside the row's bottom,
/// and centred 3 pt inside Forward's trailing edge so "10" overhangs by at most the 5 pt the hardware notch leaves
/// visible. Clear of the glyph, it needs no cut-out ring.
public enum VoiceBarQueueCountBadge {
    public static let height: CGFloat = 9
    public static let fontSize: CGFloat = 7
    public static let horizontalPadding: CGFloat = 1.5
    /// The badge centre from the control's bottom-trailing corner (the 20 pt plate, centred in the 32 pt row).
    public static let centreOffset = CGSize(width: -3, height: -0.25)

    /// How far to move a badge pinned bottom-trailing to the control so its centre lands on `centreOffset`.
    public static func placement(for label: String) -> CGSize {
        let size = size(for: label)
        return CGSize(width: centreOffset.width + size.width / 2, height: centreOffset.height + size.height / 2)
    }
    public static let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

    /// The painted size for `label`: never narrower than tall (a circle for one digit).
    public static func size(for label: String) -> CGSize {
        let text = ceil((label as NSString).size(withAttributes: [.font: tabular]).width)
        return CGSize(width: max(height, text + 2 * horizontalPadding), height: height)
    }

    private static var tabular: NSFont {
        let descriptor = font.fontDescriptor.withDesign(.rounded)?.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]]) ?? font.fontDescriptor
        return NSFont(descriptor: descriptor, size: fontSize) ?? font
    }

}

extension View {
    /// The queued count on a 20 pt transport control (Forward). BarView and the glyph-clearance pixel test share this
    /// placement, so the test measures what the notch draws.
    func queueCountBadge(_ label: String?, accessibilityLabel: String?) -> some View {
        modifier(VoiceBarQueueCountBadgeModifier(label: label, accessibilityLabel: accessibilityLabel))
    }
}

extension VoiceBarQueueCountBadge {
    /// R892 P3: the badge grows in from 0.6 as it arrives and shrinks as it leaves; with Reduce Motion it only fades.
    static func insertionScale(reduceMotion: Bool) -> CGFloat { reduceMotion ? 1 : 0.6 }

    enum TransitionKind: Equatable { case fade, scaleAndFade }

    static func transitionKind(reduceMotion: Bool) -> TransitionKind { reduceMotion ? .fade : .scaleAndFade }

    static func transition(_ kind: TransitionKind) -> AnyTransition {
        switch kind {
        case .fade: .opacity
        case .scaleAndFade:
            .scale(scale: insertionScale(reduceMotion: false), anchor: .topLeading).combined(with: .opacity)
        }
    }

    #if DEBUG
    /// Test oracle (R892-r2 P3): the transition the mounted modifier chose, in order.
    nonisolated(unsafe) static var recordedTransitionKinds: [TransitionKind] = []
    #endif
}

private struct VoiceBarReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Tests set this to drive Reduce Motion (SwiftUI's `accessibilityReduceMotion` is read-only); nil uses the system.
    var voiceBarReduceMotionOverride: Bool? {
        get { self[VoiceBarReduceMotionOverrideKey.self] }
        set { self[VoiceBarReduceMotionOverrideKey.self] = newValue }
    }
}

private struct VoiceBarQueueCountBadgeModifier: ViewModifier {
    let label: String?
    let accessibilityLabel: String?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.voiceBarReduceMotionOverride) private var reduceMotionOverride

    func body(content: Content) -> some View {
        let kind = VoiceBarQueueCountBadge.transitionKind(reduceMotion: reduceMotionOverride ?? systemReduceMotion)
        #if DEBUG
        VoiceBarQueueCountBadge.recordedTransitionKinds.append(kind)
        #endif
        return content.overlay(alignment: .bottomTrailing) {
            if let label {
                let placement = VoiceBarQueueCountBadge.placement(for: label)
                VoiceBarQueueCountBadgeView(label: label)
                    .offset(x: placement.width, y: placement.height)
                    .allowsHitTesting(false)
                    .accessibilityLabel(accessibilityLabel ?? "")
                    .transition(VoiceBarQueueCountBadge.transition(kind))
            }
        }
    }
}

struct VoiceBarQueueCountBadgeView: View {
    let label: String

    var body: some View {
        let size = VoiceBarQueueCountBadge.size(for: label)
        Text(label)
            .font(.system(size: VoiceBarQueueCountBadge.fontSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color.white)
            .frame(width: size.width, height: size.height)
            .background(Capsule().fill(Theme.speakingColor))
            .contentTransition(.numericText())
    }

}

/// 2.3 U2: the reading-aloud time in the right wing (`.time` in the mocks: 12 pt tabular digits, the secondary
/// ink). Its width fills the fixed wing's content lane beside Stop exactly, so Stop's hit rect is fixed.
public struct VoiceBarReadingTimeLabel: View {
    /// 57.5 pt lane − 6 pt spacing − 20 pt Stop.
    public static let width: CGFloat = VoiceBarNotchContract.fixedWingWidth
        - 2 * VoiceBarNotchContract.fixedWingContentInset
        - VoiceBarNotchContract.material.compactControlSpacing
        - VoiceBarNotchContract.material.compactControlSize

    let elapsedMilliseconds: () -> Int
    let color: Color
    /// T1 (QA 2026-11-08 S1-F6r): "Preparing speech…" has no player, so it shows no counter. The lane keeps its
    /// width so Stop never moves.
    var showsClock: () -> Bool = { true }

    /// X1-23 (Etan QA 2026-11-10: "it's become minutes because it's long should probably still have the full like
    /// seconds and minutes"): every clock keeps its seconds. "m:ss" to 9:59, "mm:ss" to 59:59, then "h:mm:ss" (capped
    /// at 99:59:59). The longer forms keep the region's width by drawing narrower (`VoiceBarClockFace`), never by
    /// dropping the seconds the old "10m" / "1h" forms lost.
    public static func text(elapsedMilliseconds: Int) -> String {
        let seconds = min(max(0, elapsedMilliseconds) / 1000, 99 * 3600 + 59 * 60 + 59)
        let mmss = String(format: "%02d", seconds % 60)
        if seconds < 3600 { return "\(seconds / 60):" + mmss }
        return "\(seconds / 3600):" + String(format: "%02d", seconds / 60 % 60) + ":" + mmss
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            // U2 review R1 (A2): the accessibility value is computed with the visible text on every tick, so
            // VoiceOver never reads a stale time.
            let shows = showsClock()
            let time = shows ? Self.text(elapsedMilliseconds: elapsedMilliseconds()) : ""
            Text(time)
                .font(.system(size: 12).width(VoiceBarClockFace.width(for: time)))
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

/// X1-23: the wing clock's face. Up to 9:59 it is the standard SF digits; "10:00" in them is 32.2 pt against the
/// 26 pt time region, so two-digit minutes draw in SF's condensed width (25.5 pt for "59:59") and hours in its
/// compressed width (scaled further only past the region, a read over an hour). Same size, weight, ink and tabular
/// digits throughout, so the wing, the meter and the 8 pt notch clearance never move.
public enum VoiceBarClockFace {
    public static func width(for text: String) -> Font.Width {
        switch text.count {
        case ...4: .standard
        case 5: .condensed
        default: .compressed
        }
    }

    static func nsWidth(for text: String) -> NSFont.Width {
        switch width(for: text) {
        case .condensed: .condensed
        case .compressed: .compressed
        default: .standard
        }
    }

    /// The font the time draws with (tabular digits), for measurement.
    public static func nsFont(for text: String, size: CGFloat = VoiceBarRecordingWingLabel.timeFontSize) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium, width: nsWidth(for: text))
        let tabular = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: tabular, size: size) ?? base
    }

    /// Only an hour-plus clock can still exceed the region in its compressed face; it scales down to fit.
    public static let minimumScaleFactor: CGFloat = 0.75
}

struct VoiceBarClockText: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: VoiceBarRecordingWingLabel.timeFontSize, weight: .medium)
                .width(VoiceBarClockFace.width(for: text)))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(VoiceBarClockFace.minimumScaleFactor)
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
    /// QA 0449: 4 layout points plus digit side-bearing paint a clear 6 pt gap. X4: reading uses it too, so the time
    /// and the meter sit the same way whether VoiceBar is listening or reading aloud.
    public static let recordingTimeGap: CGFloat = 4
    /// X4: between the reading meter and the collapsed Stop: one control spacing, so a hidden read's eye sits exactly
    /// over the meter's last control slot, one pitch inside Stop.
    public static let readingStopGap: CGFloat = VoiceBarNotchContract.material.compactControlSpacing

    /// X4: the reading row's width, the time region's leading edge to the meter's (or collapsed Stop's) trailing edge.
    public static func readingRowWidth(showsStop: Bool) -> CGFloat {
        width + recordingTimeGap + WaveformLayout.viewportWidth +
            (showsStop ? readingStopGap + VoiceBarNotchContract.material.compactControlSize : 0)
    }
    public static let timeFontSize: CGFloat = 11
    public static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium)
}

/// X4 (Etan, PR #860: "too much space on the right"): the reading right wing is the recording row (time, gap, meter),
/// centred in the wing with no blank outer region. Collapsed (paused or hidden), Stop follows the meter one control
/// spacing out, and the whole row stays centred.
struct VoiceBarReadingTrailingRow<Time: View, Meter: View, Stop: View>: View {
    let showsStop: Bool
    @ViewBuilder let time: Time
    @ViewBuilder let meter: Meter
    @ViewBuilder let stop: Stop

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            time
            meter
                .padding(.leading, VoiceBarRecordingWingLabel.recordingTimeGap)
            if showsStop {
                stop
                    .padding(.leading, VoiceBarRecordingWingLabel.readingStopGap)
            }
        }
    }

}

/// QA 0449: centre the time and meter as one row, without a blank outer region.
struct VoiceBarRecordingTrailingRow<Time: View, Meter: View>: View {
    @ViewBuilder let time: Time
    @ViewBuilder let meter: Meter

    var body: some View {
        HStack(alignment: .center, spacing: VoiceBarRecordingWingLabel.recordingTimeGap) {
            time
            meter
        }
    }
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
        // X4: the region keeps its width before capture opens, so the meter never jumps sideways when the time appears.
        ZStack(alignment: .trailing) {
            Color.clear.frame(width: VoiceBarRecordingWingLabel.width, height: 1)
            if isCaptureOpen {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let time = VoiceBarReadingTimeLabel.text(elapsedMilliseconds: elapsedMilliseconds())
                    VoiceBarClockText(text: time, color: color)
                        .frame(maxWidth: VoiceBarRecordingWingLabel.width, alignment: .trailing)
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

/// T5/T7 (Etan QA 2026-11-09: "consistent with the same waveform and time stuff that we have when recording"): the
/// reading time drawn exactly like the recording time (same region, font and ink), beside the same level meter.
public struct VoiceBarReadingTimeRegion: View {
    let elapsedMilliseconds: () -> Int
    let color: Color
    /// "Preparing speech…" has no player, so it shows no counter; the region keeps its width so nothing moves.
    var showsClock: () -> Bool = { true }

    public init(elapsedMilliseconds: @escaping () -> Int, color: Color, showsClock: @escaping () -> Bool = { true }) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.color = color
        self.showsClock = showsClock
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            // The accessibility value is computed with the visible text on every tick (U2 review R1).
            let shows = showsClock()
            let time = shows ? VoiceBarReadingTimeLabel.text(elapsedMilliseconds: elapsedMilliseconds()) : ""
            VoiceBarClockText(text: time, color: color)
                .frame(width: VoiceBarRecordingWingLabel.width, alignment: .trailing)
                .accessibilityElement()
                .accessibilityLabel("Reading time")
                .accessibilityValue(shows ? time : "Preparing")
        }
    }
}
