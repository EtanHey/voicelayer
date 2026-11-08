import AppKit
import Foundation
func rect(_ r: NSRect?) -> Any { guard let r else { return NSNull() }; return ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height] }
let capture = ISO8601DateFormatter().string(from: Date())
let model = Process(); model.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl"); model.arguments = ["-n", "hw.model"]
let pipe = Pipe(); model.standardOutput = pipe; try model.run(); model.waitUntilExit()
let hardware = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
let rows = NSScreen.screens.map { s -> [String: Any] in
    let display = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let mode = CGDisplayCopyDisplayMode(display)
    let displayMode: [String: Any] = ["width": mode?.width ?? 0, "height": mode?.height ?? 0,
        "pixelWidth": mode?.pixelWidth ?? 0, "pixelHeight": mode?.pixelHeight ?? 0,
        "refreshRate": mode?.refreshRate ?? 0]
    return ["provenance": ["model": hardware, "capturedAt": capture, "source": "NSScreen read-only probe", "backingScale": s.backingScaleFactor, "displayMode": displayMode], "name": s.localizedName, "frame": rect(s.frame), "safeAreaTop": s.safeAreaInsets.top, "auxiliaryTopLeftArea": rect(s.auxiliaryTopLeftArea), "auxiliaryTopRightArea": rect(s.auxiliaryTopRightArea)]
}
print(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
