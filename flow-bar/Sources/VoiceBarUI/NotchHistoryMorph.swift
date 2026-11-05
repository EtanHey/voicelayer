import CoreGraphics
import Foundation
import SwiftUI

/// VoiceBar 2.3 lane U4: History morph B, exactly as Etan chose it in the approved mock (2-morph.html,
/// 5-history.html; "the best we've ever done", 2026-11-03). One progress value `p` drives everything:
/// p = 0 is the closed launcher, p = 1 the open panel. The shell's size follows `p` unclamped (the open
/// spring overshoots a little), the radii follow it clamped, and the rows grow out of the notch: they scale
/// up from 0.8 at the top edge, sharpen from a 20 pt blur, and fade in once the shape is 30 % open.
/// Every morph is a spring on `p`, so a new target retargets from the current position and velocity and
/// the morph reverses from wherever it is.
public enum NotchHistoryMorph {
    // MARK: Springs (BoringNotch's, as the mock states)

    public static let openResponse: Double = 0.42
    public static let openDampingFraction: Double = 0.8
    public static let closeResponse: Double = 0.45
    public static let closeDampingFraction: Double = 1.0

    // MARK: Radii

    /// The open panel's concave top flare where it meets the menu bar, and its convex bottom corners.
    public static let openTopRadius: CGFloat = 19
    public static let openBottomRadius: CGFloat = 24

    // MARK: Rows

    public static let rowsStartScale: CGFloat = 0.8
    public static let rowsStartBlur: CGFloat = 20
    /// The rows stay invisible for the first 30 % of the morph, then fade in over the rest.
    public static let rowsFadeStart: CGFloat = 0.3

    // MARK: Panel (Etan, 2026-11-03: "2 lines, 7 visible")

    public static let bodyWidth: CGFloat = 420
    public static let rowHeight: CGFloat = 46
    public static let visibleRows = 7
    /// V6 (Etan: "draggable to extend, downward-only is fine"): the handle adds whole rows up to 12 (the mock's
    /// `dims('history')`: 40 + rows × 46 + 18).
    public static let maximumRows = 12
    /// The list starts 8 pt under the 32 pt band (40 pt from the top of the screen); under it an 18 pt band holds
    /// the extend handle. The list is 404 pt wide in the 420 pt panel.
    public static let listTopInset: CGFloat = 8
    public static let handleBandHeight: CGFloat = 18
    public static let listHorizontalInset: CGFloat = 8
    public static var listHeight: CGFloat { listHeight(rows: CGFloat(visibleRows)) }
    public static var lowerSurfaceHeight: CGFloat { lowerSurfaceHeight(rows: CGFloat(visibleRows)) }

    public static func listHeight(rows: CGFloat) -> CGFloat { rowHeight * rows }

    public static func lowerSurfaceHeight(rows: CGFloat) -> CGFloat {
        listTopInset + listHeight(rows: rows) + handleBandHeight
    }

    // MARK: Extend handle (mock `.pull`: a 34 × 4 capsule, white 22 %, 50 % under the pointer)

    public static let handleWidth: CGFloat = 34
    public static let handleThickness: CGFloat = 4
    public static let handleOpacity: Double = 0.22
    public static let handleHoverOpacity: Double = 0.5
    /// The handle takes presses across a wider strip than it draws (Fitts): 88 pt × the band, plus 4 pt below.
    public static let handleHitWidth: CGFloat = 88
    /// The `pull` motion token: a released handle settles on the nearest whole row.
    public static let pullResponse: Double = 0.38
    public static let pullDampingFraction: Double = 0.86

    /// History's window below the 32 pt band: seven rows plus the transient-note reserve, or the 12-row panel,
    /// whichever is taller (578 pt; the window stays 610 pt, inside the 640 pt narrow-display guard). An extended
    /// panel and a note share this space; the shell never draws past it.
    public static var historyCanvasLowerSurfaceHeight: CGFloat {
        max(lowerSurfaceHeight(rows: CGFloat(visibleRows)) + VoiceBarNotchContract.transientNoteCanvasReserve,
            lowerSurfaceHeight(rows: CGFloat(maximumRows)))
    }

    /// How far the handle may extend: never past the rows there are to show (no empty rows), never past 12.
    public static func maximumRows(entryCount: Int) -> Int {
        max(visibleRows, min(maximumRows, entryCount))
    }

    /// The mock's handle drag: rows follow the pointer and stretch with resistance past either end (at most
    /// 0.6 of a row), so the handle never hits a wall.
    public static func rowsRubberBand(_ rows: CGFloat, maximum: Int) -> CGFloat {
        let low = CGFloat(visibleRows), high = CGFloat(maximum)
        if rows > high { return high + (1 - 1 / (1 + (rows - high) * 0.5)) * 0.6 }
        if rows < low { return low - (1 - 1 / (1 + (low - rows) * 0.5)) * 0.6 }
        return rows
    }

    /// Where a released handle settles: the nearest whole row inside 7…maximum. Never between rows.
    public static func snappedRows(_ rows: CGFloat, maximum: Int) -> Int {
        min(max(visibleRows, Int(rows.rounded())), max(visibleRows, maximum))
    }

