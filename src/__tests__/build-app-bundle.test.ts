import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "fs";
import { join } from "path";

// Static contract tests for flow-bar/build-app.sh: every runtime asset that
// src/ resolves relative to itself MUST be bundled into Resources/, or the
// installed app silently loses a capability on the next rebuild.
//
// AIDEV-NOTE: bug class with two real hits — #241 (models/silero_vad.onnx
// missing → recording broke) and 2026-06-05 (scripts/edge-tts-words.py
// missing → all daemon TTS broke with edge-tts exit code 2).

const buildScript = readFileSync(
  join(import.meta.dir, "..", "..", "flow-bar", "build-app.sh"),
  "utf-8",
);
const packageJson = JSON.parse(
  readFileSync(join(import.meta.dir, "..", "..", "package.json"), "utf-8"),
);
const serverJson = JSON.parse(
  readFileSync(join(import.meta.dir, "..", "..", "server.json"), "utf-8"),
);
const entitlementsPath = join(
  import.meta.dir,
  "..",
  "..",
  "flow-bar",
  "bundle",
  "VoiceBar.entitlements",
);
const infoPlistPath = join(
  import.meta.dir,
  "..",
  "..",
  "flow-bar",
  "bundle",
  "Info.plist",
);

function plistString(plist: string, key: string): string | undefined {
  const match = plist.match(
    new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`),
  );
  return match?.[1];
}

describe("build-app.sh bundles runtime assets", () => {
  test("bundles the Silero VAD model (regression: #241)", () => {
    expect(buildScript).toContain("models/silero_vad.onnx");
    expect(buildScript).toMatch(/cp -R "\$REPO_ROOT\/models"/);
  });

  test("bundles scripts/edge-tts-words.py (TTS word-boundary synth)", () => {
    // tts.ts resolves ../scripts/edge-tts-words.py relative to bundled src/
    expect(buildScript).toContain("scripts/edge-tts-words.py");
    expect(buildScript).toMatch(
      /cp .*edge-tts-words\.py.*Resources\/scripts|cp .*"\$APP_DIR\/Contents\/Resources\/scripts"/,
    );
  });

  test("bundles daemon production dependencies beside the bundled src", () => {
    expect(packageJson.files).toContain("bun.lock");
    expect(buildScript).toContain('require_bundle_file "bun.lock"');
    expect(buildScript).toContain("node_modules/zod");
    expect(buildScript).toContain("node_modules/@modelcontextprotocol");
    expect(buildScript).toMatch(
      /bun install --production --frozen-lockfile --cwd "\$APP_DIR\/Contents\/Resources"/,
    );
  });

  test("bundles every file required by the F5 hidutil installer", () => {
    expect(buildScript).toContain("scripts/install-voicebar-f5-hidutil.sh");
    expect(buildScript).toContain("scripts/apply-voicebar-f5-hidutil.sh");
    expect(buildScript).toContain("launchd/com.voicelayer.f5-to-f18-hidutil.plist");
    expect(buildScript).toContain("require_bundle_file");
    expect(buildScript).toMatch(/exit 1/);
  });

  test("npm package includes bundle metadata needed by build-app", () => {
    expect(packageJson.files).toContain("flow-bar/bundle/");
  });
});

describe("build-app.sh Developer ID release contract", () => {
  test("preserves the canonical bundle directory while replacing its contents in place", () => {
    expect(buildScript).toContain("clear_app_bundle_for_rebuild");
    expect(buildScript).toContain(
      'find "$APP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +',
    );
    expect(buildScript).not.toContain('rm -rf "$APP_DIR"');
  });

  test("uses the Developer ID Application identity with hardened runtime and a real timestamp", () => {
    expect(buildScript).toContain(
      "Developer ID Application: Etan Heyman (PPN23G925Y)",
    );
    expect(buildScript).not.toContain(
      "Apple Development: Etan Heyman (DXHB5E7P2D)",
    );
    expect(buildScript).toContain("--options runtime");
    expect(buildScript).toContain("--timestamp");
    expect(buildScript).not.toContain("--timestamp=none");
    expect(buildScript).not.toContain("--deep --options runtime");
  });

  test("fails loudly instead of allowing non-Developer-ID signing identities", () => {
    expect(buildScript).toContain("VOICEBAR_REQUIRED_TEAM_ID");
    expect(buildScript).toContain("VOICEBAR_REQUIRED_SIGNING_PREFIX");
    expect(buildScript).toContain("validate_signing_identity");
    expect(buildScript).toContain("security find-identity");
    expect(buildScript).toContain("Refusing to sign VoiceBar with non-Developer-ID identity");
    expect(buildScript).toContain("verify_developer_id_signature");
  });

  test("cleans throwaway VoiceBar bundles out of LaunchServices registration", () => {
    expect(buildScript).toContain("unregister_throwaway_bundle");
    expect(buildScript).toContain("lsregister");
    expect(buildScript).toContain("-u \"$APP_DIR\"");
    expect(buildScript).toContain("Skipping LaunchServices unregister for resident app");
  });

  test("signs hardened-runtime VoiceBar with microphone entitlement", () => {
    expect(existsSync(entitlementsPath)).toBe(true);
    const entitlements = readFileSync(entitlementsPath, "utf-8");
    expect(entitlements).toContain(
      "com.apple.security.device.audio-input",
    );
    expect(entitlements).toContain("<true/>");
    expect(buildScript).toContain("VOICEBAR_ENTITLEMENTS");
    expect(buildScript).toContain("--entitlements");
    expect(buildScript).toMatch(
      /--entitlements "\$VOICEBAR_ENTITLEMENTS"/,
    );
  });

  test("signs nested Mach-O daemon dependencies before the outer app bundle", () => {
    const helperStart = buildScript.indexOf(
      "sign_nested_native_dependencies() {",
    );
    const helperEnd = buildScript.indexOf("\n}\n", helperStart);
    expect(helperStart).toBeGreaterThanOrEqual(0);
    expect(helperEnd).toBeGreaterThan(helperStart);
    const helperBody = buildScript.slice(helperStart, helperEnd);
    expect(helperBody).toContain("node_modules");
    expect(helperBody).toContain("*.node");
    expect(helperBody).toContain("*.dylib");
    expect(helperBody).toContain("Mach-O");
    expect(helperBody).toContain("codesign --force --options runtime --timestamp");

    const helperCall = buildScript.indexOf(
      "\nsign_nested_native_dependencies\n",
      helperEnd,
    );
    const outerSign = buildScript.indexOf(
      'codesign --force --options runtime --entitlements "$VOICEBAR_ENTITLEMENTS"',
    );
    expect(helperCall).toBeGreaterThan(helperEnd);
    expect(outerSign).toBeGreaterThan(helperCall);
  });

  test("stamps git provenance into the built VoiceBar Info.plist", () => {
    expect(buildScript).toContain("stamp_info_plist");
    expect(buildScript).toContain("GitCommit");
    expect(buildScript).toContain("BuildTimeUTC");
    expect(buildScript).toContain("git_commit");
    expect(buildScript).toContain("build_time_utc");
  });

  test("keeps the checked-in VoiceBar Info.plist version synced with package.json", () => {
    const infoPlist = readFileSync(infoPlistPath, "utf-8");

    expect(plistString(infoPlist, "CFBundleShortVersionString")).toBe(
      packageJson.version,
    );
    expect(plistString(infoPlist, "CFBundleVersion")).toBe(
      packageJson.version,
    );
  });

  test("keeps MCP registry metadata versions synced with package.json", () => {
    expect(serverJson.version).toBe(packageJson.version);
    expect(serverJson.packages[0].version).toBe(packageJson.version);
  });

  test("stamps VoiceBar bundle versions from the canonical package version during build", () => {
    expect(buildScript).toContain("package_version");
    expect(buildScript).toContain("CFBundleShortVersionString");
    expect(buildScript).toContain("CFBundleVersion");
    expect(buildScript).toContain("ReleaseVersion");
  });

  test("uses the VoiceBar socket override path during relaunch verification", () => {
    expect(buildScript).toContain(
      'VOICEBAR_SOCKET_PATH="${QA_VOICE_SOCKET_PATH:-${VOICEBAR_SOCKET_PATH:-/tmp/voicelayer.sock}}"',
    );
  });

  test("submits a zip to notarytool and staples the accepted ticket", () => {
    expect(buildScript).toContain("notarytool submit");
    expect(buildScript).toContain("xcrun stapler staple");
    expect(buildScript).toContain("xcrun stapler validate");
    expect(buildScript).toContain("VOICEBAR_NOTARY_PROFILE");
    expect(buildScript).toContain("VOICEBAR_NOTARY_KEYCHAIN_PROFILE");
    expect(buildScript).toContain("--keychain-profile");
    expect(buildScript).toMatch(/ditto -c -k --keepParent "\$APP_DIR"/);
  });

  test("defaults resident rebuild notarization to notary-layers and guards stapled cask apps before clobbering", () => {
    const profileInit = buildScript.indexOf(
      'VOICEBAR_NOTARY_PROFILE="${VOICEBAR_NOTARY_PROFILE:-${VOICEBAR_NOTARY_KEYCHAIN_PROFILE:-}}"',
    );
    const defaultProfile = buildScript.indexOf(
      'VOICEBAR_NOTARY_PROFILE="notary-layers"',
      profileInit,
    );
    expect(profileInit).toBeGreaterThan(0);
    expect(defaultProfile).toBeGreaterThan(profileInit);

    const guardStart = buildScript.indexOf(
      "protect_notarized_resident_before_rebuild() {",
    );
    const guardEnd = buildScript.indexOf(
      "\n}\n\ncreate_release_zip",
      guardStart,
    );
    const guardBody = buildScript.slice(guardStart, guardEnd);
    expect(guardBody).toContain("xcrun stapler validate \"$APP_DIR\"");
    expect(guardBody).toContain("notary_credentials_available");
    expect(guardBody).toContain(
      "Refusing to replace notarized /Applications/VoiceBar.app with an unnotarized local rebuild",
    );

    const parseCall = buildScript.indexOf('parse_build_app_args "$@"');
    const normalizeCall = buildScript.indexOf(
      "normalize_app_dir_path",
      parseCall,
    );
    const guardCall = buildScript.indexOf(
      "protect_notarized_resident_before_rebuild",
      normalizeCall,
    );
    const stopCall = buildScript.indexOf(
      'if [[ "$STOP_RUNNING" -eq 1 ]]',
      guardCall,
    );
    expect(parseCall).toBeGreaterThan(0);
    expect(normalizeCall).toBeGreaterThan(parseCall);
    expect(guardCall).toBeGreaterThan(normalizeCall);
    expect(stopCall).toBeGreaterThan(guardCall);
  });

  test("preflights the notary keychain profile before treating resident rebuild credentials as available", () => {
    const preflightStart = buildScript.indexOf(
      "notary_profile_credentials_available() {",
    );
    const preflightEnd = buildScript.indexOf(
      "\n}\n\nnotarytool_auth_args",
      preflightStart,
    );
    const preflightBody = buildScript.slice(preflightStart, preflightEnd);
    const skipFlag = preflightBody.indexOf(
      'if [ "${VOICEBAR_NOTARY_SKIP_PREFLIGHT:-0}" = "1" ]; then',
    );
    const notaryHistory = preflightBody.indexOf(
      'xcrun notarytool history --keychain-profile "$VOICEBAR_NOTARY_PROFILE"',
    );
    expect(skipFlag).toBeGreaterThan(0);
    expect(notaryHistory).toBeGreaterThan(skipFlag);
  });

  test("requires notarization before producing a Homebrew release zip", () => {
    expect(buildScript).toContain("VOICEBAR_RELEASE_ZIP");
    expect(buildScript).toContain("VOICEBAR_REQUIRE_NOTARIZATION");
    expect(buildScript).toContain("Homebrew release zip requires notarization");
    expect(buildScript).toMatch(/ditto -c -k --keepParent "\$APP_DIR" "\$VOICEBAR_RELEASE_ZIP"/);
  });
});

describe("VoiceBar Homebrew release script contract", () => {
  const releaseScript = readFileSync(
    join(import.meta.dir, "..", "..", "scripts", "release-voicebar.sh"),
    "utf-8",
  );

  test("builds a notarized release zip from a non-resident install path", () => {
    expect(releaseScript).toContain("--install-path");
    expect(releaseScript).toContain("--no-stop");
    expect(releaseScript).toContain("--no-relaunch");
    expect(releaseScript).toContain("VOICEBAR_RELEASE_ZIP");
    expect(releaseScript).toContain("VOICEBAR_ENTITLEMENTS");
    expect(releaseScript).toContain("VOICEBAR_REQUIRE_NOTARIZATION=1");
    expect(releaseScript).toContain("VOICEBAR_NOTARY_PROFILE");
    expect(releaseScript).toContain("notary-layers");
    expect(releaseScript).toContain("VoiceBar.zip");
    expect(releaseScript).not.toContain("/Applications/VoiceBar.app");
  });

  test("prints the Homebrew cask bump inputs for EtanHey/homebrew-layers", () => {
    expect(releaseScript).toContain("EtanHey/homebrew-layers");
    expect(releaseScript).toContain("Casks/voicebar.rb");
    expect(releaseScript).toContain("sha256");
    expect(releaseScript).toContain("gh release upload");
  });

  test("runs release verification before printing the zip sha256", () => {
    const verifyIndex = releaseScript.indexOf(
      "scripts/verify-voicebar-release.sh",
    );
    const shaIndex = releaseScript.indexOf("shasum -a 256");

    expect(verifyIndex).toBeGreaterThanOrEqual(0);
    expect(shaIndex).toBeGreaterThan(verifyIndex);
  });

  test("documents coordinated Homebrew formula and cask bump inputs", () => {
    expect(releaseScript).toContain("Formula/voicelayer.rb");
    expect(releaseScript).toContain("Casks/voicebar.rb");
    expect(releaseScript).toContain("formula and cask");
  });

  test("can build a new release artifact before the tap is bumped", () => {
    expect(releaseScript).toContain("--skip-tap-check");
    expect(releaseScript).toContain("SKIP_TAP_CHECK=1");
    expect(releaseScript).toContain(
      '[[ "$SKIP_TAP_CHECK" -eq 1 && -n "$TAP_ROOT" ]]',
    );
  });
});
