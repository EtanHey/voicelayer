#!/usr/bin/env bash
# Builds the T7 fixture harnesses from the production Swift sources into $1 (default .build.noindex/typed-delivery-fixture).
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
out="${1:-$root/.build.noindex/typed-delivery-fixture}"
mkdir -p "$out/mod"
ui=("$root/flow-bar/Sources/VoiceBarUI/SynthesizedTyping.swift")
[[ -f "$root/flow-bar/Sources/VoiceBarUI/ListContinuationTyping.swift" ]] && ui+=("$root/flow-bar/Sources/VoiceBarUI/ListContinuationTyping.swift")
swiftc -O -module-name PlanHarness "${ui[@]}" "$root/tests/fixtures/typed-delivery/plan/main.swift" -o "$out/plan"
swiftc -O -parse-as-library -emit-library -static -emit-module -module-name VoiceBarUI \
  -emit-module-path "$out/mod/VoiceBarUI.swiftmodule" -o "$out/mod/libVoiceBarUI.a" \
  "${ui[@]}" "$root/tests/fixtures/typed-delivery/post/GuardedTypingResultShim.swift"
vb=("$root/flow-bar/Sources/VoiceBar/SynthesizedKeyEvents.swift")
[[ -f "$root/flow-bar/Sources/VoiceBar/ListAwareTyping.swift" ]] && vb+=("$root/flow-bar/Sources/VoiceBar/ListAwareTyping.swift")
swiftc -O -I "$out/mod" -L "$out/mod" -lVoiceBarUI "${vb[@]}" "$root/tests/fixtures/typed-delivery/post/main.swift" -o "$out/post"
echo "harness -> $out (plan, post)"
