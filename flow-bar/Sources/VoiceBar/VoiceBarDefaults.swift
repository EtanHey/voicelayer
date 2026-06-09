import Foundation

enum VoiceBarDefaults {
    static let suiteEnvironmentVariable = "VOICEBAR_USER_DEFAULTS_SUITE"
    static let allowParallelInstanceEnvironmentVariable = "VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE"
    static let skipLaunchServicesRegistrationEnvironmentVariable = "VOICEBAR_QA_SKIP_LS_REGISTER"
    static let skipPermissionPromptsEnvironmentVariable = "VOICEBAR_QA_SKIP_PERMISSION_PROMPTS"
    static let skipHotkeyEnvironmentVariable = "VOICEBAR_QA_SKIP_HOTKEY"

    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard let suiteName = environment[suiteEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suiteName.isEmpty,
              let defaults = UserDefaults(suiteName: suiteName)
        else {
            return .standard
        }
        return defaults
    }

    static func shouldEnforceSingleton(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[allowParallelInstanceEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
    }

    static func shouldRegisterLaunchServices(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[skipLaunchServicesRegistrationEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
    }

    static func shouldPromptForPermissions(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[skipPermissionPromptsEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
    }

    static func shouldStartHotkey(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[skipHotkeyEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
    }
}
