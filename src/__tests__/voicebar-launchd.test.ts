import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const helper = join(process.cwd(), "scripts/lib/voicebar-launchagent.sh");
for (const mode of ["loaded", "missing", "not-running", "wrong-pid"] as const) {
  test(`resident restore is launchd-owned: ${mode}`, () => {
    const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "launch-")), bin = join(root, "bin");
    mkdirSync(bin);
    const home = join(root, "home"); mkdirSync(home);
    const log = join(root, "calls"); writeFileSync(log, "");
    const fakes = {
      launchctl: `echo "$*" >> "$CALLS"
case "$1" in
 print) [[ "$MODE" != missing || -f "$ROOT/started" ]] || exit 113
 if [[ "$MODE" == not-running ]]; then echo 'state = waiting'; else echo 'state = running'; fi
 echo "pid = 42";;
 bootstrap) touch "$ROOT/started";;
 kickstart) touch "$ROOT/started";;
esac`,
      pgrep: '[[ -f "$ROOT/started" ]] || exit 1; [[ "$MODE" != wrong-pid ]] && echo 42 || echo 99',
      ps: 'echo /Applications/VoiceBar.app/Contents/MacOS/VoiceBar',
      sleep: 'exit 0',
      open: 'echo FORBIDDEN_OPEN >> "$CALLS"; exit 99',
    };
    for (const [name, body] of Object.entries(fakes)) writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
    const script = `source "$HELPER"; source "$GATE"; VOICELAYER_GATE_RESTORE_APP=/Applications/VoiceBar.app; VOICELAYER_GATE_RESTORE_LAUNCHD=1; vl_gate_restore_voicebar`;
    const result = Bun.spawnSync(["/bin/bash", "-c", script], { env: { ...process.env, ROOT: root, HOME: home,
      HELPER: helper, GATE: join(process.cwd(), "scripts/lib/update-gate.sh"), PATH: `${bin}:/usr/bin:/bin`, MODE: mode, CALLS: log, VOICEBAR_LAUNCH_WAIT_ATTEMPTS: "2" }, stdout: "pipe", stderr: "pipe" });
    const calls = readFileSync(log, "utf8");
    expect(calls).not.toContain("FORBIDDEN_OPEN");
    if (mode === "not-running" || mode === "wrong-pid") {
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr.toString()).toContain("launchd");
    } else {
      expect(result.exitCode).toBe(0);
      expect(calls).not.toContain("kickstart -k");
      if (mode === "missing") expect(calls).not.toContain("kickstart ");
      if (mode === "missing") expect(calls).toContain("bootstrap gui/");
    }
  }, 15_000);
}

