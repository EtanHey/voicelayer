import Foundation

/// Chromium-family hosts (Chrome, Electron, CEF), recognised from the app bundle.
///
/// One detector serves both Speak Selection's AX preflight and dictation delivery.
/// An Electron app may rename its framework (ChatGPT.app, `com.openai.codex`, ships
/// "Codex Framework.framework"), so Electron's `Resources/app.asar` also counts.
public enum ChromiumFamilyApps {
    public static let frameworks = [
        "Electron Framework.framework", "Chromium Embedded Framework.framework", "Chromium Framework.framework",
        "Google Chrome Framework.framework", "Microsoft Edge Framework.framework", "Brave Browser Framework.framework",
    ]

    public static func contains(bundleURL: URL?) -> Bool {
        guard let contents = bundleURL?.appendingPathComponent("Contents") else { return false }
        let fileManager = FileManager.default
        let frameworkDirectory = contents.appendingPathComponent("Frameworks")
        return frameworks.contains {
            fileManager.fileExists(atPath: frameworkDirectory.appendingPathComponent($0).path)
        } || fileManager.fileExists(atPath: contents.appendingPathComponent("Resources/app.asar").path)
    }
}
