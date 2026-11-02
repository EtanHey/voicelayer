# Recognizer management — synthetic native visual evidence

Status: offscreen SwiftUI fixtures only; no installed-app or runtime qualification.

Before images: picker from stack layer 3, before management controls.
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