    public static func rowsAnimation(from rows: CGFloat, to target: Int, velocity: Double) -> Animation {
        let coefficients = springCoefficients(response: pullResponse, dampingFraction: pullDampingFraction)
        let distance = Double(CGFloat(target) - rows)
        return .interpolatingSpring(
            mass: 1, stiffness: coefficients.stiffness, damping: coefficients.damping,
            initialVelocity: abs(distance) > 0.001 ? velocity / distance : 0
        )
    }

    // MARK: Pull-down

    /// A press that moves less than this is a click, never a drag.
    public static let dragSlop: CGFloat = 3
    /// The band a pull starts in, measured from the top of the screen.
    public static let pullBandHeight: CGFloat = 34
    /// A release faster than this (in progress per second) decides the target by its direction alone.
    public static let flickVelocity: Double = 0.5
    public static let maximumReleaseVelocity: Double = 8

    // MARK: Pure functions

    public static func clamp(_ value: CGFloat, _ lower: CGFloat = 0, _ upper: CGFloat = 1) -> CGFloat {
        min(upper, max(lower, value))
    }

    public static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }

    public static func rowsOpacity(progress p: CGFloat) -> CGFloat {
        clamp((p - rowsFadeStart) / (1 - rowsFadeStart))
    }

    public static func rowsScale(progress p: CGFloat) -> CGFloat {
        lerp(rowsStartScale, 1, clamp(p))
    }

    /// No blur at all once open: a zero-radius blur still costs a render pass.
    public static func rowsBlur(progress p: CGFloat) -> CGFloat {
        let pc = clamp(p)
        return pc > 0.999 ? 0 : lerp(rowsStartBlur, 0, pc)
    }

    public static func topRadius(progress p: CGFloat, closed: CGFloat) -> CGFloat {
        lerp(closed, openTopRadius, clamp(p))
    }

    public static func bottomRadius(progress p: CGFloat, closed: CGFloat) -> CGFloat {
        lerp(closed, openBottomRadius, clamp(p))
    }

    /// The shell at progress `p`: every extent is interpolated unclamped (so the open spring's overshoot
    /// stretches the panel a little past its size, as in the mock); the lower surface never goes negative.
    public static func geometry(
        progress p: CGFloat,
        closed: VoiceBarNotchGeometry,
        open: VoiceBarNotchGeometry
    ) -> VoiceBarNotchGeometry {
        VoiceBarNotchGeometry(
            coreWidth: open.coreWidth,
            topHeight: open.topHeight,
            leadingWingWidth: max(0, lerp(closed.leadingWingWidth, open.leadingWingWidth, p)),
            trailingWingWidth: max(0, lerp(closed.trailingWingWidth, open.trailingWingWidth, p)),
            bodyLeadingExtent: max(0, lerp(closed.bodyLeadingExtent, open.bodyLeadingExtent, p)),
            bodyTrailingExtent: max(0, lerp(closed.bodyTrailingExtent, open.bodyTrailingExtent, p)),
            lowerSurfaceHeight: max(0, lerp(closed.lowerSurfaceHeight, open.lowerSurfaceHeight, p))
        )
    }

    /// SwiftUI's `.spring(response:dampingFraction:)` as mass-1 physics (the mock's `springParams`).
    public static func springCoefficients(
        response: Double,
        dampingFraction: Double
    ) -> (stiffness: Double, damping: Double) {
        (pow(2 * Double.pi / response, 2), 4 * Double.pi * dampingFraction / response)
    }

    /// The spring toward `open`. `velocity` is in progress per second (a flick's release speed); SwiftUI's
    /// initial velocity is relative to the distance still to travel, so it is converted here. Interpolating
    /// springs merge with the one already running and keep its velocity, which is what makes every morph
    /// reverse from wherever it is.
    public static func animation(
        opening: Bool,
        from progress: CGFloat,
        velocity: Double = 0
    ) -> Animation {
        let coefficients = opening
            ? springCoefficients(response: openResponse, dampingFraction: openDampingFraction)
            : springCoefficients(response: closeResponse, dampingFraction: closeDampingFraction)
        let distance = Double((opening ? 1 : 0) - progress)
        let relative = abs(distance) > 0.001 ? velocity / distance : 0
        return .interpolatingSpring(
            mass: 1,
            stiffness: coefficients.stiffness,
            damping: coefficients.damping,
            initialVelocity: relative
        )
    }

    /// Past either end the drag stretches with resistance (the mock's rubber band); it never goes above 0.
    public static func rubberBand(_ raw: CGFloat) -> CGFloat {
        if raw > 1 {
            let over = raw - 1
            return 1 + over / (1 + over * 4) * 0.35
        }
        return max(0, raw)
    }

    /// Where a released drag settles: a flick goes the way it was thrown, anything slower to the nearer end.
    public static func releaseTarget(progress: CGFloat, velocity: Double) -> Bool {
        if velocity > flickVelocity { return true }
        if velocity < -flickVelocity { return false }
        return progress > 0.5
    }
}

