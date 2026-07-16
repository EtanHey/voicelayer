# VoiceBar Dev-Expanded State Design

## Context

VoiceBar normally collapses its idle pill to a dot after five seconds. That default is intentional, but it makes agent-driven development and visual testing harder because the visible app state disappears between actions. The B16 addendum permits a separate, flag-gated development state that keeps the existing pill expanded without changing the F5 or default UI contract.

## Requirements

- Preserve default idle-collapse behavior when no development flag is present.
- Enable persistent expanded idle state with either `VOICEBAR_DEV_KEEP_EXPANDED=1` or `/tmp/.voicelayer-voicebar-expanded`.
- Resolve the flag at VoiceBar state creation; changing it requires relaunching VoiceBar.
- Do not change `BarView`, panel geometry, hotkeys, F5 handling, dictation, socket protocol, or daemon behavior.
- Add deterministic tests for environment, flag-file, default, and idle-timer behavior.

## Considered approaches

### 1. Gate the idle-collapse scheduler (chosen)

Add a small `VoiceBarDevState` policy that resolves the environment variable or flag file. Inject the resolved Boolean into `VoiceState` and make `startCollapseTimer()` leave the pill expanded when enabled.

This keeps one source of truth: `VoiceState.isCollapsed`. It also makes the default path use the existing timer unchanged and provides pure seams for tests.

### 2. Override collapsed rendering in `BarView`

Render the expanded pill even when `VoiceState.isCollapsed` is true. This is rejected because panel layout and hit testing would still use collapsed state, creating visual and interaction divergence. It would also modify the frozen visible pill surface.

### 3. Replace the collapse delay with an effectively infinite duration

Set `idleCollapseDelay` to a huge value under a flag. This is rejected because it schedules a long-lived task, hides intent in a timing value, and is less deterministic to test.

## Design

`VoiceBarDevState` lives in `VoiceBarUI`, alongside the state it configures. It exposes:

- `keepExpandedEnvironmentVariable = "VOICEBAR_DEV_KEEP_EXPANDED"`
- `keepExpandedFlagPath = "/tmp/.voicelayer-voicebar-expanded"`
- `shouldKeepExpanded(environment:fileExists:)`

The policy returns true when the trimmed environment value is exactly `1`, or when the flag file exists. Its injected arguments keep tests isolated from process-global environment and filesystem state.

The opt-in is intentionally available in a release-configured app: `flow-bar/build-app.sh` always uses `swift build -c release`, including local development installs. A compile-time `#if DEBUG` gate would therefore make the requested development state unreachable. The shared `/tmp` sentinel intentionally follows the addendum's `/tmp/.voicelayer-daemon-disabled` family; its only effect is non-privileged window presentation, and the app's normal singleton policy limits VoiceBar to one active instance.

`VoiceState` accepts `keepsExpandedInDevState`, defaulting to the policy result. `startCollapseTimer()` first cancels any existing timer. When the development state is enabled, it also expands the pill and returns without scheduling a new task. Every existing caller therefore receives the same behavior without branching throughout the state machine.

## Verification

- A RED test proves the policy API and injected `VoiceState` behavior do not yet exist.
- Policy tests cover default false, environment true, and flag-file true.
- Async state tests prove enabled development state remains expanded past the collapse delay and disabled/default behavior still collapses.
- Full `swift test` and `flow-bar/build-app.sh` verify the package and app bundle.
- Diff audit proves no F5/hotkey, `BarView`, socket, daemon, or TypeScript surface changed.
- A real VoiceBar launch with an isolated socket and the environment flag must remain expanded in idle state; screenshots provide the visual receipt.

## Scope note

This is a development/testing affordance and a small stepping stone toward the persistent teleprompter direction in L1 §10 / §8.11. It does not implement that product behavior and does not change production defaults.
