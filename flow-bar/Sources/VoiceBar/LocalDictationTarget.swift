import AppKit
import VoiceBarUI

/// AppKit's field editor is the input target for VoiceBar's own Settings fields.
/// Avoid cross-process AX calls back into our blocked main thread.
enum LocalDictationTarget {
    static var focusedEditor: NSTextView? {
        guard let app = NSApp, app.isActive, let window = app.keyWindow, window.isKeyWindow else { return nil }
        return window.firstResponder as? NSTextView
    }

    static func captureEligibility(
        frontmostPID: pid_t?, editor: NSTextView?,
        external: () -> DictationFocusedTargetEligibility?
    ) -> DictationFocusedTargetEligibility? {
        if let editor { return eligibility(for: editor) }
        guard frontmostPID != ProcessInfo.processInfo.processIdentifier else { return nil }
        return external()
    }

    static func eligibility(for editor: NSTextView) -> DictationFocusedTargetEligibility {
        DictationFocusedTargetEligibility(processIdentifier: ProcessInfo.processInfo.processIdentifier,
            role: "AXTextArea", isEditable: editor.isEditable,
            isSecure: editor.delegate is NSSecureTextField,
            matchesCurrentFocus: { [weak editor] in
                guard let editor else { return false }
                return focusedEditor === editor && editor.isEditable && !(editor.delegate is NSSecureTextField)
            })
    }

    static func insertion(for editor: NSTextView) -> AsyncDictationInsertionHandler {
        { [weak editor] text, completion in
            guard let editor, editor.isEditable, !(editor.delegate is NSSecureTextField) else { return false }
            let before = editor.string
            let range = editor.selectedRange()
            guard let replacementRange = Range(range, in: before) else { return false }
            let expected = before.replacingCharacters(in: replacementRange, with: text)
            // Invocation consumes the attempt even if a delegate rejects or transforms it.
            editor.insertText(text, replacementRange: range)
            completion(editor.string == expected ? .verified : .appliedUnverified)
            return true
        }
    }
}
