import SwiftUI

public struct VoiceBarNotchViewDescriptor: Equatable {
    public let shellIdentity: String
    public let fixedCoreCount: Int
    public let reusableWingSlotCount: Int
    public let lowerSurfaceCount: Int
    public let clipsContentToVisibleSurfaces: Bool
    public let coreUsesMaterial: Bool
    public let accessibilityLabel: String

    public static func resolve(
        presentation: VoiceBarNotchPresentation
    ) -> VoiceBarNotchViewDescriptor {
        VoiceBarNotchViewDescriptor(
            shellIdentity: "VoiceBarNotchShell",
            fixedCoreCount: 1,
            reusableWingSlotCount: 2,
            lowerSurfaceCount: presentation.geometry.lowerSurfaceHeight > 0 ? 1 : 0,
            clipsContentToVisibleSurfaces: true,
            coreUsesMaterial: VoiceBarNotchContract.material.coreUsesBackdropMaterial,
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}

public struct VoiceBarNotchView<LeadingContent: View, TrailingContent: View, LowerContent: View>: View {
    public let presentation: VoiceBarNotchPresentation
    private let leadingContent: LeadingContent
    private let trailingContent: TrailingContent
    private let lowerContent: LowerContent
    private let onHoverChanged: (Bool) -> Void

    public init(
        presentation: VoiceBarNotchPresentation,
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder leadingContent: () -> LeadingContent,
        @ViewBuilder trailingContent: () -> TrailingContent,
        @ViewBuilder lowerContent: () -> LowerContent
    ) {
        self.presentation = presentation
        self.onHoverChanged = onHoverChanged
        self.leadingContent = leadingContent()
        self.trailingContent = trailingContent()
        self.lowerContent = lowerContent()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if presentation.visualState == .teleprompter {
                teleprompterSurface
                teleprompterSlots
            } else {
                compactWings
            }

            fixedHardwareCore
        }
        .frame(
            width: presentation.geometry.totalWidth,
            height: presentation.geometry.totalHeight,
            alignment: .topLeading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .onHover(perform: onHoverChanged)
    }

    private var layout: VoiceBarNotchShapeLayout {
        VoiceBarNotchShapeLayout(geometry: presentation.geometry)
    }

    private var fixedHardwareCore: some View {
        Rectangle()
            .fill(.black)
            .frame(width: layout.coreRect.width, height: layout.coreRect.height)
            .position(x: layout.coreRect.midX, y: layout.coreRect.midY)
            .accessibilityHidden(true)
            .transaction { transaction in
                transaction.animation = nil
            }
            .zIndex(10)
    }

    private var compactWings: some View {
        VoiceBarGlassContainer {
            ZStack(alignment: .topLeading) {
                if layout.leadingWingRect.width > 0 {
                    VoiceBarGlassWing(side: .leading) {
                        wingSlot(leadingContent, side: .leading)
                    }
                    .frame(
                        width: layout.leadingWingRect.width,
                        height: layout.leadingWingRect.height
                    )
                    .position(
                        x: layout.leadingWingRect.midX,
                        y: layout.leadingWingRect.midY
                    )
                }

                if layout.trailingWingRect.width > 0 {
                    VoiceBarGlassWing(side: .trailing) {
                        wingSlot(trailingContent, side: .trailing)
                    }
                    .frame(
                        width: layout.trailingWingRect.width,
                        height: layout.trailingWingRect.height
                    )
                    .position(
                        x: layout.trailingWingRect.midX,
                        y: layout.trailingWingRect.midY
                    )
                }
            }
            .frame(
                width: presentation.geometry.totalWidth,
                height: presentation.geometry.topHeight,
                alignment: .topLeading
            )
        }
    }

    private var teleprompterSurface: some View {
        Color.clear
            .frame(
                width: presentation.geometry.totalWidth,
                height: presentation.geometry.totalHeight
            )
            .modifier(
                VoiceBarGlassMaterial(
                    shape: VoiceBarNotchContinuousShape(
                        geometry: presentation.geometry
                    )
                )
            )
            .allowsHitTesting(false)
    }

    private var teleprompterSlots: some View {
        ZStack(alignment: .topLeading) {
            wingSlot(leadingContent, side: .leading)
                .frame(
                    width: layout.leadingWingRect.width,
                    height: layout.leadingWingRect.height
                )
                .position(
                    x: layout.leadingWingRect.midX,
                    y: layout.leadingWingRect.midY
                )

            wingSlot(trailingContent, side: .trailing)
                .frame(
                    width: layout.trailingWingRect.width,
                    height: layout.trailingWingRect.height
                )
                .position(
                    x: layout.trailingWingRect.midX,
                    y: layout.trailingWingRect.midY
                )

            lowerContent
                .frame(
                    width: layout.bodyRect.width,
                    height: layout.bodyRect.height
                )
                .clipped()
                .position(
                    x: layout.bodyRect.midX,
                    y: layout.bodyRect.midY
                )
        }
    }

    private func wingSlot(
        _ content: some View,
        side: VoiceBarNotchSide
    ) -> some View {
        content
            .padding(contentInsets(for: side))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private func contentInsets(for side: VoiceBarNotchSide) -> EdgeInsets {
        let material = VoiceBarNotchContract.material
        let coreInset = material.blackToGlassFadeWidth + material.fadeToContentGap
        return switch side {
        case .leading:
            EdgeInsets(
                top: 0,
                leading: material.outerContentInset,
                bottom: 0,
                trailing: coreInset
            )
        case .trailing:
            EdgeInsets(
                top: 0,
                leading: coreInset,
                bottom: 0,
                trailing: material.outerContentInset
            )
        }
    }
}
