# VoiceBar Rune Dictionary pilot

A separate, read-only test host. It does not integrate with the installed VoiceBar,
its MCP process, dictation, permissions, F5 or audio.

Run from this directory with Rust **1.99.1**:

```sh
cargo test --locked
cargo run --locked
VOICELAYER_RUNE_FIXTURE=1 cargo run --locked -- --theme dark --snap docs/pictures/dark-default.png
```

Rune and rune-kit, including the four upstream vendor patches, are pinned to
`74a3c8d4f4aadbdadcc8fae0aee5e36f42af1ccd`. Cargo does not inherit a git
dependency's workspace patches. The lockfile also retains the compatible wgpu
30.0.1 packages so the patched HAL is actually used.

The host reads `~/.local/state/voicelayer/stt-vocabulary.json` without migrating or
writing it. `QA_VOICE_STT_VOCABULARY_PATH` overrides that location, matching the
TypeScript resolver. Missing/malformed data displays zero personal entries.
`src/included.json` contains only the public built-in developer vocabulary; a test
compares every canonical and variant against the TypeScript constant in order.

`VOICELAYER_RUNE_FIXTURE=1` substitutes four invented developer terms, disables
geometry persistence and never reads the personal dictionary. Always set it for
public pictures, tree dumps and input scripts. Never dump a runtime tree of the
real dictionary into source, logs or fixtures.

Height is stored in `~/.local/state/voicelayer/rune-ui.json`, independently of the
dictionary. Override with `VOICELAYER_RUNE_UI_STATE_PATH`. The bottom grip and native
resize edges change height; `VOICELAYER_RUNE_SCREEN_HEIGHT` provides a deterministic
logical screen-height cap for tests. On macOS the default is the main display's
CoreGraphics logical bounds. A window moved to a different monitor still uses its
launch-time main-screen cap in this pilot.

Search matches terms and variants case-insensitively. Disclosure headers collapse
each group. One row can be selected. Add, Edit and the menu’s Copy/Delete items are
disabled; there are no mutation or clipboard handlers in this slice.

Rune-kit supplies the input, button, icon buttons, disclosure headers and neutral
theme. Core Rune virtual rows bound mounted content for large dictionaries. The
custom pencil and ellipsis are SVG glyphs inside kit icon buttons.

Build output goes to `../.build.noindex/rune-target`. Run Cargo from this directory
so it loads `.cargo/config.toml`. No audio or microphone tests are involved.
