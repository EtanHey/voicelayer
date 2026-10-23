#!/usr/bin/env bash
# Return 0: VoiceBar identity; 1: absent metadata or valid nonmatching/missing ID;
# 2: unknown identity. Callers must refuse on 2 before counting/planning changes.
# Names, locations and signatures do not determine bundle identity.
voicebar_bundle_identity() {
    local app="$1" info="$1/Contents/Info.plist" bundle_id result
    local buddy="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
    [[ -d "$app" ]] || return 1
    if [[ ! -r "$app" || ! -x "$app" ]] ||
       { [[ -d "$app/Contents" ]] && [[ ! -r "$app/Contents" || ! -x "$app/Contents" ]]; }; then
        printf 'VoiceBar bundle identity unknown (unreadable directory): %s\n' "$app" >&2
        return 2
    fi
    [[ -e "$info" || -L "$info" ]] || return 1
    if [[ ! -f "$info" || ! -r "$info" ]] || ! plutil -lint -s -- "$info" >/dev/null 2>&1; then
        printf 'VoiceBar bundle identity unknown (unreadable/malformed Info.plist): %s\n' "$app" >&2
        return 2
    fi
    if bundle_id="$("$buddy" -c 'Print :CFBundleIdentifier' "$info" 2>&1)"; then
        [[ "$bundle_id" = 'com.voicelayer.voicebar' ]]
        return $?
    else
        result="$bundle_id"
        # Only PlistBuddy's explicit missing-entry error is a known missing ID.
        # Other read/extraction failures must not silently hide a real copy.
        [[ "$result" = 'Print: Entry, ":CFBundleIdentifier", Does Not Exist' ]] && return 1
        printf 'VoiceBar bundle identity unknown (cannot read CFBundleIdentifier): %s\n' "$app" >&2
        return 2
    fi
}
