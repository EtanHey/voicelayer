#!/usr/bin/env swift
// Verify one rendered selection before posting exactly one HID Option+F5 pair.
import AppKit
import ApplicationServices
func refuse(_ reason: String) -> Never {
    fputs("[t3-optf5-drive] REFUSED: \(reason); no Option+F5 posted\n", stderr); exit(1)
}
func check(_ expected: String, _ actual: String) {
    guard !expected.isEmpty, expected == actual else { refuse("selection does not exactly match expected text") }
}
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--help"] {
    print("Usage: swift scripts/t3-optf5-drive.swift --expected-text-file PATH\n       ... --check-selection EXPECTED ACTUAL (no screen/input)"); exit(0)
}
if args.first == "--check-selection", args.count == 3 {
    check(args[1], args[2]); print("selection matches; check only, no input posted"); exit(0)
}
guard args.count == 2, args[0] == "--expected-text-file" else { refuse("expected --expected-text-file PATH") }
guard let contents = try? String(contentsOfFile: args[1], encoding: .utf8) else { refuse("cannot read expected file") }
let expected = contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
guard !expected.isEmpty, AXIsProcessTrusted() else { refuse("empty text or Accessibility permission unavailable") }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.t3tools.t3code").first else { refuse("T3 Code is not running") }
app.activate(options: [.activateIgnoringOtherApps]); Thread.sleep(forTimeInterval: 0.5)
func frontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
guard frontmost() else { refuse("T3 Code did not become frontmost") }
let root = AXUIElementCreateApplication(app.processIdentifier)
func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }; return result
}
func nodes() -> [AXUIElement] {
    var result: [AXUIElement] = [], pending = [root]
    while let node = pending.popLast() {
        result.append(node)
        guard result.count < 50_000 else { refuse("AX traversal bound exceeded") }
        pending.append(contentsOf: value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return result
}
let tree = nodes()
guard tree.count > 1 else { refuse("T3 accessibility tree unreadable; do not relaunch") }
// Static text only: never select text in the editable composer.
guard let element = tree.first(where: {
    (value($0, kAXRoleAttribute) as? String) == kAXStaticTextRole &&
    ((value($0, kAXValueAttribute) as? String) ?? "").contains(expected)
}) else { refuse("sentence not found in rendered static text") }
let range = ((value(element, kAXValueAttribute) as! String) as NSString).range(of: expected)
var selection = CFRange(location: range.location, length: range.length)
let rangeValue = AXValueCreate(.cfRange, &selection)!
func selectedText() -> String? {
    for node in nodes() {
        if let text = value(node, kAXSelectedTextAttribute) as? String, !text.isEmpty { return text }
    }; return nil
}
let source = CGEventSource(stateID: .hidSystemState)
let result = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
Thread.sleep(forTimeInterval: 0.1)
if result != .success || selectedText() != expected {
    func bounds(_ offset: Int) -> CGRect? {
        var character = CFRange(location: offset, length: 1)
        var output: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &character),
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &output) == .success,
              let output, CFGetTypeID(output) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(output as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }; return rect
    }
    guard let first = bounds(range.location), let last = bounds(range.location + range.length - 1) else {
        refuse("AX selection refused and exact character frames unavailable for HID drag")
    }
    guard frontmost() else { refuse("focus changed before drag") }
    func mouse(_ type: CGEventType, _ point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { refuse("cannot create mouse event") }
        event.post(tap: .cghidEventTap)
    }
    let start = CGPoint(x: first.minX, y: first.midY), end = CGPoint(x: last.maxX, y: last.midY)
    mouse(.mouseMoved, start); mouse(.leftMouseDown, start)
    for step in 1...20 {
        let t = CGFloat(step)/20
        mouse(.leftMouseDragged, CGPoint(x: start.x+(end.x-start.x)*t, y: start.y+(end.y-start.y)*t)); Thread.sleep(forTimeInterval: 0.01)
    }
    mouse(.leftMouseUp, end); Thread.sleep(forTimeInterval: 0.2)
    print("selected by HID drag using AX character frames")
} else { print("selected through AXSelectedTextRange") }
func copiedSelection() -> String? {
    guard frontmost() else { return nil }
    let board = NSPasteboard.general
    let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
        guard let data = item.data(forType: type) else { return nil }; return (type, data)
    } }
    defer {
        board.clearContents()
        board.writeObjects(saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem(); for (type, data) in entries { item.setData(data, forType: type) }; return item
        })
    }
    let before = board.changeCount
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return nil }
    down.flags = .maskCommand; up.flags = .maskCommand
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    for _ in 0..<20 { Thread.sleep(forTimeInterval: 0.05); if board.changeCount != before { return board.string(forType: .string) } }; return nil
}
check(expected, selectedText() ?? copiedSelection() ?? "")
guard frontmost(), !app.isTerminated else { refuse("T3 focus/process changed before Option+F5") }
guard let down = CGEvent(keyboardEventSource: source, virtualKey: 96, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 96, keyDown: false) else { refuse("cannot create Option+F5") }
down.flags = .maskAlternate; up.flags = .maskAlternate
down.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.05); up.post(tap: .cghidEventTap)
print("exact selection verified (\(expected.utf16.count) UTF-16 units); posted ONE Option+F5 down/up at cghidEventTap")
