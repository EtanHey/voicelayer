#!/usr/bin/env bash
# Merge VoiceBar's Dictation-key -> F18 relay into the current hidutil mapping.
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

# AIDEV-NOTE: On a machine with NO existing key mapping — i.e. every fresh boot —
# `hidutil property --get UserKeyMapping` prints the literal string `(null)`,
# which is not plist and not JSON. `plutil -convert json` then emits nothing on
# stdout while still exiting 0, so the `|| printf '[]'` fallback never fires and
# an unparseable value reaches the JSON parser below. The merge dies with
# "JSON Parse error: Unexpected token '('" and the F5 -> F18 relay is never
# applied. The LaunchAgent still reports a clean exit, so the failure is silent
# and looks exactly like "F5 stopped working after I restarted".
# This is why the relay survived all day but died on every reboot.
# Normalize anything that is not a JSON array into an empty array.
case "${current_mapping_json//[[:space:]]/}" in
  '['*']') : ;;
  *) current_mapping_json='[]' ;;
esac

merge_with_osascript() {
  /usr/bin/osascript -l JavaScript - "$current_mapping_json" "$F5_SRC_DEC" "$DICTATION_SRC_DEC" "$F18_DST_DEC" <<'JXA'
function run(argv) {
  const current = JSON.parse(argv[0] || "[]");
  const f5Src = Number(argv[1]);
  const dictationSrc = Number(argv[2]);
  const f18Dst = Number(argv[3]);
  // VoiceBar owns BOTH source keys it relays to F18: the physical F5
  // (0x70000003E) and the Apple Dictation consumer key (0xC000000CF). Strip any
  // existing mapping on either Src so the re-push below can't create a duplicate
  // Src entry (idempotent). Filtering by Src — not by exact Src->F18 pair — also
  // means a prior F5 -> anything is reclaimed for VoiceBar. Mappings on OTHER
  // keys (CapsLock -> Esc, etc.) are untouched and survive across LaunchAgent
  // runs.
  const voiceBarOwnedSrc = new Set([f5Src, dictationSrc]);
  const mappings = Array.isArray(current) ? current : ((current && current.UserKeyMapping) || []);
  // hidutil/plutil can emit HID values as strings on some macOS versions;
  // normalize so `hidutil property --set` always sees numeric Src/Dst.
  const preserved = mappings
    .filter((entry) => !voiceBarOwnedSrc.has(Number(entry.HIDKeyboardModifierMappingSrc)))
    .map((entry) => ({
      HIDKeyboardModifierMappingSrc: Number(entry.HIDKeyboardModifierMappingSrc),
      HIDKeyboardModifierMappingDst: Number(entry.HIDKeyboardModifierMappingDst),
    }));

  // Push BOTH remaps. F5 -> F18 is required so a bare F5 press survives reboots
  // instead of falling through to macOS Dictation; Dictation -> F18 promotes the
  // consumer key. Both land as numeric Src/Dst with no null entries.
  preserved.push({
    HIDKeyboardModifierMappingSrc: f5Src,
    HIDKeyboardModifierMappingDst: f18Dst,
  });
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
// VoiceBar owns BOTH source keys it relays to F18 (physical F5 + Dictation
// consumer key). Strip any existing mapping on either Src so the re-push can't
// dupe a Src (idempotent) — see the osascript path for the full rationale.
const voiceBarOwnedSrc = new Set([f5Src, dictationSrc]);
const mappings = Array.isArray(current) ? current : ((current && current.UserKeyMapping) || []);
// hidutil/plutil can emit HID values as strings on some macOS versions;
// normalize so `hidutil property --set` always sees numeric Src/Dst.
const preserved = mappings
  .filter((entry) => !voiceBarOwnedSrc.has(Number(entry.HIDKeyboardModifierMappingSrc)))
  .map((entry) => ({
    HIDKeyboardModifierMappingSrc: Number(entry.HIDKeyboardModifierMappingSrc),
    HIDKeyboardModifierMappingDst: Number(entry.HIDKeyboardModifierMappingDst),
  }));

// Push BOTH remaps: F5 -> F18 (survives reboots, no Dictation fall-through) and
// Dictation -> F18. Numeric Src/Dst, no null entries.
preserved.push({
  HIDKeyboardModifierMappingSrc: f5Src,
  HIDKeyboardModifierMappingDst: f18Dst,
});
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
