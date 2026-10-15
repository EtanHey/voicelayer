# Offscreen Swift tests

This target is a dependency of both XCTest targets, never of VoiceBar or VoiceBarUI.
Its Objective-C `+load` installs isolation before XCTest runs any fixture (including
fixtures opened indirectly by production window controllers).

- Prefer un-ordered NSHostingView bitmap rendering for view shots.
- Use `VLOrderTestWindow` when AppKit ordering/lifecycle behavior matters. Windows
  stay alpha 0 and outside every connected NSScreen. Key/main-window acquisition
  and application activation are suppressed in this test process only.
- `VLOrderCompositorTestWindow` is reserved for native-glass pixel tests. Transparent
  compositor capture is empty, and bitmap rendering changes native glass. These
  windows use alpha 1, but cannot be moved/resized onto a display. They never become
  key or activate the process. This preserves the original pixel assertions.
- `VLPostTestActivation` exercises activation-notification handling without asking
  macOS to activate the test application. SwiftUI's `controlActiveState` can
  model appearance, but does not establish keyboard focus.

The popover test pins production root focus-suppression wiring and rejects its
removal (including a compiled-source mutation run). `controlActiveState` models
appearance only. Actual MenuBarExtra opening, keyboard-focus transitions, and
absence of a focus ring on opening remain native acceptance.

AppKit normally constrains titled windows back onto a screen during ordering.
The test-only frame constraint disables that behavior; ordering and later moves
and resizes force ordered windows offscreen. The XCTest observer records actual
key/activation/geometry violations on AppKit notifications and checks again after
each case. The source guard rejects direct fixture ordering/focus/activation calls.
The NotchPanelVisibility spy still overrides ordering without calling AppKit.

Run `swift test` normally, including from push hooks; no opt-in flag is required.
Do not link this helper into a production target.
