import Foundation

/// Chromium-family hosts (Chrome, Electron, CEF), recognised from the app bundle.
///
/// One detector serves both Speak Selection's AX preflight (whose unreadable-focus Copy
/// exemption relies on Chromium's secure-input behaviour) and dictation delivery.
/// An Electron app may rename its framework (ChatGPT.app, `com.openai.codex`, ships
/// "Codex Framework.framework"). Such a bundle counts only when a regular-file
/// `Resources/app.asar` is corroborated by a framework carrying Chromium's own runtime
/// data; an archive resource alone is not evidence of Chromium (PASTE2 R1).
public enum ChromiumFamilyApps {
    public static let frameworks = [
        "Electron Framework.framework", "Chromium Embedded Framework.framework", "Chromium Framework.framework",
        "Google Chrome Framework.framework", "Microsoft Edge Framework.framework", "Brave Browser Framework.framework",
    ]

    /// Files every Chromium runtime loads from its framework's Resources.
    static let chromiumRuntimeData = ["icudtl.dat", "resources.pak"]

    public static func contains(bundleURL: URL?) -> Bool {
        guard let contents = bundleURL?.appendingPathComponent("Contents") else { return false }
        let fileManager = FileManager.default
        let frameworkDirectory = contents.appendingPathComponent("Frameworks")
        if frameworks.contains(where: {
            fileManager.fileExists(atPath: frameworkDirectory.appendingPathComponent($0).path)
        }) {
            return true
        }
        guard isRegularFile(contents.appendingPathComponent("Resources/app.asar")),
              let embedded = try? fileManager.contentsOfDirectory(atPath: frameworkDirectory.path) else {
            return false
        }
        return embedded.contains { name in
            name.hasSuffix(" Framework.framework") && chromiumRuntimeData.allSatisfy {
                isRegularFile(frameworkDirectory.appendingPathComponent("\(name)/Resources/\($0)"))
            }
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
