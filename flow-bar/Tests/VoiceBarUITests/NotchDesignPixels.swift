import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision

@testable import VoiceBarUI
import XCTest

@MainActor enum NotchDesignPixels {
    static func render(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return try EtanQA0510Tests.fixedScaleBitmap(host)
    }
    static func inkBounds(_ bitmap: NSBitmapImageRep, rect: CGRect) -> CGRect? {
        var bounds: CGRect?
        for y in max(0, Int(rect.minY*2))..<min(bitmap.pixelsHigh, Int(rect.maxY*2)) {
            for x in max(0, Int(rect.minX*2))..<min(bitmap.pixelsWide, Int(rect.maxX*2)) {
                guard let c = bitmap.colorAt(x: x, y: y), c.redComponent > 0.4,
                      abs(c.redComponent-c.greenComponent)<0.1 else { continue }
                let pixel = CGRect(x: CGFloat(x)/2, y: CGFloat(y)/2, width: 0.5, height: 0.5)
                bounds = bounds.map { $0.union(pixel) } ?? pixel
            }
        }
        return bounds
    }
}
