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
      expect(calls).toContain("kickstart -k gui/");
      if (mode === "missing") expect(calls).toContain("bootstrap gui/");
    }
  }, 15_000);
}
