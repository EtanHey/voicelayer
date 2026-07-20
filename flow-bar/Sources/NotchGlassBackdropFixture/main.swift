import AppKit
import Foundation

private enum FixtureMode: String {
    case busy
    case black
    case bright
}

private final class BackdropView: NSView {
    let mode: FixtureMode

    init(mode: FixtureMode, frame: CGRect) {
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch mode {
        case .black:
            NSColor.black.setFill()
            bounds.fill()
        case .bright:
            drawBrightChecker()
        case .busy:
            drawBusyTerminal()
        }
    }

    private func drawBrightChecker() {
        let colors = [
            NSColor(srgbRed: 0.82, green: 0.82, blue: 0.82, alpha: 1),
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let cellSize: CGFloat = 12
        for row in 0 ... Int(ceil(bounds.height / cellSize)) {
            for column in 0 ... Int(ceil(bounds.width / cellSize)) {
                colors[(row + column).isMultiple(of: 2) ? 0 : 1].setFill()
                NSRect(
                    x: CGFloat(column) * cellSize,
                    y: CGFloat(row) * cellSize,
                    width: cellSize,
                    height: cellSize
                ).fill()
            }
        }
    }

    private func drawBusyTerminal() {
        NSColor(srgbRed: 0.025, green: 0.035, blue: 0.055, alpha: 1).setFill()
        bounds.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let rows = [
            "01:34:20 renderer  glass sample alpha=0.53 backing=terminal",
            "swift test --filter VoiceBarNotchCaptureAuditTests   PASS",
            "0x7ff92a  GLASS-CONTINUITY  panel -> wing -> compact",
            "export QA_VOICE_SOCKET_PATH=/tmp/isolated/notch.sock",
            "[trace] waveform=[0.18 0.42 0.73 1.00 0.72 0.41 0.17]",
            "main 5febd6a  #360 busy backdrop readability regression",
            "ABCDEFGHIJKLMNOPQRSTUVXYZ 0123456789 !@#$%^&*()",
            "frosting must destroy these high-frequency terminal edges",
        ]
        let colors = [
            NSColor(srgbRed: 0.42, green: 0.82, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.55, green: 1.00, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.78, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.94, green: 0.94, blue: 0.97, alpha: 1),
        ]
        for row in 0 ..< 20 {
            let text = rows[row % rows.count]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colors[row % colors.count],
            ]
            text.draw(
                at: CGPoint(x: CGFloat((row % 3) * 7), y: CGFloat(row) * 18),
                withAttributes: attributes
            )
        }
    }
}

private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let mode: FixtureMode
    let readyReceiptPath: String
    private var panel: NSPanel?

    init(mode: FixtureMode, readyReceiptPath: String) {
        self.mode = mode
        self.readyReceiptPath = readyReceiptPath
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard let screen = NSScreen.main else {
            fputs("NotchGlassBackdropFixture: no main screen\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let fixtureSize = CGSize(width: 700, height: 360)
        let frame = CGRect(
            x: screen.visibleFrame.minX,
            y: screen.visibleFrame.minY,
            width: fixtureSize.width,
            height: fixtureSize.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = true
        panel.hasShadow = false
        panel.appearance = NSAppearance(
            named: mode == .bright ? .aqua : .darkAqua
        )

        let backdrop = BackdropView(mode: mode, frame: CGRect(origin: .zero, size: fixtureSize))
        let reference = NSImageView(frame: CGRect(x: 590, y: 34, width: 28, height: 28))
        reference.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "Native microphone reference"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        )
        reference.imageScaling = .scaleProportionallyUpOrDown
        reference.contentTintColor = .labelColor
        backdrop.addSubview(reference)
        panel.contentView = backdrop
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [readyReceiptPath, mode] in
            let receipt: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "mode": mode.rawValue,
                "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height],
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: readyReceiptPath), options: .atomic)
            } catch {
                fputs("NotchGlassBackdropFixture receipt error: \(error)\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }
}

private func argument(named name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let modeValue = argument(named: "--mode"),
      let mode = FixtureMode(rawValue: modeValue),
      let readyReceiptPath = argument(named: "--ready-receipt")
else {
    fputs(
        "usage: NotchGlassBackdropFixture --mode busy|black|bright --ready-receipt <json>\n",
        stderr
    )
    exit(2)
}

let app = NSApplication.shared
private let delegate = FixtureDelegate(mode: mode, readyReceiptPath: readyReceiptPath)
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
