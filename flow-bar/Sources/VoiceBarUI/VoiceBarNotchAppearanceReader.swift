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

public final class VoiceBarEffectiveAppearanceView: NSView {
    var onAppearanceChange: ((VoiceBarNotchAppearance) -> Void)?
    private var tracker = VoiceBarNotchAppearanceTracker(initial: .dark)

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportEffectiveAppearance()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reportEffectiveAppearance()
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func reportEffectiveAppearance() {
        tracker.receive(effectiveAppearance: effectiveAppearance)
        onAppearanceChange?(tracker.appearance)
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
        DispatchQueue.main.async {
            view.reportEffectiveAppearance()
        }
        return view
    }

    public func updateNSView(_ view: VoiceBarEffectiveAppearanceView, context: Context) {
        installReporter(on: view)
    }

    private func installReporter(on view: VoiceBarEffectiveAppearanceView) {
        let appearance = $appearance
        view.onAppearanceChange = { next in
            guard appearance.wrappedValue != next else { return }
            DispatchQueue.main.async {
                appearance.wrappedValue = next
            }
        }
    }
}