for (const mode of ["recording", "bootstrap-running", "scoped", "slow", "crash", "pid-churn", "unmanaged"] as const) {
  test(`R2 safe start and stable verify: ${mode}`, () => {
    const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "launch-r2-")), bin = join(root, "bin");
    mkdirSync(bin); const home = join(root, "home"); mkdirSync(home);
    const log = join(root, "calls"); writeFileSync(log, "");
    if (mode === "recording") writeFileSync(join(root, "recording"), "live capture must survive");
    const fakes = {
      launchctl: `echo "$*" >> "$CALLS"
case "$1" in
 print) [[ "$MODE" != bootstrap-running || -f "$ROOT/booted" ]] || exit 113
 n=$(cat "$ROOT/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$ROOT/count"
 [[ "$MODE" != slow || "$n" -ge 55 ]] || { echo 'state = waiting'; exit 0; }
 [[ "$MODE" != crash || "$n" -le 1 ]] || exit 113
 echo 'state = running'
 if [[ "$MODE" == pid-churn && $((n%2)) == 0 ]]; then echo 'pid = 43'; else echo 'pid = 42'; fi;;
 bootstrap) touch "$ROOT/booted";;
 kickstart) if [[ "$2" == -k && ( "$MODE" == recording || "$MODE" == bootstrap-running ) ]]; then rm -f "$ROOT/recording"; exit 91; fi;;
esac`,
      pgrep: 'echo "pgrep $*" >> "$CALLS"; if [[ "$MODE" == scoped && "$1" != -U ]]; then printf "42\\n999\\n"; elif [[ "$MODE" == unmanaged ]]; then echo 99; elif [[ "$MODE" == pid-churn ]]; then n=$(cat "$ROOT/count"); [[ $((n%2)) == 0 ]] && echo 43 || echo 42; else echo 42; fi',
      ps: 'echo /Applications/VoiceBar.app/Contents/MacOS/VoiceBar',
      sleep: 'exit 0',
    };
    for (const [name, body] of Object.entries(fakes)) writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
    const script = mode === "unmanaged"
      ? 'source "$GATE"; VOICELAYER_GATE_RESTORE_APP=/Applications/VoiceBar.app; vl_gate_restore_voicebar'
      : mode === "scoped" ? 'source "$HELPER"; voicebar_verify_launchd /Applications/VoiceBar.app'
      : 'source "$HELPER"; voicebar_start_launchd /Applications/VoiceBar.app';
    const result = Bun.spawnSync(["/bin/bash", "-c", script], { env: { ...process.env, ROOT: root, HOME: home,
      HELPER: helper, GATE: join(process.cwd(), "scripts/lib/update-gate.sh"), PATH: `${bin}:/usr/bin:/bin`, MODE: mode, CALLS: log,
      ...(mode === "slow" ? {} : { VOICEBAR_LAUNCH_WAIT_ATTEMPTS: "3" }) }, stdout: "pipe", stderr: "pipe" });
    const calls = readFileSync(log, "utf8");
    if (["crash", "pid-churn", "unmanaged"].includes(mode)) expect(result.exitCode).not.toBe(0);
    else expect({ exit: result.exitCode, stderr: result.stderr.toString() }).toMatchObject({ exit: 0 });
    expect(calls).not.toContain("kickstart -k");
    if (mode === "recording") { expect(readFileSync(join(root, "recording"), "utf8")).toContain("survive"); expect(calls).not.toMatch(/^(enable|bootstrap|kickstart) /m); }
    if (mode === "bootstrap-running") expect(calls).not.toContain("kickstart ");
    if (mode === "scoped") expect(calls).toContain(`pgrep -U ${process.getuid!()} -x VoiceBar`);
  }, 60_000);
}
test("R2 launch wait exceeds native accepted quit and auto-f5 restore uses shared helper", () => {
  const source = readFileSync(helper, "utf8");
  const timeout = Number(source.match(/VOICEBAR_LAUNCH_WAIT_ATTEMPTS:-(\d+)/)![1]) * 0.1;
  const native = readFileSync(join(process.cwd(), "flow-bar/Sources/VoiceBar/VoiceBarDaemonController.swift"), "utf8");
  const graceful = Number(native.match(/gracefulStopTimeout: TimeInterval = ([\d.]+)/)![1]);
  expect(timeout).toBeGreaterThanOrEqual(2 * graceful + 1 + 0.1);
  const restore = readFileSync(join(process.cwd(), "scripts/auto-f5-verify.sh"), "utf8");
  expect(restore).not.toContain('kickstart_launchd_service "$VOICEBAR_LAUNCHD_LABEL"');
  expect(restore).toContain('bash "$main_root/scripts/start-voicebar.sh"');
});

test("supervised post-commit failure leaves disabled job to TS restore", () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "supervised-"));
  const log = join(root, "calls");
  writeFileSync(log, "");
  for (const name of ["launchctl", "open"]) writeFileSync(join(root, name),
    '#!/bin/bash\necho "$*" >> "$CALLS"\nexit 1\n', { mode: 0o755 });
  writeFileSync(join(root, "pgrep"), '#!/bin/bash\necho "pgrep $*" >> "$CALLS"\nexit 1\n', { mode: 0o755 });
  const result = Bun.spawnSync(["/bin/bash", "-c",
    'source "$GATE"; export VOICELAYER_GATE_RESTORE_APP=/Applications/VoiceBar.app; export VOICELAYER_INSTALL_OPERATION="$OPERATION"; trap vl_gate_restore_exit EXIT; exit 7'], {
    env: { ...process.env, PATH: root + ":/usr/bin:/bin", CALLS: log,
      HOME: root, GATE: join(process.cwd(), "scripts/lib/update-gate.sh"),
      OPERATION: JSON.stringify({ lease: { generation: 1, operationId: "11111111-1111-4111-8111-111111111111", ownerId: "22222222-2222-4222-8222-222222222222", targetSha: "a".repeat(40) }, pid: process.pid, identity: "fixture", source: "supervised-bootstrap" }),
      VOICELAYER_GATE_RESTORE_APP: "/Applications/VoiceBar.app", VOICEBAR_LAUNCH_WAIT_ATTEMPTS: "1" },
    stdout: "pipe", stderr: "pipe",
  });
  expect(result.exitCode).toBe(7);
  expect(readFileSync(log, "utf8")).not.toMatch(/^(enable|bootstrap|kickstart) /m);
});
