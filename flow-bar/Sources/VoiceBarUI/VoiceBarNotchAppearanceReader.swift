import AppKit
import SwiftUI

private struct VoiceBarNotchAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue = VoiceBarNotchAppearance.dark
}

public extension EnvironmentValues {
    var voiceBarNotchAppearance: VoiceBarNotchAppearance {
        get { self[VoiceBarNotchAppearanceEnvironmentKey.self] }
        set { self[VoiceBarNotchAppearanceEnvironmentKey.self] = newValue }
    }
}

enum VoiceBarNotchAppearanceDelivery {
    static func publish(
        _ next: VoiceBarNotchAppearance,
        to appearance: Binding<VoiceBarNotchAppearance>
    ) {
        guard appearance.wrappedValue != next else { return }
        appearance.wrappedValue = next
    }
}

public final class VoiceBarEffectiveAppearanceView: NSView {
    var onAppearanceChange: ((VoiceBarNotchAppearance) -> Void)?
    var effectiveAppearanceProvider: (() -> NSAppearance)?
    private var tracker = VoiceBarNotchAppearanceTracker(initial: .dark)
    private var settledAppearanceTask: Task<Void, Never>?

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        handleEffectiveAppearanceChange()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        handleEffectiveAppearanceChange()
    }

    func handleEffectiveAppearanceChange() {
        reportEffectiveAppearance()
        scheduleSettledAppearanceRead()
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func reportEffectiveAppearance() {
        tracker.receive(
            effectiveAppearance: effectiveAppearanceProvider?() ?? effectiveAppearance
        )
        onAppearanceChange?(tracker.appearance)
    }

    private func scheduleSettledAppearanceRead() {
        settledAppearanceTask?.cancel()
        settledAppearanceTask = Task { @MainActor [weak self] in
            // AppKit can invoke viewDidChangeEffectiveAppearance while the
            // view still exposes the outgoing appearance. Re-read after the
            // current main-actor turn so a live Light↔Dark toggle cannot leave
            // the compact wings one event behind.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.reportEffectiveAppearance()
        }
    }
}

public struct VoiceBarNotchAppearanceReader: NSViewRepresentable {
    @Binding private var appearance: VoiceBarNotchAppearance

    public init(appearance: Binding<VoiceBarNotchAppearance>) {
        _appearance = appearance
    }

    public func makeNSView(context: Context) -> VoiceBarEffectiveAppearanceView {
        let view = VoiceBarEffectiveAppearanceView(frame: .zero)
        installReporter(on: view)
        return view
    }

    public func updateNSView(_ view: VoiceBarEffectiveAppearanceView, context: Context) {
        installReporter(on: view)
    }

    private func installReporter(on view: VoiceBarEffectiveAppearanceView) {
        let appearance = $appearance
        view.onAppearanceChange = { next in
            VoiceBarNotchAppearanceDelivery.publish(next, to: appearance)
        }
    }
}
