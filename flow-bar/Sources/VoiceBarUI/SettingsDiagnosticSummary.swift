import AppKit
import SwiftUI

/// Preserve the exact payload, including whitespace, Unicode and multiline errors.
enum SettingsCopyPayload {
    static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    @MainActor
    @discardableResult
    static func write(_ text: String?, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = nonempty(text) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// Shared with the Speech lane: copying never runs a command or changes a setting.
@MainActor
struct SettingsCopyButton: View {
    let text: String?
    let label: String
    var onCopy: ((String) -> Bool)? = nil
    @State private var copied = false

    var body: some View {
        if let payload = SettingsCopyPayload.nonempty(text) {
            Button {
                copied = onCopy?(payload) ?? SettingsCopyPayload.write(payload)
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(label)")
            .accessibilityLabel(copied ? "Copied \(label)" : "Copy \(label)")
            .onChange(of: text) { _, _ in copied = false }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
    }
}

enum SettingsDiagnosticSummary {
    private static func value(_ text: String?) -> String {
        SettingsCopyPayload.nonempty(text) ?? "Unknown"
    }

    static func versionLabel(bundle: Bundle = .main) -> String {
        let version = value(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = value(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        return "\(version) (build \(build))"
    }

    static func build(bundle: Bundle = .main, models: ModelsSettingsState) -> String {
        // No checkout/git lookup: only the running app's bundle establishes its build.
        [
            "VoiceBar: \(versionLabel(bundle: bundle))",
            "App commit: \(value(bundle.object(forInfoDictionaryKey: "GitCommit") as? String))",
            "Daemon identity: Unknown (not reported)",
            "Recognizer status: \(models.availability)",
            "Configured model: \(value(models.configuredModelName))",
            "Active model: \(value(models.activeModelName))",
            "Residency: \(models.residency.rawValue)",
            "Configured effort: \(value(models.configuredEffort?.rawValue))",
            "Active effort: \(value(models.activeEffort?.rawValue))",
        ].joined(separator: "\n")
    }

    static func historyMetadata(_ entry: SettingsHistoryEntry) -> String {
        [
            "Recorded: \(ISO8601DateFormatter().string(from: entry.createdAt))",
            "Microphone: \(value(entry.inputDeviceLabel))",
            "Model: \(value(entry.modelLabel))",
            "Effort: \(value(entry.performanceEffort?.rawValue))",
            "Recording duration (ms): \(entry.durationMs.map(String.init) ?? "Unknown")",
            "Transcribed duration (ms): \(entry.transcribedDurationMs.map(String.init) ?? "Unknown")",
            "Spoken duration (ms): \(entry.spokenDurationMs.map(String.init) ?? "Unknown")",
            "Processing duration (ms): \(entry.processingDurationMs.map(String.init) ?? "Unknown")",
        ].joined(separator: "\n")
    }
}
