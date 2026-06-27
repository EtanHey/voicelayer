#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-voicebar-release.sh"
CANONICAL_VERSION="$(bun -e 'const path = process.argv[1]; console.log(JSON.parse(await Bun.file(path).text()).version)' "$ROOT_DIR/package.json")"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

write_info_plist() {
    local path="$1"
    local version="$2"
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$version</string>
</dict>
</plist>
EOF
}

write_tap() {
    local tap_root="$1"
    local formula_version="$2"
    local cask_version="$3"
    mkdir -p "$tap_root/Formula" "$tap_root/Casks"
    cat > "$tap_root/Formula/voicelayer.rb" <<EOF
class Voicelayer < Formula
  url "https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-$formula_version.tgz"
end
EOF
    cat > "$tap_root/Casks/voicebar.rb" <<EOF
cask "voicebar" do
  version "$cask_version"
  sha256 "abc123"
end
EOF
}

write_signature_tools() {
    local bin_dir="$1"
    local mode="$2"
    cat > "$bin_dir/codesign" <<EOF
#!/usr/bin/env bash
case "$mode:\$*" in
  developer-id:*-dvvv*)
    printf 'Authority=Developer ID Application: Etan Heyman (PPN23G925Y)\\nAuthority=Developer ID Certification Authority\\nAuthority=Apple Root CA\\nTeamIdentifier=PPN23G925Y\\nRuntime Version=14.0.0\\n' >&2
    ;;
  developer-id:*-d\\ -r-*)
    printf 'designated => identifier "com.voicelayer.voicebar" and certificate leaf[subject.OU] = "PPN23G925Y"\\n' >&2
    ;;
  apple-development:*-dvvv*)
    printf 'Authority=Apple Development: Etan Heyman (DXHB5E7P2D)\\nTeamIdentifier=DXHB5E7P2D\\n' >&2
    ;;
  apple-development:*-d\\ -r-*)
    printf 'designated => identifier "com.voicelayer.voicebar" and certificate leaf[subject.OU] = "DXHB5E7P2D"\\n' >&2
    ;;
  *)
    exit 2
    ;;
esac
EOF
    cat > "$bin_dir/xcrun" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "stapler" && "$2" == "validate" ]]; then
    exit 0
fi
exit 2
EOF
    cat > "$bin_dir/xattr" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "$bin_dir/codesign" "$bin_dir/xcrun" "$bin_dir/xattr"
}

write_forbidden_xattr_tool() {
    local bin_dir="$1"
    cat > "$bin_dir/xattr" <<'EOF'
#!/usr/bin/env bash
printf '%s: com.apple.macl:\n' "$2/Contents/MacOS/VoiceBar"
EOF
    chmod 755 "$bin_dir/xattr"
}

make_release_fixture() {
    local temp_dir="$1"
    local plist_version="$2"
    local package_version="$3"
    local formula_version="$4"
    local cask_version="$5"

    mkdir -p "$temp_dir/VoiceBar.app/Contents/Resources"
    write_info_plist "$temp_dir/VoiceBar.app/Contents/Info.plist" "$plist_version"
    printf '{"version":"%s"}\n' "$package_version" > "$temp_dir/VoiceBar.app/Contents/Resources/package.json"
    printf 'zip-placeholder\n' > "$temp_dir/VoiceBar.zip"
    write_tap "$temp_dir/tap" "$formula_version" "$cask_version"
}

run_verify() {
    local temp_dir="$1"
    local version="${2:-$CANONICAL_VERSION}"
    PATH="$temp_dir/bin:$PATH" "$VERIFY_SCRIPT" \
        --version "$version" \
        --app "$temp_dir/VoiceBar.app" \
        --zip "$temp_dir/VoiceBar.zip" \
        --tap-root "$temp_dir/tap"
}

if [[ ! -x "$VERIFY_SCRIPT" ]]; then
    fail "scripts/verify-voicebar-release.sh must exist and be executable"
fi

test_release_verifier_accepts_fully_aligned_artifact() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    mkdir -p "$temp_dir/bin"
    make_release_fixture "$temp_dir" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION"
    write_signature_tools "$temp_dir/bin" "developer-id"
    local out_file="$temp_dir/verify-ok.out"
    local err_file="$temp_dir/verify-ok.err"

    run_verify "$temp_dir" >"$out_file" 2>"$err_file" || {
        cat "$out_file"
        cat "$err_file" >&2
        rm -rf "$temp_dir"
        fail "aligned artifact should pass release verification"
    }
    rm -rf "$temp_dir"
}

test_release_verifier_rejects_plist_package_mismatch() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    mkdir -p "$temp_dir/bin"
    make_release_fixture "$temp_dir" "0.0.0" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION"
    write_signature_tools "$temp_dir/bin" "developer-id"
    local out_file="$temp_dir/verify-mismatch.out"
    local err_file="$temp_dir/verify-mismatch.err"

    if run_verify "$temp_dir" >"$out_file" 2>"$err_file"; then
        rm -rf "$temp_dir"
        fail "plist/package mismatch should fail release verification"
    fi
    grep -q "CFBundleShortVersionString" "$err_file" || {
        cat "$err_file" >&2
        rm -rf "$temp_dir"
        fail "plist/package mismatch failure should identify CFBundleShortVersionString"
    }
    rm -rf "$temp_dir"
}

