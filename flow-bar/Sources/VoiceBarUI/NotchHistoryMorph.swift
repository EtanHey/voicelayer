import CoreGraphics
import Foundation
import SwiftUI

/// VoiceBar 2.3 lane U4: History morph B, exactly as Etan chose it in the approved mock (2-morph.html,
/// 5-history.html; "the best we've ever done", 2026-11-03). One progress value `p` drives everything:
/// p = 0 is the closed launcher, p = 1 the open panel. The shell's size follows `p` unclamped (the open
/// spring may overshoot a hair), the radii follow it clamped, and the rows come out of the notch with it.
/// 2.4 Lane A made the motion one stage: one spring, the rows' opacity following `p`.
/// Every morph is a spring on `p`, so a new target retargets from the current position and velocity and
/// the morph reverses from wherever it is.
public enum NotchHistoryMorph {
    // MARK: Spring (2.4 Lane A, Etan: "simplify the History pull animation: one spring, no multi-stage")

    /// THE spring: opening, closing, a released pull, the extend handle settling and the History/Settings drawer
    /// swap all ride it. Critically damped: it lands without a bounce and reverses cleanly from wherever it is.
    public static let springResponse: Double = 0.4
    public static let springDampingFraction: Double = 1.0
    public static let openResponse: Double = springResponse
    public static let openDampingFraction: Double = springDampingFraction
    public static let closeResponse: Double = springResponse
    public static let closeDampingFraction: Double = springDampingFraction

    // MARK: Radii

    /// The open panel's concave top flare where it meets the menu bar, and its convex bottom corners.
    public static let openTopRadius: CGFloat = 19
    public static let openBottomRadius: CGFloat = 24

    // MARK: Rows

    /// One stage: the rows' opacity follows the shell's progress, with no scale, no blur pass and no delayed fade.
    public static let rowsStartScale: CGFloat = 1
    public static let rowsStartBlur: CGFloat = 0
    public static let rowsFadeStart: CGFloat = 0

    // MARK: Panel (2.4 Lane A, Etan: "collapsed 6, expanded 8, scrolls to 20")

    public static let bodyWidth: CGFloat = 420
    public static let rowHeight: CGFloat = 46
    /// The collapsed detent.
    public static let visibleRows = 6
    /// The expanded detent: the extend handle settles on 6 or 8, never between.
    public static let maximumRows = 8
    /// How many dictations the list holds; past the visible rows it scrolls.
    public static let maximumEntries = 20
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
    public static let pullResponse: Double = springResponse
    public static let pullDampingFraction: Double = springDampingFraction

    /// History's window below the 32 pt band: seven rows plus the transient-note reserve, or the 12-row panel,
    /// whichever is taller (578 pt; the window stays 610 pt, inside the 640 pt narrow-display guard). An extended
    /// panel and a note share this space; the shell never draws past it.
    public static var historyCanvasLowerSurfaceHeight: CGFloat {
        max(lowerSurfaceHeight(rows: CGFloat(visibleRows)) + VoiceBarNotchContract.transientNoteCanvasReserve,
            lowerSurfaceHeight(rows: CGFloat(maximumRows)))
    }

    /// How far the handle may extend: never past the rows there are to show (no empty rows), never past 8.
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

    /// 2.4 Lane A: a handle released this far above the collapsed rows (1.25 rows, about 58 pt) closes History.
    public static let handleCloseRows: CGFloat = CGFloat(visibleRows) - 1.25

    public static func handleClosesHistory(rawRows: CGFloat) -> Bool {
        rawRows > 0 && rawRows <= handleCloseRows
    }

    /// Where a released handle settles: the nearer detent (6 collapsed, or the expanded rows), never between.
    public static func snappedRows(_ rows: CGFloat, maximum: Int) -> Int {
        let expanded = max(visibleRows, min(maximumRows, maximum))
        return NotchHistoryDetent.nearest(rows: rows) == .expanded ? expanded : visibleRows
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
    /// 2.4 Lane A: a pull that goes this far past open (in progress units, before the rubber band; about 90 pt on
    /// the collapsed panel) arms Settings, and releasing it there opens the Settings drawer.
    public static let settingsPullThreshold: CGFloat = 1.3
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
        clamp(p)
    }

    public static func rowsScale(progress _: CGFloat) -> CGFloat {
        1
    }

