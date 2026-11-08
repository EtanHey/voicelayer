import AppKit
import Foundation
func rect(_ r: NSRect?) -> Any { guard let r else { return NSNull() }; return ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height] }
let rows = NSScreen.screens.map { s -> [String: Any] in
    ["name": s.localizedName, "frame": rect(s.frame), "safeAreaTop": s.safeAreaInsets.top, "auxiliaryTopLeftArea": rect(s.auxiliaryTopLeftArea), "auxiliaryTopRightArea": rect(s.auxiliaryTopRightArea)]
}
print(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
