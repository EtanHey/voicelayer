import AppKit
import SwiftUI

public enum VoiceBarNotchGlassTopology: Equatable {
    case directContinuousSurface
}

public enum VoiceBarNotchMaterialStrategy: Equatable {
    case nativeGlass
    case visualEffectMaterial
    case opaque

    public static func resolve(
        nativeGlassAvailable: Bool,
        visualEffectAvailable: Bool
    ) -> VoiceBarNotchMaterialStrategy {
        if nativeGlassAvailable {
            .nativeGlass
        } else if visualEffectAvailable {
            .visualEffectMaterial
        } else {
            .opaque
        }
    }
}

public enum VoiceBarNotchNativeGlassHost: Equatable {
    case appKitGlassEffectView
}

public struct VoiceBarNotchMaterialDescriptor: Equatable {
    public let topology: VoiceBarNotchGlassTopology
    public let surfaceCount: Int
    public let insetFrameCount: Int
    public let usesFilledBackdropMaterial: Bool
    public let hasOuterTopAndBottomEdgeTreatment: Bool
    public let usesTransparentBorderOnlyShell: Bool

    public static func resolve(
        for state: VoiceBarNotchVisualState
    ) -> VoiceBarNotchMaterialDescriptor {
        switch state {
        case .idle:
            continuous(surfaceCount: 0)
        case .hoverLauncher, .recording, .compactStatus:
            continuous(surfaceCount: 1)
        case .teleprompter:
            continuous(surfaceCount: VoiceBarNotchContract.material.lowerSurfaceLayerCount)
        }
    }

    private static func continuous(surfaceCount: Int) -> VoiceBarNotchMaterialDescriptor {
        VoiceBarNotchMaterialDescriptor(
            topology: .directContinuousSurface,
            surfaceCount: surfaceCount,
            insetFrameCount: VoiceBarNotchContract.material.teleprompterInsetFrameCount,
            usesFilledBackdropMaterial: surfaceCount > 0,
            hasOuterTopAndBottomEdgeTreatment: VoiceBarNotchContract.material.compactWingsHaveOuterEdgeTreatment,
            usesTransparentBorderOnlyShell: false
        )
    }
}

public struct VoiceBarNotchGlassRecipe: Equatable {
    public let tint: VoiceBarRGBA
    public let nativeOverlay: VoiceBarRGBA?
    public let fallbackOverlay: VoiceBarRGBA
    public let nativeHost: VoiceBarNotchNativeGlassHost

    public static func resolve(for _: VoiceBarNotchAppearance) -> Self {
        VoiceBarNotchGlassRecipe(
            tint: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06),
            nativeOverlay: nil,
            fallbackOverlay: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06),
            nativeHost: .appKitGlassEffectView
        )
    }
}

/// Keeps one native-glass ownership boundary stable while the notch geometry
/// changes between compact wing subpaths and the connected teleprompter body.
public struct VoiceBarGlassContainer<Content: View>: View {
    public let variant: VoiceBarNotchMorphVariant
    private let content: Content
    @Namespace private var nativeGlassNamespace

    public init(
        variant: VoiceBarNotchMorphVariant = .p1Matched,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *),
           variant.descriptor(
               nativeGlassAvailable: true,
               reducedMotion: false
           ).usesNativeGlassContainer {
            let descriptor = variant.descriptor(
                nativeGlassAvailable: true,
                reducedMotion: false
            )
            GlassEffectContainer(spacing: descriptor.nativeGlassSpacing) {
                content
                    .glassEffectID(
                        VoiceBarNotchMorphVariant.sharedGlassID,
                        in: nativeGlassNamespace
                    )
            }
        } else {
            content
        }
    }
}

/// Shared filled material primitive for the persistent notch surface. It
/// deliberately never wraps the black hardware core.
public struct VoiceBarGlassMaterial<SurfaceShape: Shape>: ViewModifier {
    public let shape: SurfaceShape
    public let appearance: VoiceBarNotchAppearance
    public let forceOpaqueFallback: Bool
    public let morphVariant: VoiceBarNotchMorphVariant

    public init(
        shape: SurfaceShape,
        appearance: VoiceBarNotchAppearance = .dark,
        forceOpaqueFallback: Bool = false,
        morphVariant: VoiceBarNotchMorphVariant = .p1Matched
    ) {
        self.shape = shape
        self.appearance = appearance
        self.forceOpaqueFallback = forceOpaqueFallback
        self.morphVariant = morphVariant
    }

