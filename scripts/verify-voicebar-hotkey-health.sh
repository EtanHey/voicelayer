#!/usr/bin/env bash
# Fail-loud postflight for VoiceBar's canonical app, launchd, remap, and event tap.
set -euo pipefail

CANONICAL_APP="${VOICEBAR_CANONICAL_APP:-/Applications/VoiceBar.app}"
BUNDLE_ID="com.voicelayer.voicebar"
LABEL="com.voicelayer.voicebar"
REQUIRED_TEAM_ID="${VOICEBAR_REQUIRED_TEAM_ID:-PPN23G925Y}"
REQUIRED_AUTHORITY_PREFIX="Developer ID Application"
PLIST_BUDDY="${VOICEBAR_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
F18_USAGE=30064771181
F5_USAGE=30064771134
DICTATION_USAGE=51539607759
ALLOW_STOPPED=0

mapping_has_pair() {
    local mapping="$1"
    local source_usage="$2"
    local destination_usage="$3"

    printf '%s\n' "$mapping" | awk \
        -v source_usage="$source_usage" \
        -v destination_usage="$destination_usage" '
        BEGIN { RS = "}" }
        {
            source = ""
            destination = ""
            line_count = split($0, lines, "\n")
            for (i = 1; i <= line_count; i++) {
                if (lines[i] ~ /HIDKeyboardModifierMappingSrc/) {
                    source = lines[i]
                    gsub(/[^0-9]/, "", source)
                }
                if (lines[i] ~ /HIDKeyboardModifierMappingDst/) {
                    destination = lines[i]
                    gsub(/[^0-9]/, "", destination)
                }
            }
            if (source == source_usage && destination == destination_usage) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

secure_input_owner() {
    local ioreg_output="$1"
    local owner
    owner="$(
        printf '%s\n' "$ioreg_output" \
            | sed -n 's/.*kCGSSessionSecureInputPID"[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            | head -n 1
    )"
    [[ "$owner" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$owner"
}

launchd_loaded_program() {
    local launchd_output="$1"
    local program
    program="$(
        printf '%s\n' "$launchd_output" \
            | sed -n 's/^[[:space:]]*program = //p' \
            | head -n 1
    )"
    [[ -n "$program" ]] || return 1
    printf '%s\n' "$program"
}

noncanonical_launchd_definitions() {
    local definitions="$1"
    local canonical_definition="$2"
    local definition

    while IFS= read -r definition; do
        [[ -n "$definition" ]] || continue
        [[ "$definition" = "$canonical_definition" ]] && continue
        printf '%s\n' "$definition"
    done <<<"$definitions"
}

voicebar_process_rows() {
    local ps_output="$1"

    printf '%s\n' "$ps_output" | awk '
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            pid = line
            sub(/[[:space:]].*$/, "", pid)
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            if (line ~ /^\/.*\/VoiceBar\.app\/Contents\/MacOS\/VoiceBar([[:space:]]|$)/) {
                print pid " " line
            }
        }
    '
}

event_tap_log_verdict() {
    local log_output="$1"
    local verdict="unknown"
    local line

    # Both unified logging and the LaunchAgent stderr file are chronological.
    # Keep replacing the verdict so a successful retry supersedes a stale
    # startup failure, while a later failure still wins over an earlier success.
    while IFS= read -r line; do
        case "$line" in
            *"[HotkeyManager] Input Monitoring permission not granted"*)
                verdict="input-monitoring-missing"
                ;;
            *"[HotkeyManager] Accessibility permission not granted"*)
                verdict="accessibility-missing"
                ;;
            *"[HotkeyManager] Failed to create CGEventTap"*)
                verdict="event-tap-failed"
                ;;
            *"[HotkeyManager] Event tap started"*)
                verdict="ready"
                ;;
        esac
    done <<<"$log_output"

    printf '%s\n' "$verdict"
}

chronological_event_tap_logs() {
    # Both sources begin with an ISO-like date and time. Sort only by those
    # fields and keep input order for equal timestamps so message text cannot
    # reverse two status transitions recorded in the same clock tick.
    LC_ALL=C sort -s -k1,2
}

fail() {
    printf 'HOTKEY HEALTH FAILED: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: verify-voicebar-hotkey-health.sh [--allow-stopped]

  --allow-stopped  verify static app/launchd/remap state without requiring a
                   running VoiceBar event tap.
EOF
}

if [[ "${VOICEBAR_HOTKEY_HEALTH_SOURCE_ONLY:-0}" = "1" ]]; then
    # shellcheck disable=SC2317 # This branch exits only when the file is sourced.
    return 0 2>/dev/null || exit 0
fi

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --allow-stopped)
            ALLOW_STOPPED=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -d "$CANONICAL_APP" ]] || fail "canonical app is missing: $CANONICAL_APP"

info_plist="$CANONICAL_APP/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "Info.plist is missing: $info_plist"
actual_bundle_id="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
[[ "$actual_bundle_id" = "$BUNDLE_ID" ]] || fail "unexpected bundle id: ${actual_bundle_id:-<missing>}"

signature="$(
    codesign -dvvv "$CANONICAL_APP" 2>&1 || true
)"
team_id="$(printf '%s\n' "$signature" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
authority="$(printf '%s\n' "$signature" | awk -F= '/^Authority=/{print $2; exit}')"
[[ "$team_id" = "$REQUIRED_TEAM_ID" ]] || fail "canonical app Team ID is ${team_id:-<missing>}, expected $REQUIRED_TEAM_ID"
[[ "$authority" = "$REQUIRED_AUTHORITY_PREFIX"* ]] || fail "canonical app is not Developer-ID signed"
codesign --verify --deep --strict "$CANONICAL_APP" >/dev/null 2>&1 \
    || fail "canonical app signature verification failed"