test_release_verifier_rejects_formula_cask_mismatch() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    mkdir -p "$temp_dir/bin"
    make_release_fixture "$temp_dir" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "0.0.0" "$CANONICAL_VERSION"
    write_signature_tools "$temp_dir/bin" "developer-id"
    local out_file="$temp_dir/verify-tap.out"
    local err_file="$temp_dir/verify-tap.err"

    if run_verify "$temp_dir" >"$out_file" 2>"$err_file"; then
        rm -rf "$temp_dir"
        fail "formula/cask mismatch should fail release verification"
    fi
    grep -q "Formula/voicelayer.rb" "$err_file" || {
        cat "$err_file" >&2
        rm -rf "$temp_dir"
        fail "tap mismatch failure should identify Formula/voicelayer.rb"
    }
    rm -rf "$temp_dir"
}

test_release_verifier_rejects_cli_version_mismatch() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    mkdir -p "$temp_dir/bin"
    make_release_fixture "$temp_dir" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION"
    write_signature_tools "$temp_dir/bin" "developer-id"
    local out_file="$temp_dir/verify-version.out"
    local err_file="$temp_dir/verify-version.err"

    if run_verify "$temp_dir" "0.0.0" >"$out_file" 2>"$err_file"; then
        rm -rf "$temp_dir"
        fail "CLI --version mismatch should fail release verification"
    fi
    grep -q "release version input" "$err_file" || {
        cat "$err_file" >&2
        rm -rf "$temp_dir"
        fail "CLI version mismatch failure should identify release version input"
    }
    rm -rf "$temp_dir"
}

test_release_verifier_can_skip_tap_check_before_tap_bump() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    mkdir -p "$temp_dir/bin" "$temp_dir/empty-tap"
    make_release_fixture "$temp_dir" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION"
    rm -rf "$temp_dir/empty-tap/Formula" "$temp_dir/empty-tap/Casks"
    write_signature_tools "$temp_dir/bin" "developer-id"
    local out_file="$temp_dir/verify-skip.out"
    local err_file="$temp_dir/verify-skip.err"

    PATH="$temp_dir/bin:$PATH" "$VERIFY_SCRIPT" \
        --version "$CANONICAL_VERSION" \
        --app "$temp_dir/VoiceBar.app" \
        --zip "$temp_dir/VoiceBar.zip" \
        --tap-root "$temp_dir/empty-tap" \
        --skip-tap-check >"$out_file" 2>"$err_file" || {
            cat "$out_file"
            cat "$err_file" >&2
            rm -rf "$temp_dir"
            fail "skip tap check should allow artifact verification before tap bump"
        }

    grep -q "PASS: VoiceBar $CANONICAL_VERSION" "$out_file" || {
        cat "$out_file" >&2
        rm -rf "$temp_dir"
        fail "skip tap check should still verify and report the artifact"
    }

    rm -rf "$temp_dir"
}

test_release_verifier_rejects_apple_development_signature() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    mkdir -p "$temp_dir/bin"
    make_release_fixture "$temp_dir" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION"
    write_signature_tools "$temp_dir/bin" "apple-development"
    local out_file="$temp_dir/verify-dev.out"
    local err_file="$temp_dir/verify-dev.err"

    if run_verify "$temp_dir" >"$out_file" 2>"$err_file"; then
        rm -rf "$temp_dir"
        fail "Apple Development signature should fail release verification"
    fi
    grep -q "Apple Development" "$err_file" || {
        cat "$err_file" >&2
        rm -rf "$temp_dir"
        fail "signature failure should identify Apple Development"
    }
    rm -rf "$temp_dir"
}

test_release_verifier_rejects_security_extended_attributes() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    mkdir -p "$temp_dir/bin"
    make_release_fixture "$temp_dir" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION" "$CANONICAL_VERSION"
    write_signature_tools "$temp_dir/bin" "developer-id"
    write_forbidden_xattr_tool "$temp_dir/bin"
    local out_file="$temp_dir/verify-xattr.out"
    local err_file="$temp_dir/verify-xattr.err"

    if run_verify "$temp_dir" >"$out_file" 2>"$err_file"; then
        rm -rf "$temp_dir"
        fail "security extended attributes should fail release verification"
    fi
    grep -q "com.apple.macl" "$err_file" || {
        cat "$err_file" >&2
        rm -rf "$temp_dir"
        fail "xattr failure should identify com.apple.macl"
    }
    rm -rf "$temp_dir"
}

test_release_verifier_accepts_fully_aligned_artifact
test_release_verifier_rejects_plist_package_mismatch
test_release_verifier_rejects_formula_cask_mismatch
test_release_verifier_rejects_cli_version_mismatch
test_release_verifier_can_skip_tap_check_before_tap_bump
test_release_verifier_rejects_apple_development_signature
test_release_verifier_rejects_security_extended_attributes

printf 'PASS: VoiceBar release verification shell tests\n'
