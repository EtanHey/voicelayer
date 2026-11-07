import SwiftUI

/// The production MenuBarExtra body, shared with the offscreen visual harness.
public struct MenuBarPopoverView: View {
    public let footer: VoiceBarFooterPresentation
    public let hotkeyHint: String
    /// The microphone-priority default, read-only (D2); nil when none resolves.
    public let defaultMicrophoneName: String?
    public let transcript: String
    public let degradationHint: String?
    /// Returns whether the text reached the pasteboard, so a failed copy shows no tick.
    public let onCopy: () -> Bool
    @State private var copyFeedback = CopyFeedback()
    public let onSettings: () -> Void
    public let onQuit: () -> Void
    /// The first broken Setup step, or nil: healthy shows no setup entry at all (permission health, 2026-11-07).
    public let setupAlert: MenuBarSetupAlert?
    /// Opens Settings › General scrolled to the first broken step.
    public let onFixSetup: () -> Void
    /// Opens Settings › General › Microphone priority. There is no direct device pick here (D2).
    public let onChangeMicrophone: () -> Void
    public let onLayout: ([String: CGRect]) -> Void

    public init(
        footer: VoiceBarFooterPresentation,
        hotkeyHint: String,
        defaultMicrophoneName: String?,
        transcript: String,
        degradationHint: String? = nil,
        onCopy: @escaping () -> Bool = { false },
        onSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        setupAlert: MenuBarSetupAlert? = nil,
        onFixSetup: @escaping () -> Void = {},
        onChangeMicrophone: @escaping () -> Void = {},
        onLayout: @escaping ([String: CGRect]) -> Void = { _ in }
    ) {
        self.footer = footer
        self.hotkeyHint = hotkeyHint
        self.defaultMicrophoneName = defaultMicrophoneName
        self.transcript = transcript
        self.degradationHint = degradationHint
        self.onCopy = onCopy
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.setupAlert = setupAlert
        self.onFixSetup = onFixSetup
        self.onChangeMicrophone = onChangeMicrophone
        self.onLayout = onLayout
    }

    public var defaultMicrophoneTitle: String {
        MicrophoneDefaultPresentation.title(defaultMicrophoneName)
    }

    public var defaultMicrophoneAccessibilityLabel: String {
        MicrophoneDefaultPresentation.accessibilityLabel(defaultMicrophoneName)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let degradationHint {
                Label(degradationHint, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.orange)
                Divider()
            }
            HStack(spacing: 8) {
                VoiceBarStatusIndicator(presentation: footer)
                    .accessibilityIdentifier("popover-status")
                    .popoverFrame("status")
                Spacer(minLength: 0)
                Text(hotkeyHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(hotkeyHint)
                    .accessibilityIdentifier("popover-hotkey")
                    .popoverFrame("hotkey")
            }
            if let remoteNotice = footer.remoteNotice {
                Label(remoteNotice, systemImage: "network")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(remoteNotice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .popoverFrame("locality")
            }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                    // A long device name wraps to a second line rather than losing its middle.
                    Text(defaultMicrophoneTitle)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(defaultMicrophoneTitle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(defaultMicrophoneAccessibilityLabel)
                Spacer(minLength: 0)
                Button(MicrophoneDefaultPresentation.changeTitle, action: onChangeMicrophone)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                    .fixedSize()
                    .help("Choose the default in Settings › Microphone priority")
                    .accessibilityLabel(MicrophoneDefaultPresentation.changeAccessibilityLabel)
                    .accessibilityIdentifier("popover-microphone-change")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            .accessibilityIdentifier("popover-microphone")
            .popoverFrame("mic")
            if !transcript.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Text(popoverTranscriptPreview(transcript))
                        .accessibilityIdentifier("popover-transcript")
                        .popoverFrame("transcript")
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyFeedbackButton("Copy last transcript", feedback: $copyFeedback, copy: onCopy)
                        .accessibilityIdentifier("popover-copy")
                        .popoverFrame("copy")
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .popoverFrame("transcript-row")
            }
            Divider()
                .popoverFrame("divider")
            HStack(spacing: 8) {
                Button(action: onSettings) {
                    Text("Open Settings…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityIdentifier("popover-settings")
                .popoverFrame("settings")
                Button(action: onQuit) {
                    Text("Quit VoiceBar")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityIdentifier("popover-quit")
                .popoverFrame("quit")
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .popoverFrame("footer")
            // Etan, 2026-11-07: no generic re-run entry; only a broken step, named, straight to its fix.
            if let setupAlert {
                Button(action: onFixSetup) {
                    Label(setupAlert.title, systemImage: "exclamationmark.circle.fill")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .help(setupAlert.help)
                .accessibilityIdentifier("popover-setup")
                .popoverFrame("setup")
            }
        }
        .frame(width: 276)
        .padding(12)
        .focusEffectDisabled()
        .coordinateSpace(name: "popover")
        .onPreferenceChange(PopoverFramesKey.self, perform: onLayout)
    }
}

/// The popover's setup row: names the first broken Setup step. Nil when nothing is broken.
public struct MenuBarSetupAlert: Equatable, Sendable {
    public let step: SettingsSetupStepID
    public let title: String
    public let help: String

    public init?(setup: SettingsGeneralSetup) {
        guard let step = setup.steps.first else { return nil }
        self.step = step.id
        title = "Fix \(step.title)…"
        help = step.description + " Opens Settings › General."
    }
}

func popoverTranscriptPreview(_ transcript: String) -> String {
    transcript.split(whereSeparator: \.isNewline).joined(separator: " ")
}

private struct PopoverFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func popoverFrame(_ id: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(
                key: PopoverFramesKey.self,
                value: [id: geometry.frame(in: .named("popover"))]
            )
        })
    }
}
