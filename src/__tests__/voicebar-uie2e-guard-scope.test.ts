import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

// #416 full review C1 + C2 (HARN-GUARD). Every scenario that compiles UIE2EGate2245 builds a
// real AppDelegate, so the no-device tripwire must cover all of them, not only gate2246; and
// the QA-only sources must be compiled somewhere so they cannot silently stop building.

const SUBPROCESS_TEST_TIMEOUT_MS = 20_000;
const repoRoot = new URL("../..", import.meta.url).pathname;
const read = (...parts: string[]) => readFileSync(join(repoRoot, ...parts), "utf8");

describe("UIE2E no-device guard covers every GATE2245 scenario (C2)", () => {
  test("the QA app refuses any guarded scenario or GATE2245 build without the tripwire", () => {
    const host = read("flow-bar", "Sources", "VoiceBar", "UIE2EHost.swift");
    expect(host).toContain('static let guardedScenarios: Set<String> = ["hide1", "gate2246"]');
    expect(host).toContain("UIE2ENoDeviceGuard.isRequired(scenario: environment[\"VOICEBAR_UIE2E_SCENARIO\"]");
    expect(host).not.toMatch(/== "gate2246" \{\s*UIE2ENoDeviceGuard\.requireInstalled\(\)/);
    const gate = read("flow-bar", "Sources", "VoiceBar", "UIE2EGate2245.swift");
    // The real AppDelegate is constructed by a stored-property initializer, before init's body.
    expect(gate).toMatch(/let app: AppDelegate = \{\s*UIE2ENoDeviceGuard\.requireInstalled\(\)\s*return AppDelegate\(\)\s*\}\(\)/);
  });

  test("XCUI inserts the tripwire and its receipt for every guarded launch", () => {
    const flow = read("flow-bar", "UIE2E", "VoiceBarUIE2ETests", "VoiceBarFlowTests.swift");
    expect(flow).toContain('if gate2245Enabled || ["hide1", "gate2246"].contains(scenario) {');
    expect(flow).not.toContain('if scenario == "gate2246" {');
    const gate = read("flow-bar", "UIE2E", "VoiceBarUIE2ETests", "Gate2245Tests.swift");
    for (const prefix of ["HIDE1VIS", "GATE2246"]) {
      expect(gate).toContain(`step("${prefix} no-device guard installed before fixtures")`);
      expect(gate).toContain(`step("${prefix} no device-start or process tripwire invoked")`);
    }
  });

  test("the runner builds, verifies and passes the guard for every GATE2245 build", () => {
    const shell = read("scripts", "voicebar-ui-e2e.sh");
    expect(shell).toContain('if [[ ${VOICEBAR_UIE2E_GATE2245:-0} == 1 ]]; then\n  python3 "$repo/scripts/voicebar-ui-e2e-guard-proof.py" build "$output"');
    expect(shell).not.toContain("if [[ $scenario == gate2246 ]]; then");
    const run = read("scripts", "voicebar-ui-e2e-run.py");
    expect(run).toContain("guard.authorize(");
    expect(run).not.toContain("== 'gate2246':");
    const results = read("scripts", "voicebar-ui-e2e-results.py");
    expect(results).toContain("guard.required(scenario, app / 'Contents/Info.plist')");
    expect(results).not.toContain("if scenario == 'gate2246':\n        import importlib.util");
  });

  test("the Python guard and results suites pass", () => {
    for (const suite of ["test-voicebar-ui-e2e-guard-proof.py", "test-voicebar-ui-e2e-results.py"]) {
      const result = Bun.spawnSync(["python3", join(repoRoot, "scripts", suite)], {
        stdout: "pipe",
        stderr: "pipe",
      });
      expect({ suite, exitCode: result.exitCode, tail: result.stderr.toString().slice(-600) }).toMatchObject({
        suite,
        exitCode: 0,
      });
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

describe("QA-only sources are compiled in CI (C1)", () => {
  test("hide1 compiles without #410's capture-failure APIs; gate2246 has its own flag", () => {
    const gate = read("flow-bar", "Sources", "VoiceBar", "UIE2EGate2245.swift");
    const capture = gate.indexOf("#if VOICEBAR_UIE2E_GATE2246_CAPTURE");
    expect(capture).toBeGreaterThan(0);
    for (const api of ["microphonePromptDisabled:", "configureCaptureFailurePresentation(", "userInitiated:"]) {
      expect(gate.indexOf(api)).toBeGreaterThan(capture);
    }
    const build = read("flow-bar", "build-app.sh");
    expect(build).toContain("QA_SWIFT_FLAGS+=(-Xswiftc -DVOICEBAR_UIE2E_GATE2246_CAPTURE)");
    expect(build).toContain("GATE2246_CAPTURE requires GATE2245");
    const shell = read("scripts", "voicebar-ui-e2e.sh");
    expect(shell).toContain("gate2246) export VOICEBAR_UIE2E_GATE2245=1 VOICEBAR_UIE2E_GATE2246_CAPTURE=1 ;;");
    expect(shell).toContain("hide1) export VOICEBAR_UIE2E_GATE2245=1 VOICEBAR_UIE2E_GATE2246_CAPTURE=0 ;;");
  });

  test("build-app.sh refuses a capture flag without the GATE2245 QA build", () => {
    for (const env of [
      { VOICEBAR_QA_BUILD: "1", VOICEBAR_UIE2E_GATE2246_CAPTURE: "1" },
      { VOICEBAR_QA_BUILD: "1", VOICEBAR_UIE2E_GATE2245: "1", VOICEBAR_UIE2E_GATE2246_CAPTURE: "yes" },
    ]) {
      const result = Bun.spawnSync(
        ["bash", "-c", 'VOICEBAR_BUILD_APP_SOURCE_ONLY=1 source "$1"; configure_qa_swift_flags', "_", join(repoRoot, "flow-bar", "build-app.sh")],
        { env: { ...process.env, VOICEBAR_UIE2E_GATE2245: "0", ...env }, stdout: "pipe", stderr: "pipe" },
      );
      expect(result.exitCode).not.toBe(0);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("the compile check derives its flags from build-app.sh for hide1 and gate2246", () => {
    const result = Bun.spawnSync(["bash", join(repoRoot, "scripts", "check-voicebar-qa-compile.sh")], {
      env: { ...process.env, VOICEBAR_QA_COMPILE_DRY_RUN: "1" },
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(result.exitCode).toBe(0);
    const lines = result.stdout.toString().trim().split("\n");
    expect(lines).toEqual([
      "hide1: swift build -c release --package-path flow-bar --product VoiceBar -Xswiftc -DVOICEBAR_QA -Xswiftc -DVOICEBAR_UIE2E_GATE2245",
      "gate2246: swift build -c release --package-path flow-bar --product VoiceBar -Xswiftc -DVOICEBAR_QA -Xswiftc -DVOICEBAR_UIE2E_GATE2245 -Xswiftc -DVOICEBAR_UIE2E_GATE2246_CAPTURE",
    ]);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("CI runs the QA compile check, and the README records the #410 merge order", () => {
    const workflow = read(".github", "workflows", "ci.yml");
    expect(workflow).toContain("run: bash scripts/check-voicebar-qa-compile.sh");
    const readme = read("flow-bar", "UIE2E", "README.md");
    expect(readme).toContain("#410 must merge before #416");
    expect(readme).toContain("VOICEBAR_UIE2E_GATE2246_CAPTURE");
  });
});
