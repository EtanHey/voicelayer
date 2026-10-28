import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
struct GlassTextCapability {
    nonisolated static let contrastFloor = 64
    static let current: Result<GlassTextCapability, Error> = Result { try probe() }

    let contrast: Int
    let macOSVersion: String

    var isReadable: Bool { contrast >= Self.contrastFloor }

    func requireReadableText() throws {
        guard isReadable else {
            throw XCTSkip("GLASS TEXT COVERAGE SKIPPED: macOS \(macOSVersion), measured contrast \(contrast), "
                + "floor \(Self.contrastFloor); native glass content is dim in cacheDisplay. "
                + "Glass-text readability is NOT enforced on this host.")
        }
    }

    private static func probe() throws -> GlassTextCapability {
        let size = CGSize(width: 240, height: 64)
        let host = NSHostingView(rootView:
            Text("Glass sample")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .modifier(VoiceBarGlassMaterial(shape: Rectangle(), appearance: .dark))
                .environment(\.colorScheme, .dark)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let scale = CGFloat(image.width) / size.width
        let crop = try XCTUnwrap(image.cropping(to: CGRect(
            x: 12 * scale, y: 12 * scale, width: 216 * scale, height: 40 * scale)))
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var minimum = 255, maximum = 0
        for pixel in 0 ..< crop.width * crop.height {
            let offset = pixel * 4
            let luminance = (54 * Int(bytes[offset]) + 183 * Int(bytes[offset + 1])
                + 19 * Int(bytes[offset + 2])) / 256
            minimum = min(minimum, luminance)
            maximum = max(maximum, luminance)
        }
        let capability = GlassTextCapability(contrast: maximum - minimum,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        print("GLASS TEXT CAPABILITY: macOS \(capability.macOSVersion), measured contrast \(capability.contrast), "
            + "floor \(contrastFloor), readability \(capability.isReadable ? "ENFORCED" : "SKIPPED")")
        return capability
    }
}
