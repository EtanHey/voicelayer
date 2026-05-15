#!/usr/bin/env bash
# Merge VoiceBar's F5/Dictation -> F18 relay into the current hidutil mapping.
set -euo pipefail

readonly F5_SRC_DEC="30064771134" # 0x70000003E
readonly DICTATION_SRC_DEC="51539607759" # 0xC000000CF
readonly F18_DST_DEC="30064771181" # 0x70000006D

if [[ -n "${VOICELAYER_HIDUTIL_CURRENT_MAPPING:-}" ]]; then
  current_mapping_json="$VOICELAYER_HIDUTIL_CURRENT_MAPPING"
else
  current_mapping_json="$(
    /usr/bin/hidutil property --get UserKeyMapping 2>/dev/null \
      | /usr/bin/plutil -convert json -o - - 2>/dev/null \
      || printf '[]'
  )"
fi

merge_with_osascript() {
  /usr/bin/osascript -l JavaScript - "$current_mapping_json" "$F5_SRC_DEC" "$DICTATION_SRC_DEC" "$F18_DST_DEC" <<'JXA'
function run(argv) {
  const current = JSON.parse(argv[0] || "[]");
  const f5Src = Number(argv[1]);
  const dictationSrc = Number(argv[2]);
  const f18Dst = Number(argv[3]);
  // Filter only the exact stale VoiceBar shapes (Src -> F18). A user may have
  // their own F5 -> CapsLock or Dictation -> SomeOtherKey mapping that must
  // survive across LaunchAgent runs — only entries that look like VoiceBar's
  // output (F5 -> F18 or Dictation -> F18) are ours to strip.
  const voiceBarStaleEntries = new Set([
    `${f5Src}|${f18Dst}`,
    `${dictationSrc}|${f18Dst}`,
  ]);
  const mappings = Array.isArray(current) ? current : ((current && current.UserKeyMapping) || []);
  // hidutil/plutil can emit HID values as strings on some macOS versions;
  // normalize so `hidutil property --set` always sees numeric Src/Dst.
  const preserved = mappings
    .filter((entry) => {
      const src = Number(entry.HIDKeyboardModifierMappingSrc);
      const dst = Number(entry.HIDKeyboardModifierMappingDst);
      return !voiceBarStaleEntries.has(`${src}|${dst}`);
    })
    .map((entry) => ({
      HIDKeyboardModifierMappingSrc: Number(entry.HIDKeyboardModifierMappingSrc),
      HIDKeyboardModifierMappingDst: Number(entry.HIDKeyboardModifierMappingDst),
    }));

  // Only remap the Apple Dictation consumer key globally. The physical F5
  // (0x70000003E) is NOT pushed: VoiceBar's CGEventTap already listens for
  // keycode 96 directly, and rewriting F5 -> F18 at the HID layer would hide
  // F5 from the OS for every app — breaking system chords like Cmd+F5
  // (VoiceOver).
  preserved.push({
    HIDKeyboardModifierMappingSrc: dictationSrc,
    HIDKeyboardModifierMappingDst: f18Dst,
  });

  return JSON.stringify({ UserKeyMapping: preserved });
}
JXA
}

merge_with_node() {
  node - "$current_mapping_json" "$F5_SRC_DEC" "$DICTATION_SRC_DEC" "$F18_DST_DEC" <<'NODE'
const [currentJson, f5SrcArg, dictationSrcArg, f18DstArg] = process.argv.slice(2);
const current = JSON.parse(currentJson || "[]");
const f5Src = Number(f5SrcArg);
const dictationSrc = Number(dictationSrcArg);
const f18Dst = Number(f18DstArg);
// Filter only the exact stale VoiceBar shapes (Src -> F18) — see the
// osascript path for the full rationale.
const voiceBarStaleEntries = new Set([
  `${f5Src}|${f18Dst}`,
  `${dictationSrc}|${f18Dst}`,
]);
const mappings = Array.isArray(current) ? current : ((current && current.UserKeyMapping) || []);
// hidutil/plutil can emit HID values as strings on some macOS versions;
// normalize so `hidutil property --set` always sees numeric Src/Dst.
const preserved = mappings
  .filter((entry) => {
    const src = Number(entry.HIDKeyboardModifierMappingSrc);
    const dst = Number(entry.HIDKeyboardModifierMappingDst);
    return !voiceBarStaleEntries.has(`${src}|${dst}`);
  })
  .map((entry) => ({
    HIDKeyboardModifierMappingSrc: Number(entry.HIDKeyboardModifierMappingSrc),
    HIDKeyboardModifierMappingDst: Number(entry.HIDKeyboardModifierMappingDst),
  }));

// Only remap the Apple Dictation consumer key globally (see osascript path
// for full rationale).
preserved.push({
  HIDKeyboardModifierMappingSrc: dictationSrc,
  HIDKeyboardModifierMappingDst: f18Dst,
});

process.stdout.write(JSON.stringify({ UserKeyMapping: preserved }));
NODE
}

case "${VOICELAYER_HIDUTIL_JS_RUNTIME:-auto}" in
  osascript)
    merged_mapping_json="$(merge_with_osascript)"
    ;;
  node)
    merged_mapping_json="$(merge_with_node)"
    ;;
  auto)
    if [[ -x /usr/bin/osascript ]]; then
      merged_mapping_json="$(merge_with_osascript)"
    elif command -v node >/dev/null 2>&1; then
      merged_mapping_json="$(merge_with_node)"
    else
      echo "ERROR: neither osascript nor node is available to merge hidutil mappings" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: invalid VOICELAYER_HIDUTIL_JS_RUNTIME: ${VOICELAYER_HIDUTIL_JS_RUNTIME}" >&2
    exit 1
    ;;
esac

if [[ "${VOICELAYER_HIDUTIL_DRY_RUN:-0}" = "1" ]]; then
  printf '%s\n' "$merged_mapping_json"
  exit 0
fi

/usr/bin/hidutil property --set "$merged_mapping_json"