declare -a bundles=()
bundle_search_roots=(
    /Applications
    "$HOME/Applications"
    "$HOME/Gits"
    "$HOME/Desktop"
    "$HOME/Downloads"
    /tmp
    /private/tmp
)
if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
    bundle_search_roots+=("$TMPDIR")
fi
while IFS= read -r bundle; do
    [[ -d "$bundle" ]] || continue
    bundles+=("$bundle")
done < <(
    {
        mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true
        find "${bundle_search_roots[@]}" \
            -maxdepth 6 -name 'VoiceBar.app' -type d -prune 2>/dev/null || true
    } | sort -u
)
if [[ "${#bundles[@]}" -ne 1 || "${bundles[0]:-}" != "$CANONICAL_APP" ]]; then
    printf 'VoiceBar bundles found:\n' >&2
    printf '  %s\n' "${bundles[@]:-<none>}" >&2
    fail "expected exactly one canonical VoiceBar bundle"
fi

agent_plist="$HOME/Library/LaunchAgents/$LABEL.plist"
[[ -f "$agent_plist" ]] || fail "canonical LaunchAgent is missing: $agent_plist"
agent_program="$("$PLIST_BUDDY" -c 'Print :ProgramArguments:0' "$agent_plist" 2>/dev/null || true)"
[[ "$agent_program" = "$CANONICAL_APP/Contents/MacOS/VoiceBar" ]] \
    || fail "LaunchAgent targets ${agent_program:-<missing>}, not the canonical app"
launchd_definitions="$(
    grep -rlE 'VoiceBar|voicelayer\.voicebar' \
        "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons \
        2>/dev/null | sort -u || true
)"
stray_launchd_definitions="$(
    noncanonical_launchd_definitions "$launchd_definitions" "$agent_plist"
)"
if [[ -n "$stray_launchd_definitions" ]]; then
    printf 'Stray VoiceBar launchd definitions found:\n%s\n' \
        "$stray_launchd_definitions" >&2
    fail "expected only the canonical user LaunchAgent definition"
fi
launchd_output=""
if launchd_output="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)"; then
    loaded_program="$(launchd_loaded_program "$launchd_output" || true)"
    [[ "$loaded_program" = "$CANONICAL_APP/Contents/MacOS/VoiceBar" ]] \
        || fail "loaded LaunchAgent targets ${loaded_program:-<missing>}, not the canonical app"
elif [[ "$ALLOW_STOPPED" -eq 0 ]]; then
    fail "canonical LaunchAgent is not loaded"
fi

mapping="$(hidutil property --get UserKeyMapping 2>/dev/null || true)"
mapping_has_pair "$mapping" "$F5_USAGE" "$F18_USAGE" \
    || fail "F5 -> F18 hidutil mapping is missing"
mapping_has_pair "$mapping" "$DICTATION_USAGE" "$F18_USAGE" \
    || fail "Dictation/F5 -> F18 hidutil mapping is missing"

if [[ "$ALLOW_STOPPED" -eq 0 ]]; then
    ioreg_output="$(ioreg -l -w 0 2>/dev/null || true)"
    if secure_pid="$(secure_input_owner "$ioreg_output")"; then
        secure_process="$(ps -p "$secure_pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
        fail "macOS Secure Input is held by PID $secure_pid (${secure_process:-unknown}); change focus or quit that app"
    fi

    ps_output="$(ps -axo pid=,command=)"
    process_rows="$(
        voicebar_process_rows "$ps_output"
    )"
    process_count="$(printf '%s\n' "$process_rows" | awk 'NF { count++ } END { print count + 0 }')"
    [[ "$process_count" -eq 1 ]] || fail "expected one running VoiceBar process, found $process_count"

    voicebar_pid="$(printf '%s\n' "$process_rows" | awk 'NR == 1 { print $1 }')"
    process_command="$(printf '%s\n' "$process_rows" | awk 'NR == 1 { $1=""; sub(/^[[:space:]]+/, ""); print }')"
    [[ "$process_command" = "$CANONICAL_APP/Contents/MacOS/VoiceBar"* ]] \
        || fail "running VoiceBar is not canonical: $process_command"

    agent_stderr_path="$(
        "$PLIST_BUDDY" -c 'Print :StandardErrorPath' \
            "$agent_plist" 2>/dev/null || true
    )"
    log_output="$(
        {
            /usr/bin/log show \
                --style compact \
                --last "${VOICEBAR_HOTKEY_HEALTH_LOG_WINDOW:-10m}" \
                --predicate "processID == $voicebar_pid" 2>/dev/null || true
            if [[ -n "$agent_stderr_path" && -r "$agent_stderr_path" ]]; then
                awk -v process_marker="VoiceBar[$voicebar_pid:" \
                    'index($0, process_marker) > 0 { print }' \
                    "$agent_stderr_path"
            fi
        } | chronological_event_tap_logs
    )"
    verdict="$(event_tap_log_verdict "$log_output")"
    case "$verdict" in
        ready) ;;
        input-monitoring-missing)
            printf '%s\n' \
                "ETAN ACTION: System Settings → Privacy & Security → Input Monitoring → turn VoiceBar on." >&2
            fail "VoiceBar lacks Input Monitoring permission"
            ;;
        accessibility-missing)
            printf '%s\n' \
                "ETAN ACTION: System Settings → Privacy & Security → Accessibility → turn VoiceBar on." >&2
            fail "VoiceBar lacks Accessibility permission"
            ;;
        event-tap-failed)
            fail "VoiceBar could not create its keyboard event tap"
            ;;
        *)
            fail "current VoiceBar PID $voicebar_pid has no recent event-tap startup evidence"
            ;;
    esac
fi

printf 'HOTKEY HEALTH OK\n'
