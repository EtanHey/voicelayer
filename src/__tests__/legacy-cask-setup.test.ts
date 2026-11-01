import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const caskTest = (name: string, body: () => void) => test(name, body, 20000);
const saved = { ...process.env };
afterEach(() => {
  for (const key of ["VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_TEST_INSTALL_PROOF"])
    if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key];
});

// Real setup + canonical installers, only host paths relocated. PATH cannot reach
// host brew, launchctl, app discovery, microphone, sockets or audio playback.
function fixture(fault = "") {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "cask-"));
  const bin = join(root, "bin"), home = join(root, "home"), app = join(root, "Applications/VoiceBar.app");
  const agents = join(home, "Library/LaunchAgents"), gate = join(root, "gate");
  for (const dir of [bin, app, agents, join(root, "src/cli"), join(root, "scripts/lib"), join(root, "launchd")])
    mkdirSync(dir, { recursive: true });
  for (const tool of ["bash", "cat", "chmod", "cp", "dirname", "basename", "id", "mkdir", "readlink", "rm", "sleep"])
    symlinkSync(Bun.which(tool)!, join(bin, tool));
  symlinkSync(process.execPath, join(bin, "bun"));
  for (const file of ["src/update-gate-installer.ts", "src/update-gate-admission.ts", "src/update-gate-storage.ts", "src/paths.ts"])
    symlinkSync(join(process.cwd(), file), join(root, file));
  for (const file of ["src/cli/voicelayer.sh", "src/cli/setup.ts", "scripts/lib/update-gate.sh",
    "scripts/install-voicebar-autostart.sh", "scripts/install-voicebar-f5-hidutil.sh", "scripts/apply-voicebar-f5-hidutil.sh",
    "launchd/com.voicelayer.voicebar.plist", "launchd/com.voicelayer.f5-to-f18-hidutil.plist"])
    writeFileSync(join(root, file), readFileSync(file, "utf8").replaceAll("/Applications", join(root, "Applications")), { mode: 0o755 });
  const stub = (name: string, body: string) => writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  stub("which", "exit 1");
  stub("pgrep", '[[ "$FAULT" != inventory ]] || exit 2; [[ -s "$ROOT/running" ]] || exit 1; cat "$ROOT/running"');
  stub("ps", 'exec /bin/ps "$@"');
  stub("plutil", '[[ "$FAULT" != persistent ]] || exit 7; if [[ ( "$FAULT" == plist || ( "$FAULT" == relay && "$*" == *f5-to-f18* ) ) && ! -f "$ROOT/failed-once" ]]; then : > "$ROOT/failed-once"; exit 7; fi');
  stub("xattr", "exit 1");
  stub("hidutil", "exit 0");
  stub("open", 'echo "open $*" >> "$ROOT/calls"; echo "$1/Contents/MacOS/VoiceBar" > "$ROOT/running"');
  stub("launchctl", `echo "$*" >> "$ROOT/calls"
case "$1" in
  remove|bootout) rm -f "$ROOT/loaded-\${2##*/}";;
  print|list) [[ -f "$ROOT/loaded-\${2##*/}" ]];;
  bootstrap) label="\${3##*/}"; label="\${label%.plist}"; : > "$ROOT/loaded-$label"
    [[ "$label" != com.voicelayer.voicebar ]] || echo "$APP/Contents/MacOS/VoiceBar" > "$ROOT/running";;
  kickstart) [[ "$*" != *com.voicelayer.voicebar* ]] || echo "$APP/Contents/MacOS/VoiceBar" > "$ROOT/running";;
  enable) :;;
  *) exit 99;;
esac`);
  // Reproduce the cask order from the incident, including rollback on failure.
  stub("brew", `for label in com.voicelayer.voicebar com.voicelayer.f5-to-f18-hidutil com.voicelayer.mcp-daemon; do
  launchctl remove "$label"
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
: > "$ROOT/running"
echo 2.2.59 > "$APP/version"
[[ "$FAULT" != running ]] || echo "$APP/Contents/MacOS/VoiceBar" > "$ROOT/running"
bash "$ROOT/src/cli/voicelayer.sh" setup
status=$?
[[ "$status" == 0 ]] || echo 2.2.58 > "$APP/version"
exit "$status"`);
  for (const label of ["com.voicelayer.voicebar", "com.voicelayer.f5-to-f18-hidutil", "com.voicelayer.mcp-daemon"]) {
    writeFileSync(join(agents, label + ".plist"), "legacy");
    writeFileSync(join(root, "loaded-" + label), "");
  }
  writeFileSync(join(app, "version"), "2.2.58");
  writeFileSync(join(root, "running"), app + "/Contents/MacOS/VoiceBar\n");
  writeFileSync(join(root, "calls"), "");
  if (fault === "malformed") writeFileSync(gate, "broken gate");
  if (fault === "protected") {
    writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
    mkdirSync(gate + ".admissions");
  }
  if (fault === "locked") mkdirSync(gate + ".lock");
  if (fault === "supervisor") mkdirSync(gate + ".bootstrap-lock");
  if (fault === "ledger") mkdirSync(gate + ".admissions");
  if (fault === "controller") writeFileSync(gate + ".controller", "retained controller");
  const proof = join(root, "proof"); writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  process.env.VOICELAYER_TEST_INSTALL_PROOF = proof;
  const env = { ...process.env, HOME: home, PATH: bin, ROOT: root, APP: app, FAULT: fault,
      VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: "", VOICELAYER_UPDATE_TARGET_SHA: "",
      VOICEBAR_LEGACY_LOG_DIR: join(root, "legacy"), VOICELAYER_TEST_BUN_CANDIDATES: process.execPath };
  const run = () => Bun.spawnSync([join(bin, "brew"), "upgrade", "--cask", "voicebar"], {
    env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe", timeout: 15000,
  });
  const autostart = () => Bun.spawnSync(["/bin/bash", join(root, "scripts/install-voicebar-autostart.sh"), "--restore-availability"], {
    env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe", timeout: 15000,
  });
  return { root, gate, app, agents, run, autostart };
}
function restored(f: ReturnType<typeof fixture>) {
  for (const label of ["com.voicelayer.voicebar", "com.voicelayer.f5-to-f18-hidutil"]) {
    expect(existsSync(join(f.agents, label + ".plist"))).toBe(true);
    expect(existsSync(join(f.root, "loaded-" + label))).toBe(true);
  }
  expect(readFileSync(join(f.root, "running"), "utf8").trim()).toBe(f.app + "/Contents/MacOS/VoiceBar");
  expect(existsSync(join(f.agents, "com.voicelayer.mcp-daemon.plist"))).toBe(false);
}
caskTest("pre-gate cask upgrade runs real setup, initializes OPEN, restores both agents and VoiceBar", () => {
  const f = fixture(), r = f.run();
  expect({ exit: r.exitCode, err: r.stderr.toString() }).toMatchObject({ exit: 0 });
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  expect(readFileSync(join(f.app, "version"), "utf8").trim()).toBe("2.2.59");
  restored(f);
});
for (const fault of ["malformed", "locked", "supervisor", "ledger", "controller", "protected", "plist", "relay"]) caskTest(`failed cask setup (${fault}) refuses but restores availability through rollback`, () => {
  const f = fixture(fault), r = f.run();
  expect(r.exitCode).not.toBe(0);
  expect(readFileSync(join(f.app, "version"), "utf8").trim()).toBe("2.2.58");
  restored(f);
  if (fault === "malformed") expect(readFileSync(f.gate, "utf8")).toBe("broken gate");
  if (fault === "locked") { expect(existsSync(f.gate)).toBe(false); expect(existsSync(f.gate + ".lock")).toBe(true); }
  if (fault === "supervisor") expect(existsSync(f.gate + ".bootstrap-lock")).toBe(true);
  if (fault === "controller") expect(readFileSync(f.gate + ".controller", "utf8")).toBe("retained controller");
  if (fault === "protected") expect(JSON.parse(readFileSync(f.gate, "utf8")).generation).toBe(0);
});
for (const fault of ["running", "inventory"]) caskTest(`legacy setup refuses ${fault} process evidence without initializing`, () => {
  const f = fixture(fault), r = f.run();
  expect(r.exitCode).not.toBe(0);
  expect(existsSync(f.gate)).toBe(false);
  expect(readFileSync(join(f.root, "calls"), "utf8")).not.toMatch(/bootstrap .*voicebar\.plist/);
});
caskTest("persistent agent failure reports recovery required and still attempts canonical app launch", () => {
  const f = fixture("persistent"), r = f.run();
  expect(r.exitCode).not.toBe(0);
  expect(r.stderr.toString()).toContain("RECOVERY_REQUIRED");
  expect(readFileSync(join(f.root, "calls"), "utf8")).toContain(`open ${f.app}`);
  expect(readFileSync(join(f.root, "running"), "utf8").trim()).toBe(f.app + "/Contents/MacOS/VoiceBar");
});
caskTest("isolated setup refuses an unrelocated app path before any recovery command", () => {
  const f = fixture(), setup = join(f.root, "src/cli/setup.ts");
  writeFileSync(setup, readFileSync(setup, "utf8").replaceAll(join(f.root, "Applications"), "/Applications"));
  const r = f.run();
  expect(r.exitCode).not.toBe(0);
  expect(r.stderr.toString()).toContain("setup app escaped isolated root");
  expect(existsSync(f.gate)).toBe(false);
  const calls = readFileSync(join(f.root, "calls"), "utf8");
  expect(calls).not.toContain("bootstrap");
  expect(calls).not.toContain("open ");
});
caskTest("startup-only installer independently refuses an unrelocated app path", () => {
  const f = fixture(), script = join(f.root, "scripts/install-voicebar-autostart.sh");
  writeFileSync(script, readFileSync(script, "utf8").replaceAll(join(f.root, "Applications"), "/Applications"));
  const r = f.autostart();
  expect(r.exitCode).not.toBe(0);
  expect(readFileSync(join(f.root, "calls"), "utf8")).toBe("");
});
