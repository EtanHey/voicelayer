#if VOICEBAR_QA
import AppKit
import Foundation

/// HIDE1 measures app content; the QA menu-bar presence remains available while snoozed.
@MainActor
func uie2eVisibleContentWindows(_ windows: [NSWindow], statusWindow: NSWindow?) -> [NSWindow] {
    windows.filter { $0 !== statusWindow && $0.isVisible && !$0.frame.isEmpty }
}

/// A marker created by the runner is required before even constructing the fixture delegate.
/// There are no fallbacks to HOME, standard defaults, the archive, or resident sockets.
struct UIE2ESandbox {
    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    let root: URL
    init(environment: [String: String]) throws {
        guard let path = environment["VOICEBAR_UIE2E_ROOT"], path.hasPrefix("/") else {
            throw Refusal("VOICEBAR_UIE2E_ROOT must be an absolute vl-ui-* directory")
        }
        root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("vl-ui-"),
              root.path != NSHomeDirectory(),
              try String(contentsOf: root.appendingPathComponent(".uie2e-sandbox")) == "voicebar-ui-e2e-v1\n"
        else { throw Refusal("UIE2E root must resolve to a vl-ui-* directory outside HOME with .uie2e-sandbox containing voicebar-ui-e2e-v1 followed by a newline: \(root.path)") }
    }

    func writeObject(_ object: Any, file: String) {
        do { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(file), options: .atomic) }
        catch { fatalError("UIE2E fixture persistence failed: \(error)") }
    }

    func write<T: Encodable>(_ value: T, file: String) {
        do { try JSONEncoder().encode(value).write(to: root.appendingPathComponent(file), options: .atomic) }
        catch { fatalError("UIE2E fixture persistence failed: \(error)") }
    }
}
#endif
