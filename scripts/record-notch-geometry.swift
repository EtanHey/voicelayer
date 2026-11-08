// Read-only: prints every connected screen's notch metrics as JSON (NSScreen frame, visibleFrame,
// safeAreaInsets, auxiliaryTopLeftArea / auxiliaryTopRightArea, backing scale). Used once per Mac to
// record the real notch fixture the snapshot tests lay out against (Lane A, 2.4). It never writes,
// never moves the pointer and never opens a window.
// Run: swift scripts/record-notch-geometry.swift
import AppKit
import Foundation

func rect(_ r: CGRect?) -> Any {
    guard let r else { return NSNull() }
    return ["x": r.origin.x, "y": r.origin.y, "width": r.size.width, "height": r.size.height]
}

let host = Host.current().localizedName ?? "unknown"
let model: String = {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(1, size))
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
}()
let screens: [[String: Any]] = NSScreen.screens.map { screen in
    let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    return [
        "name": screen.localizedName,
        "builtIn": CGDisplayIsBuiltin(number) != 0,
        "backingScaleFactor": screen.backingScaleFactor,
        "frame": rect(screen.frame),
        "visibleFrame": rect(screen.visibleFrame),
        "safeAreaInsets": [
            "top": screen.safeAreaInsets.top, "left": screen.safeAreaInsets.left,
            "bottom": screen.safeAreaInsets.bottom, "right": screen.safeAreaInsets.right,
        ],
        "auxiliaryTopLeftArea": rect(screen.auxiliaryTopLeftArea),
        "auxiliaryTopRightArea": rect(screen.auxiliaryTopRightArea),
    ]
}
let payload: [String: Any] = [
    "recordedAt": ISO8601DateFormatter().string(from: Date()),
    "hardwareModel": model,
    "hostName": host,
    "screens": screens,
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