    /// No blur, ever: one stage, and no render pass for it.
    public static func rowsBlur(progress _: CGFloat) -> CGFloat {
        0
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

/// A spring in flight, as mass-1 physics: where SwiftUI is drawing it right now. SwiftUI never reports an in-flight
/// value (the model already holds the target), so a press that grabs a moving panel reads it from here and the panel
/// stays under the pointer instead of jumping to where the spring was headed (Codex review R1).
/// The one clock History's springs and pointer samples share: monotonic (system uptime), the base NSEvent and
/// SwiftUI gesture timestamps already use. A flight started on wall-clock Date() and read at a gesture's time
/// clamped to its start, so a fully open panel read as progress 0 and refused the extend handle (2.3 U4 native, M1).
public enum NotchHistoryClock {
    public static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public struct NotchHistorySpringFlight: Equatable {
    public let from: CGFloat
    public let to: CGFloat
    /// In value units per second at `start`.
    public let velocity: Double
    public let start: TimeInterval
    public let stiffness: Double
    public let damping: Double

    public init(from: CGFloat, to: CGFloat, velocity: Double, start: TimeInterval,
                response: Double, dampingFraction: Double) {
        let coefficients = NotchHistoryMorph.springCoefficients(response: response, dampingFraction: dampingFraction)
        self.from = from
        self.to = to
        self.velocity = velocity
        self.start = start
        self.stiffness = coefficients.stiffness
        self.damping = coefficients.damping
    }

    /// Displacement from `to` and its velocity `t` seconds in (x'' = -k x - c x', x(0) = from - to, x'(0) = velocity).
    private func state(_ t: Double) -> (x: Double, v: Double) {
        let a = Double(from - to), v0 = velocity
        let omega = stiffness.squareRoot(), zeta = damping / (2 * omega)
        if abs(zeta - 1) < 1e-6 {
            let b = v0 + omega * a, e = exp(-omega * t)
            return ((a + b * t) * e, (b - omega * (a + b * t)) * e)
        }
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot(), decay = zeta * omega
            let b = (v0 + decay * a) / wd, e = exp(-decay * t)
            let x = e * (a * cos(wd * t) + b * sin(wd * t))
            let v = e * ((b * wd - decay * a) * cos(wd * t) - (a * wd + decay * b) * sin(wd * t))
            return (x, v)
        }
        let root = (zeta * zeta - 1).squareRoot()
        let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
        let c2 = (v0 - r1 * a) / (r2 - r1), c1 = a - c2
        return (c1 * exp(r1 * t) + c2 * exp(r2 * t), c1 * r1 * exp(r1 * t) + c2 * r2 * exp(r2 * t))
    }

    public func value(at time: TimeInterval) -> CGFloat {
        to + CGFloat(state(max(0, time - start)).x)
    }

    public func velocity(at time: TimeInterval) -> Double {
        state(max(0, time - start)).v
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
    /// Where the pointer has the value, before the rubber band: past 1 it measures how far the pull went beyond
    /// open (2.4: far enough arms Settings). 0 while not dragging.
    public private(set) var rawProgress: CGFloat = 0
    private var lastY: CGFloat = 0
    private var lastTime: TimeInterval = 0
    /// A seed the band can't express (a spring overshooting past 1 or under 0) is carried as an offset on every
    /// sample, so the grab never moves what is drawn (Codex review R2). 0 for an in-range seed.
    private var seedOffset: CGFloat = 0

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
        seedOffset = 0
        velocity = 0
        lastY = y
        lastTime = time
    }

    /// The pointer moved. Returns the value the panel should show (`band` stretches it past its ends), or nil while
    /// this is not a drag. `range` is how far the pointer travels per unit of value.
    /// `seed` is what the panel shows at the moment the press becomes a drag (a spring may have moved it since the
    /// press): the drag continues from there, from this pointer position, so nothing jumps.
    public mutating func move(
        y: CGFloat, time: TimeInterval, range: CGFloat,
        band: (CGFloat) -> CGFloat = NotchHistoryMorph.rubberBand, seed: CGFloat? = nil
    ) -> CGFloat? {
        switch phase {
        case .idle:
            return nil
        case let .pending(startY, startProgress):
            guard abs(y - startY) > NotchHistoryMorph.dragSlop else { return nil }
            if let seed {
                phase = .dragging(startY: y, startProgress: seed)
                lastY = y
                lastTime = time
                seedOffset = seed - band(seed)
                rawProgress = seed
                return seed
            }
            phase = .dragging(startY: startY, startProgress: startProgress)
            return band(track(y: y, time: time, range: range, startY: startY, startProgress: startProgress))
        case let .dragging(startY, startProgress):
            return band(track(y: y, time: time, range: range, startY: startY, startProgress: startProgress)) + seedOffset
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
        rawProgress = startProgress + (y - startY) / span
        return rawProgress
    }

    /// The press ended (or was cancelled: then a drag still settles, at the nearer end).
    public mutating func release(progress: CGFloat, cancelled: Bool = false) -> Release {
        defer {
            phase = .idle
            rawProgress = 0
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
        content
            .opacity(NotchHistoryMorph.rowsOpacity(progress: progress))
            .allowsHitTesting(progress > 0.98)
    }
}