/// The drag-versus-click disambiguation and drag-follow for pulling History down from the notch
/// (formal/history-pull, `HistoryPull.tla`). A press on the band (or on the open panel's bottom edge) is
/// pending until it moves `dragSlop`; only then does it become a drag that owns the progress. A press that
/// never moves is a click, and a click never moves the panel. A drag ends exactly once, on release or on
/// cancel, and hands the panel to a spring.
public struct NotchHistoryPull: Equatable {
    public enum Phase: Equatable {
        case idle
        /// Pressed, not yet moved past the slop: still possibly a click.
        case pending(startY: CGFloat, startProgress: CGFloat)
        /// Moved past the slop: the panel follows the pointer.
        case dragging(startY: CGFloat, startProgress: CGFloat)
    }

    public enum Release: Equatable {
        /// The press never moved: a click. The panel is left exactly as it was.
        case click
        /// A drag ended: spring to `open` with this release velocity (progress per second).
        case settle(open: Bool, velocity: Double)
        /// Nothing was pressed (a stray release).
        case none
    }

    public private(set) var phase: Phase = .idle
    public private(set) var velocity: Double = 0
    private var lastY: CGFloat = 0
    private var lastTime: TimeInterval = 0

    public init() {}

    public var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    /// Whether a press at `y` (points from the top of the screen) may start an open/close pull: on the band.
    /// Pulling the band up closes the panel; the panel's bottom edge belongs to the extend handle.
    public static func accepts(y: CGFloat) -> Bool {
        y <= NotchHistoryMorph.pullBandHeight
    }

    /// Whether a press at `point` lands on the open panel's extend handle: its band under the last row, within
    /// `handleHitWidth` of the panel's centre `centreX`. `panelHeight` is the open panel from the top of the screen.
    public static func acceptsHandle(point: CGPoint, centreX: CGFloat, panelHeight: CGFloat, progress: CGFloat) -> Bool {
        guard progress > 0.98 else { return false }
        let bandTop = panelHeight - NotchHistoryMorph.handleBandHeight
        return abs(point.x - centreX) <= NotchHistoryMorph.handleHitWidth / 2
            && point.y >= bandTop - 2 && point.y <= panelHeight + 4
    }

    /// A press. Ignored while another press is in progress (one pointer owns the pull).
    public mutating func press(y: CGFloat, progress: CGFloat, time: TimeInterval) {
        guard case .idle = phase else { return }
        phase = .pending(startY: y, startProgress: progress)
        velocity = 0
        lastY = y
        lastTime = time
    }

    /// The pointer moved. Returns the value the panel should show (`band` stretches it past its ends), or nil while
    /// this is not a drag. `range` is how far the pointer travels per unit of value.
    public mutating func move(
        y: CGFloat, time: TimeInterval, range: CGFloat,
        band: (CGFloat) -> CGFloat = NotchHistoryMorph.rubberBand
    ) -> CGFloat? {
        switch phase {
        case .idle:
            return nil
        case let .pending(startY, startProgress):
            guard abs(y - startY) > NotchHistoryMorph.dragSlop else { return nil }
            phase = .dragging(startY: startY, startProgress: startProgress)
            return band(track(y: y, time: time, range: range, startY: startY, startProgress: startProgress))
        case let .dragging(startY, startProgress):
            return band(track(y: y, time: time, range: range, startY: startY, startProgress: startProgress))
        }
    }

    private mutating func track(
        y: CGFloat, time: TimeInterval, range: CGFloat, startY: CGFloat, startProgress: CGFloat
    ) -> CGFloat {
        let span = max(1, range)
        let dt = max(0.001, time - lastTime)
        // The mock's smoothing: mostly the latest sample, a little of the previous velocity.
        velocity = 0.7 * Double((y - lastY) / span) / dt + 0.3 * velocity
        lastY = y
        lastTime = time
        return startProgress + (y - startY) / span
    }

    /// The press ended (or was cancelled: then a drag still settles, at the nearer end).
    public mutating func release(progress: CGFloat, cancelled: Bool = false) -> Release {
        defer {
            phase = .idle
        }
        switch phase {
        case .idle:
            return .none
        case .pending:
            return .click
        case .dragging:
            let speed = cancelled ? 0 : min(
                NotchHistoryMorph.maximumReleaseVelocity,
                max(-NotchHistoryMorph.maximumReleaseVelocity, velocity)
            )
            return .settle(open: NotchHistoryMorph.releaseTarget(progress: progress, velocity: speed), velocity: speed)
        }
    }
}

/// The rows' half of morph B, driven by the same animated progress as the shell, so the two can never drift.
struct NotchHistoryRowsMorph: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let blur = NotchHistoryMorph.rowsBlur(progress: progress)
        content
            .scaleEffect(NotchHistoryMorph.rowsScale(progress: progress), anchor: .top)
            .blur(radius: blur, opaque: false)
            .opacity(NotchHistoryMorph.rowsOpacity(progress: progress))
            .allowsHitTesting(progress > 0.98)
    }
}
