# Recognizer management — synthetic native visual evidence

Status: offscreen SwiftUI fixtures only; no installed-app or runtime qualification.

Before images: the picker before management controls.
After images: the same missing-Parakeet / loaded-Whisper fixture with the native
Load/Unload and download/trash buttons. 720 and 390 point layouts, light and dark,
rendered at the host's 2x backing scale. No private recordings, paths or user data.

Reproduce after images with:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
VOICEBAR_RECOGNIZER_SHOTS="$PWD/.build.noindex/recognizer-shots" swift test --package-path flow-bar --scratch-path .build.noindex/swift --filter RecognizerManagementShotsTests
```

The download icon invokes setup, including the Parakeet runtime. The trash icon
requires an unloaded engine and another installed recognizer; clicking it shows
a native confirmation containing the model-file size. UI command tests cover
correlation and cancel; no real network/runtime/app lifecycle was exercised.

## Source surface sweep

- Entry points: typed socket parsing/acks for status, residency, download, cancel
  and delete; mutations join update-drain admission, cancellation remains available.
- Client: VoiceBarApp → SettingsView → ModelsSettingsView → picker → VoiceState.
  Native offscreen fixture callbacks are inert; the older UIE2E health fixture has
  no recognizer snapshot/management callbacks and remains disabled.
- Providers: Whisper and Parakeet; explicit paths, cached weights, owned runtime
  and Python override. npm inventory includes the hashed runtime lock; app bundling
  copies runtime source. No actual model/runtime payload transfer was exercised.
- Contracts: asset metadata is independent of nullable runtime availability;
  equal-revision reads may refresh file metadata without granting Ready.
- Reverse states: absent/partial assets, checksum mismatch, cancel/retry, disk
  refusal, loaded/last-engine refusal, fallback retry and update-drain refusal.
- Connection modes: existing native socket status/ack correlation and disconnect
  reset; MCP bridge/server transports have no new tool or capability contract.
- Docs: provisioning contract updated in docs/parakeet-resident-backend.md.

The first whole Bun run exposed fake-provider prerequisites and cross-file test
state leakage. Those adverse logs remain in `.build.noindex/issue-656/final-bun.log`.
The same two failing files passed at the requested main 9e5355bd (43/0); the fixed
seven-file integration replay passed 90/0. Final whole-suite receipts live in the
PR descriptions. No capture/F5 mechanics, microphone, resident socket, installed
VoiceBar or /Applications operation is part of this implementation proof.

Delivery changed to one lane branch under Etan's explicit 01:55Z deadline,
overriding the original four-PR split. INT owns the integration PR and M4 install.
The current Parakeet revision and all three SHA256 pins were posted immediately
in the final-20261102 collab. No PR to main is opened by this lane.