    public func body(content: Content) -> some View {
        materialBody(content: content.clipShape(shape))
            .overlay {
                shape.stroke(.white.opacity(0.14), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .stroke(.black.opacity(0.10), lineWidth: 1)
                    .blur(radius: 0.35)
                    .offset(y: 0.5)
                    .mask(shape)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func materialBody(content: some View) -> some View {
        let recipe = VoiceBarNotchGlassRecipe.resolve(for: appearance)
        if forceOpaqueFallback {
            content.background {
                shape.fill(
                    appearance == .dark
                        ? Color.black.opacity(0.88)
                        : Color.white.opacity(0.84)
                )
            }
        } else if #available(macOS 26.0, *) {
            VoiceBarAppKitGlassHost(
                shape: shape,
                tint: recipe.tint,
                useNativeContainer: nativeContainerEnabled,
                containerSpacing: nativeContainerSpacing
            ) {
                content
            }
            .id(morphVariant.rawValue)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background {
                    shape.fill(recipe.fallbackOverlay.color)
                        .allowsHitTesting(false)
                }
        }
    }

    private var nativeContainerSpacing: CGFloat {
        morphVariant.descriptor(
            nativeGlassAvailable: true,
            reducedMotion: false
        ).nativeGlassSpacing
    }

    private var nativeContainerEnabled: Bool {
        morphVariant.descriptor(
            nativeGlassAvailable: true,
            reducedMotion: false
        ).usesNativeGlassContainer
    }
}

@available(macOS 26.0, *)
private struct VoiceBarAppKitGlassHost<SurfaceShape: Shape, HostedContent: View>: NSViewRepresentable {
    let shape: SurfaceShape
    let tint: VoiceBarRGBA
    let useNativeContainer: Bool
    let containerSpacing: CGFloat
    @ViewBuilder let content: HostedContent

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> NSView {
        let glassView = VoiceBarTrackedGlassEffectView()
        glassView.style = .regular
        glassView.cornerRadius = 0

        let hostingView = context.coordinator.hostingView
        hostingView.frame = glassView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        glassView.contentView = hostingView
        configure(glassView, context: context)

        if useNativeContainer {
            let containerView = VoiceBarTrackedGlassContainerView(glassView: glassView)
            containerView.spacing = containerSpacing
            return containerView
        }
        return glassView
    }

    func updateNSView(_ rootView: NSView, context: Context) {
        context.coordinator.hostingView.rootView = content
        if let containerView = rootView as? VoiceBarTrackedGlassContainerView {
            containerView.spacing = containerSpacing
            configure(containerView.glassView, context: context)
        } else if let glassView = rootView as? VoiceBarTrackedGlassEffectView {
            configure(glassView, context: context)
        }
    }

    private func configure(
        _ glassView: VoiceBarTrackedGlassEffectView,
        context _: Context
    ) {
        glassView.tintColor = NSColor(
            srgbRed: tint.red,
            green: tint.green,
            blue: tint.blue,
            alpha: tint.alpha
        )
        glassView.maskPathProvider = { rect in
            shape.path(in: rect).cgPath
        }
        glassView.needsLayout = true
    }

    final class Coordinator {
        let hostingView: NSHostingView<HostedContent>

        init(content: HostedContent) {
            hostingView = NSHostingView(rootView: content)
        }
    }
}

@available(macOS 26.0, *)
private final class VoiceBarTrackedGlassContainerView: NSGlassEffectContainerView {
    let glassView: VoiceBarTrackedGlassEffectView

    init(glassView: VoiceBarTrackedGlassEffectView) {
        self.glassView = glassView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        contentView = glassView
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = .clear
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
    }
}

@available(macOS 26.0, *)
private final class VoiceBarTrackedGlassEffectView: NSGlassEffectView {
    var maskPathProvider: ((CGRect) -> CGPath)?

    private let glassMaskLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.mask = glassMaskLayer
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func animation(forKey _: NSAnimatablePropertyKey) -> Any? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = .clear
    }

    override func layout() {
        super.layout()
        contentView?.frame = bounds
        updateGlassMask()
    }

    private func updateGlassMask() {
        guard let path = maskPathProvider?(bounds) else {
            glassMaskLayer.path = nil
            return
        }
        var transform = CGAffineTransform(translationX: 0, y: bounds.height)
        transform = transform.scaledBy(x: 1, y: -1)
        glassMaskLayer.frame = bounds
        glassMaskLayer.path = path.copy(using: &transform)
        glassMaskLayer.fillColor = NSColor.black.cgColor
    }
}
