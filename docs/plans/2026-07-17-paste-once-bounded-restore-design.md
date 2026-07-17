# Paste-Once With Bounded Clipboard Restore — Lead Decision

## Approval

Approved by the VoiceLayer lead on 2026-07-17 as Option 1 for PR #344. This decision supersedes the earlier immediate-restore requirement and authorizes implementation without another design checkpoint.

## Selected design

- Retain the existing production `pasteboardRestoreDelay` class and its 0.5-second value.
- Retain the pasteboard snapshot/change-count guard so restoration never overwrites a clipboard changed before the delayed restore executes.
- Retain PR #344's Shift+F5 ordering: idle key-down emits one re-paste, only its recorded paired key-up is consumed without dispatch even if Shift is released first or the other configured hotkey is pressed, an ordinary hold that acquires Shift still receives its key-up, active-gesture key-down is consumed, and active-gesture key-up unwinds the gesture.
- Preserve the existing AX-first, clipboard-plus-Cmd+V-second transport and paste each transcript once.

## Rejected alternatives

1. Immediate restore is rejected because `CGEvent.post` returns before the target is guaranteed to consume Cmd+V; the target can therefore paste the user's old clipboard.
2. Target-consumption acknowledgement is rejected for this PR because it changes the frozen paste mechanism and needs separate operator sanction.

## Verification

- Focused HotkeyManager tests cover the four Shift+F5 ordering states plus Shift-up-before-F5-up, independent F5/F18 event pairing, and Shift acquired during an ordinary hold.
- Focused VoiceStatePaste tests cover delayed restoration and preservation of a clipboard changed before restore.
- VoiceBarDevState tests confirm the #346 development-state behavior survives the rebase.
- Full Bun and Swift suites plus the isolated 10-item corpus/runtime gate must pass on the final head.
