#if VOICEBAR_QA
import Foundation

/// A marker created by the runner is required before even constructing the fixture delegate.
/// There are no fallbacks to HOME, standard defaults, the archive, or resident sockets.
struct UIE2ESandbox {
    let root: URL
    init(environment: [String: String]) throws {
        guard let path = environment["VOICEBAR_UIE2E_ROOT"], path.hasPrefix("/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("vl-ui-"),
              root.path != NSHomeDirectory(),
              try String(contentsOf: root.appendingPathComponent(".uie2e-sandbox")) == "voicebar-ui-e2e-v1\n"
        else { throw CocoaError(.fileReadNoPermission) }
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
