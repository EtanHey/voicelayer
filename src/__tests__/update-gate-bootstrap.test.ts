import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, unlinkSync, readdirSync, utimesSync } from "node:fs";
import { join } from "node:path";
import { testSocket } from "./setup/test-tmp";
const repo = process.cwd();
const diagLine = (mode = "idle", at = new Date()) => `${at.toISOString()} [VoiceBar][diag] voiceMode=${mode}\n`;
let serial = 0;
const saved = { ...process.env };
afterEach(() => { for (const key of ["VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_BOOTSTRAP_DIAG_PATH", "VOICELAYER_MCP_SOCKET_PATH", "VOICELAYER_TEST_INSTALL_PROOF"]) process.env[key] = saved[key]; });
function fixture(health: unknown = { type: "health", recording_state: "idle", queue_depth: 0 }) {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "boot-")), bin = join(root, "bin");
  mkdirSync(bin);
  const gate = join(root, "gate"), diag = join(root, "diag"), log = join(root, "calls"), socket = testSocket(`b${serial++}.sock`);
  for (const [name, value] of Object.entries({ diag: diagLine(), calls: "", owners: "123 VoiceBar\n", loaded: "yes", disabled: "false", active: "" })) writeFileSync(join(root, name), value);
  const proof = join(root, "proof.json"); writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  const app = join(root, "VoiceBar.app"); mkdirSync(app);
  const scripts = {
    ps: 'if [[ "$*" == "-p 123 -o lstart= -o comm=" ]]; then echo "Sat Oct 31 09:10:11 2026 $ROOT/VoiceBar.app/Contents/MacOS/VoiceBar"; elif [[ "$*" == "-p 123 -o comm=" ]]; then echo "$ROOT/VoiceBar.app/Contents/MacOS/VoiceBar"; else exec /bin/ps "$@"; fi',
    open: 'echo "open $*" >> "$CALL_LOG"; echo "123 VoiceBar" > "$ROOT/owners"',
    pgrep: 'if [[ -f "$ROOT/post-commit-fault" ]] && /usr/bin/grep -q COMMITTED "$ROOT/gate" 2>/dev/null; then rm "$ROOT/post-commit-fault"; echo postcommit-sample >> "$CALL_LOG"; exit 2; fi; if [[ -f "$ROOT/gate" && -f "$ROOT/proof-fault" ]]; then n=$(cat "$ROOT/proof-count" 2>/dev/null || echo 0); echo $((n+1)) > "$ROOT/proof-count"; [[ "$n" -lt 2 ]] || exit 2; fi; [[ ! -f "$ROOT/pgrep-error" ]] || exit 2; if [[ "$2" == *rec* ]]; then f=active; elif [[ "$2" != *VoiceBar* ]]; then f=direct; else f=owners; fi; if [[ "$2" == *whisper-server* && -s "$ROOT/resident" ]]; then cat "$ROOT/resident"; exit 0; fi; if [[ -s "$ROOT/$f" ]]; then cat "$ROOT/$f"; exit 0; else exit 1; fi',
    launchctl: `case "$1" in
print-disabled) printf '{\\n"com.voicelayer.voicebar" => %s\\n"com.voicelayer.mcp-daemon" => %s\\n}\\n' "$(cat "$ROOT/disabled")" "$(cat "$ROOT/disabled-mcp" 2>/dev/null || echo true)";;
print) if [[ ( -f "$ROOT/loaded" && "$2" == *voicebar ) || ( -f "$ROOT/loaded-mcp" && "$2" == *mcp-daemon ) ]]; then echo "pid = 123"; echo "path = $ROOT/actual-job.plist"; [[ ! -f "$ROOT/stderr-path" ]] || printf "stderr path = %s\\n" "$(cat "$ROOT/stderr-path")"; exit 0; else echo 'Could not find service' >&2; exit 113; fi;;
disable) echo "$*" >> "$CALL_LOG"; if [[ "$2" == *voicebar ]]; then echo true > "$ROOT/disabled"; else echo true > "$ROOT/disabled-mcp"; fi; [[ ! -f "$ROOT/race" ]] || echo '456 rec' > "$ROOT/active";;
enable) echo "$*" >> "$CALL_LOG"; [[ ! -f "$ROOT/fail-enable" ]] || exit 3; if [[ "$2" == *voicebar ]]; then echo false > "$ROOT/disabled"; else echo false > "$ROOT/disabled-mcp"; fi;;
bootout) echo "$*" >> "$CALL_LOG"; if [[ "$2" == *voicebar ]]; then rm -f "$ROOT/loaded"; else rm -f "$ROOT/loaded-mcp"; fi; [[ ! -f "$ROOT/bootout-error" ]] || exit 5; [[ ! -f "$ROOT/cancel-bootout" ]] || /bin/kill -INT "$PPID"; [[ ! -f "$ROOT/after-bootout" ]] || echo '456 rec' > "$ROOT/active";;
bootstrap) echo "$*" >> "$CALL_LOG"; [[ ! -f "$ROOT/fail-bootstrap" ]] || exit 4; echo yes > "$ROOT/loaded";;
*) exit 2;; esac`,
    osascript: 'echo "quit" >> "$CALL_LOG"; if [[ ! -f "$ROOT/sticky" ]]; then : > "$ROOT/owners"; : > "$ROOT/resident"; fi',
    brew: 'if [[ -f "$ROOT/finalizer-lock" ]]; then mkdir "$ROOT/gate.lock"; ( /bin/sleep 1.7; rmdir "$ROOT/gate.lock" ) >/dev/null 2>&1 & fi; echo "install" >> "$CALL_LOG"; [[ ! -f "$ROOT/fail-install" ]] || exit 7', kill: 'echo FORBIDDEN >> "$CALL_LOG"; exit 99',
  };
  for (const [name, script] of Object.entries(scripts)) writeFileSync(join(bin, name), `#!/bin/bash\n${script}\n`, { mode: 0o755 });
  const server = Bun.listen({ unix: socket, socket: { data(s, bytes) {
    expect(JSON.parse(bytes.toString()).cmd).toBe("health");
    s.write(JSON.stringify(health) + "\n");
  } } });
  const start = (confirmed = true) => {
    process.env.VOICELAYER_TEST_INSTALL_PROOF = proof; process.env.VOICELAYER_UPDATE_GATE_PATH = gate; process.env.VOICELAYER_BOOTSTRAP_DIAG_PATH = diag; process.env.VOICELAYER_MCP_SOCKET_PATH = socket;
    const runner = join(root, "run.ts");
    writeFileSync(runner, `import { existsSync, readFileSync } from "node:fs";
if (existsSync(${JSON.stringify(join(root, "late-commit"))})) {
  const clock = performance.now.bind(performance);
  Object.defineProperty(performance, "now", { value: () => clock() +
    (existsSync(${JSON.stringify(gate)}) && JSON.parse(readFileSync(${JSON.stringify(gate)}, "utf8")).kind === "COMMITTED" ? 960 : 0) });
}
import { runSupervisedBootstrap } from ${JSON.stringify(join(repo, "src/update-gate-bootstrap.ts"))};
try { process.exitCode = await runSupervisedBootstrap([process.execPath, ${JSON.stringify(join(repo, "src/update-gate-installer.ts"))}, "brew", "install"], ${confirmed ? "async () => true" : "undefined"}, 40); }
catch (e) { console.error(String(e)); process.exitCode = 1; }`);
    return Bun.spawn([process.execPath, runner], { env: { ...process.env, ROOT: root, CALL_LOG: log, PATH: `${bin}:${process.env.PATH}`,
      VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_BOOTSTRAP_DIAG_PATH: diag, VOICELAYER_MCP_SOCKET_PATH: socket,
      VOICELAYER_TEST_INSTALL_PROOF: proof, VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: "", VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40) }, stdout: "pipe", stderr: "pipe", timeout: 4000 });
  };
  return { root, gate, log, start, server };
}
async function waitFor(f: () => boolean) {
  for (let n = 0; n < 200; n++) { if (f()) return; await Bun.sleep(10); }
  throw Error("fixture timeout");
}
async function cancel(child: ReturnType<ReturnType<typeof fixture>["start"]>) {
  child.kill("SIGINT"); expect(await child.exited).toBe(130);
  return await new Response(child.stderr).text();
}
test("busy legacy daemon waits, names transcription, never quits/unloads/installs", async () => {
  const f = fixture({ type: "health", recording_state: "transcribing", queue_depth: 0 }), c = f.start();
  try { await Bun.sleep(250); expect(readFileSync(f.log, "utf8")).toBe(""); expect(await cancel(c)).toContain("transcribing"); }
  finally { f.server.stop(true); if (c.exitCode === null) { c.kill(); await c.exited; } }
});
test("process fallback busy waits even with idle daemon", async () => {
  const f = fixture(); writeFileSync(join(f.root, "active"), "456 rec\n"); const c = f.start();
  try { await Bun.sleep(250); expect(readFileSync(f.log, "utf8")).toBe(""); expect(await cancel(c)).toContain("audio/decoding"); }
  finally { f.server.stop(true); if (c.exitCode === null) { c.kill(); await c.exited; } }
});
test("idle disables autostart before quit, verifies exit before install, records source", async () => {
  const f = fixture(); writeFileSync(join(f.root, "recovery.wav"), "retained audio"); const c = f.start();
  try {
    expect({ exit: await c.exited, err: await new Response(c.stderr).text() }).toMatchObject({ exit: 0 });
    const calls = readFileSync(f.log, "utf8");
    expect(calls.indexOf("disable ")).toBeLessThan(calls.indexOf("quit"));
    expect(calls.indexOf("bootout ")).toBeLessThan(calls.indexOf("install"));
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
    expect(JSON.parse(readFileSync(f.gate + ".controller", "utf8")).source).toBe("supervised-bootstrap");
    expect(readFileSync(join(f.root, "recovery.wav"), "utf8")).toBe("retained audio");
  } finally { f.server.stop(true); }
});
test("no interactive TTY confirmation refuses before mutation", async () => {
  const f = fixture(), c = f.start(false);
  try { expect(await c.exited).toBe(1); expect(await new Response(c.stderr).text()).toContain("TTY"); expect(readFileSync(f.log, "utf8")).toBe(""); }
  finally { f.server.stop(true); }
});
test("CLI opt-in reaches the TTY gate; default stays UNKNOWN", async () => {
  const f = fixture(); process.env.VOICELAYER_UPDATE_GATE_PATH = f.gate;
  for (const optIn of ["", "1"]) {
    const c = Bun.spawn([process.execPath, "src/update-gate-installer.ts", "brew", "install"], { env: { ...process.env, PATH: `${join(f.root, "bin")}:${process.env.PATH}`, VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: optIn }, stdout: "pipe", stderr: "pipe" });
    expect(await c.exited).toBe(1); expect(await new Response(c.stderr).text()).toContain(optIn ? "TTY" : "UNKNOWN");
  }
  f.server.stop(true); expect(readFileSync(f.log, "utf8")).toBe("");
});
test("unreadable socket refuses unless process/diag evidence is clean AND human confirmed", async () => {
  const f = fixture(null), c = f.start();
  try { expect(await c.exited).toBe(0); expect(await new Response(c.stderr).text()).toContain("socket UNKNOWN"); }
  finally { f.server.stop(true); }
  const bad = fixture(null); writeFileSync(join(bad.root, "diag"), "unreadable state"); const b = bad.start();
  try { await Bun.sleep(250); expect(readFileSync(bad.log, "utf8")).toBe(""); const output = await cancel(b); expect(output).toContain("UNKNOWN"); expect(output).toContain(join(bad.root, "diag")); expect(output).toContain("VOICELAYER_BOOTSTRAP_DIAG_PATH"); }
  finally { bad.server.stop(true); if (b.exitCode === null) { b.kill(); await b.exited; } }
});
test("Cancel during graceful quit restores autostart without killing voice owners", async () => {
  const f = fixture(); writeFileSync(join(f.root, "sticky"), "yes"); const c = f.start();
  try {
    await waitFor(() => readFileSync(f.log, "utf8").includes("quit"));
    expect(await cancel(c)).toContain("owners");
    const calls = readFileSync(f.log, "utf8"); expect(calls).toContain("enable "); expect(calls).not.toContain("install"); expect(calls).not.toContain("bootout ");
    expect(existsSync(f.gate)).toBe(false);
  } finally { f.server.stop(true); if (c.exitCode === null) { c.kill(); await c.exited; } }
});
test("idle lost after disable refuses and restores autostart before any quit", async () => {
  const f = fixture(); writeFileSync(join(f.root, "race"), "yes"); const c = f.start();
  try {
    expect(await c.exited).toBe(1); expect(await new Response(c.stderr).text()).toContain("idle lost");
    const calls = readFileSync(f.log, "utf8"); expect(calls).toContain("enable "); expect(calls).not.toContain("quit"); expect(calls).not.toContain("install");
  } finally { f.server.stop(true); }
});
test("queue depth, diagnostics and direct CLI each block independently", async () => {
  for (const signal of ["queue", "diag", "direct"]) {
    const f = fixture({ type: "health", recording_state: "idle", queue_depth: signal === "queue" ? 1 : 0 });
    if (signal === "diag") writeFileSync(join(f.root, "diag"), diagLine("transcribing"));
    if (signal === "direct") writeFileSync(join(f.root, "direct"), "456 bun src/cli/speak.ts\n");
    const c = f.start();
    try { await Bun.sleep(250); expect(readFileSync(f.log, "utf8")).toBe(""); expect(await cancel(c)).toContain(signal === "queue" ? "queued speech" : signal === "diag" ? "transcribing" : "direct CLI"); }
    finally { f.server.stop(true); if (c.exitCode === null) { c.kill(); await c.exited; } }
  }
});
test("existing/corrupt gate refuses bootstrap without autostart mutation", async () => {
  const f = fixture(); writeFileSync(f.gate, "{}"); const c = f.start();
  try { expect(await c.exited).toBe(1); expect(await new Response(c.stderr).text()).toContain("recovery"); expect(readFileSync(f.log, "utf8")).toBe(""); }
  finally { f.server.stop(true); }
});
test("unreadable process inventory stays UNKNOWN despite human confirmation", async () => {
  const f = fixture(null); writeFileSync(join(f.root, "pgrep-error"), "yes"); const c = f.start();
  try { await Bun.sleep(250); expect(readFileSync(f.log, "utf8")).toBe(""); expect(await cancel(c)).toContain("UNKNOWN process evidence"); }
  finally { f.server.stop(true); if (c.exitCode === null) { c.kill(); await c.exited; } }
});
test("busy to idle resumes, installer failure retains closed gate and disabled autostart", async () => {
  const f = fixture(); writeFileSync(join(f.root, "active"), "456 rec\n"); writeFileSync(join(f.root, "fail-install"), "yes"); const c = f.start();
  try {
    await Bun.sleep(250); expect(readFileSync(f.log, "utf8")).toBe(""); writeFileSync(join(f.root, "active"), "");
    expect(await c.exited).toBe(7); expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
    expect(readFileSync(f.log, "utf8")).not.toContain("enable ");
  } finally { f.server.stop(true); }
});
test("concurrent bootstrap cannot restore the first controller's autostart", async () => {
  const f = fixture(); writeFileSync(join(f.root, "sticky"), "yes"); const first = f.start();
  try {
    await waitFor(() => readFileSync(f.log, "utf8").includes("quit")); const before = readFileSync(f.log, "utf8"), second = f.start();
    expect(await second.exited).toBe(1); expect(await new Response(second.stderr).text()).toContain("another bootstrap");
    expect(readFileSync(f.log, "utf8")).toBe(before); await cancel(first);
  } finally { f.server.stop(true); if (first.exitCode === null) { first.kill(); await first.exited; } }
});
test("failed final recheck restores unloaded autostart without installing", async () => {
  const f = fixture(); writeFileSync(join(f.root, "after-bootout"), "yes"); const c = f.start();
  try {
    expect(await c.exited).toBe(1); const calls = readFileSync(f.log, "utf8");
    expect(calls).toContain("enable "); expect(calls).toContain("bootstrap "); expect(calls).not.toContain("install");
  } finally { f.server.stop(true); }
});
test("bootstrap update uses brew reconciliation even without cask registration", async () => {
  const c = Bun.spawn(["/bin/bash", "-c", 'source "$1"; voicebar_cask_installed() { return 1; }; detect_install_type() { echo git-checkout; }; export VOICELAYER_SUPERVISED_BOOTSTRAP=1; voicebar_app_update_mode', "_", join(repo, "scripts/voicelayer-update.sh")], { env: { ...process.env }, stdout: "pipe", stderr: "pipe" });
  expect(await c.exited).toBe(0); expect((await new Response(c.stdout).text()).trim()).toBe("cask-sync");
});


test("R1 restoration attempts every service and releases only its bootstrap mutex", async () => {
  const f = fixture();
  for (const file of ["two-jobs", "after-bootout", "fail-enable", "fail-bootstrap"]) writeFileSync(join(f.root, file), "yes");
  writeFileSync(join(f.root, "disabled-mcp"), "false"); writeFileSync(join(f.root, "loaded-mcp"), "yes");
  const c = f.start();
  try {
    expect(await c.exited).toBe(1);
    const calls = readFileSync(f.log, "utf8"), err = await new Response(c.stderr).text();
    expect(calls.match(/^enable /gm)?.length).toBe(2);
    expect(calls.match(/^bootstrap /gm)?.length).toBe(2);
    expect(err).toContain("restoration incomplete");
    expect(err).toContain("enable"); expect(err).toContain("bootstrap");
    expect(existsSync(f.gate + ".bootstrap-lock")).toBe(false);
  } finally { f.server.stop(true); }
});

test("R1 cancelled bootout cannot commit or install and permits a fresh retry", async () => {
  const f = fixture(); writeFileSync(join(f.root, "cancel-bootout"), "yes"); const c = f.start();
  try {
    expect(await c.exited).toBe(130);
    expect(readFileSync(f.log, "utf8")).not.toContain("install");
    expect(existsSync(f.gate)).toBe(false);
    unlinkSync(join(f.root, "cancel-bootout"));
    expect(await f.start().exited).toBe(0);
  } finally { f.server.stop(true); }
});

test("R1 evidence fault refuses outside the gate lock and bootstrap remains retryable", async () => {
  const f = fixture(); writeFileSync(join(f.root, "proof-fault"), "yes"); const c = f.start();
  try {
    expect(await c.exited).toBe(1);
    expect(existsSync(f.gate + ".lock")).toBe(false);
    expect(existsSync(f.gate + ".voice-diag.json")).toBe(false);
    expect(existsSync(f.gate)).toBe(false);
    expect(readFileSync(f.log, "utf8")).not.toContain("install");
    unlinkSync(join(f.root, "proof-fault"));
    expect(await f.start().exited).toBe(0);
  } finally { f.server.stop(true); }
});

test("R1 resident whisper exits with its native owner instead of blocking idle bootstrap", async () => {
  const f = fixture(); writeFileSync(join(f.root, "resident"), "456 whisper-server\n");
  const c = f.start();
  try { expect(await c.exited).toBe(0); expect(readFileSync(f.log, "utf8")).toContain("install"); }
  finally { f.server.stop(true); }
});

test("R1 durable COMMIT survives a post-acquisition sample failure without legacy restoration", async () => {
  const f = fixture();
  writeFileSync(join(f.root, "post-commit-fault"), "yes");
  writeFileSync(join(f.root, "disabled-mcp"), "false");
  writeFileSync(join(f.root, "loaded-mcp"), "yes");
  const c = f.start();
  try {
    expect(await c.exited).toBe(1);
    const calls = readFileSync(f.log, "utf8"), err = await new Response(c.stderr).text();
    expect(calls).toContain("postcommit-sample");
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
    expect(calls).not.toContain("enable ");
    expect(calls).not.toContain("bootstrap ");
    expect(calls).not.toContain("install");
    expect(err).toContain("admission retained closed");
    expect(err).not.toContain("precommit Cancel");
    expect(existsSync(f.gate + ".controller")).toBe(true);
    expect(existsSync(f.gate + ".lock")).toBe(false);
    expect(existsSync(f.gate + ".bootstrap-lock")).toBe(false);
    const receipt = readdirSync(f.root).find(name => name.startsWith("gate.recovery-"));
    expect(receipt).toBeDefined();
    expect(JSON.parse(readFileSync(join(f.root, receipt!), "utf8")).reason).toContain("installer failed");
  } finally { f.server.stop(true); }
});

test("R1 loaded legacy stderr diagnostics can establish idle when the default has no diag", async () => {
  const f = fixture(), legacy = join(f.root, "legacy-err.log");
  writeFileSync(join(f.root, "stderr-path"), legacy);
  writeFileSync(join(f.root, "diag"), "no diagnostic here\n");
  writeFileSync(legacy, diagLine());
  const c = f.start();
  try { expect(await c.exited).toBe(0); expect(readFileSync(f.log, "utf8")).toContain("install"); }
  finally { f.server.stop(true); }
});

for (const newest of ["legacy", "default"]) test(`R1 newest diagnostic wins across legacy and default logs: ${newest}`, async () => {
  const f = fixture(), legacy = join(f.root, "legacy-err.log"), fallback = join(f.root, "diag");
  writeFileSync(join(f.root, "stderr-path"), legacy);
  writeFileSync(legacy, diagLine(newest === "legacy" ? "transcribing" : "idle", newest === "legacy" ? new Date() : new Date(1000)));
  writeFileSync(fallback, diagLine(newest === "default" ? "transcribing" : "idle", newest === "default" ? new Date() : new Date(1000)));
  utimesSync(newest === "legacy" ? fallback : legacy, 1, 1);
  const c = f.start();
  try { await Bun.sleep(250); expect(readFileSync(f.log, "utf8")).toBe(""); expect(await cancel(c)).toContain("transcribing"); }
  finally { f.server.stop(true); if (c.exitCode === null) { c.kill(); await c.exited; } }
});

for (const fault of ["no-job", "wrong-pid", "old-line", "fresh-nondiag"]) test(`R2 stale diagnostics cannot prove idle: ${fault}`, async () => {
  const f = fixture(null);
  if (fault === "no-job") unlinkSync(join(f.root, "loaded"));
  if (fault === "wrong-pid") {
    const path = join(f.root, "bin/launchctl");
    writeFileSync(path, readFileSync(path, "utf8").replace("pid = 123", "pid = 999"));
  }
  if (fault !== "wrong-pid") {
    const old = new Date(Date.now() - 365 * 86400_000);
    writeFileSync(join(f.root, "diag"), diagLine("idle", old) + (fault === "fresh-nondiag" ? "fresh unrelated log\n" : ""));
    if (fault === "no-job") utimesSync(join(f.root, "diag"), old, old);
  }
  const c = f.start();
  try {
    await Bun.sleep(400);
    expect(readFileSync(f.log, "utf8")).toBe("");
    expect(await cancel(c)).toContain("UNKNOWN");
    expect(existsSync(f.gate)).toBe(false);
  } finally { f.server.stop(true); if (c.exitCode === null) { c.kill(); await c.exited; } }
});

test("R2 failed-but-effective bootout reloads the actual loaded plist", async () => {
  const f = fixture(); writeFileSync(join(f.root, "bootout-error"), "yes");
  const c = f.start();
  try {
    expect(await c.exited).toBe(1);
    expect(existsSync(join(f.root, "loaded"))).toBe(true);
    expect(readFileSync(join(f.root, "disabled"), "utf8").trim()).toBe("false");
    expect(readFileSync(f.log, "utf8")).toContain(`${f.root}/actual-job.plist`);
    expect(readFileSync(f.log, "utf8")).not.toContain("install");
  } finally { f.server.stop(true); }
});

test("R2 successful COMMIT finalizer never reads G1 again", async () => {
  const f = fixture(); writeFileSync(join(f.root, "finalizer-lock"), "yes");
  const c = f.start();
  try {
    expect({ exit: await c.exited, err: await new Response(c.stderr).text() }).toMatchObject({ exit: 0 });
    expect(readFileSync(f.log, "utf8")).toContain("install");
    expect(readFileSync(f.log, "utf8")).not.toContain("enable ");
    await waitFor(() => !existsSync(f.gate + ".lock"));
  } finally { f.server.stop(true); }
});

test("R2 bootstrap COMMIT readback outlives the pre-sample deadline", async () => {
  const f = fixture(); writeFileSync(join(f.root, "late-commit"), "yes");
  const c = f.start();
  try {
    expect({ exit: await c.exited, err: await new Response(c.stderr).text() }).toMatchObject({ exit: 0 });
    expect(readFileSync(f.log, "utf8")).toContain("install");
  } finally { f.server.stop(true); }
});

for (const zone of ["local", "offset"]) test(`R2 NSLog diagnostic timestamp format: ${zone}`, async () => {
  const f = fixture(null);
  const date = new Date();
  const stamp = zone === "offset" ? date.toISOString().replace("T", " ").replace("Z", " +0000")
    : new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().replace("T", " ").replace("Z", "");
  writeFileSync(join(f.root, "diag"), `${stamp} VoiceBar[123:456] [VoiceBar][diag] state_idle voiceMode=idle\n`);
  const c = f.start();
  try { expect({ exit: await c.exited, err: await new Response(c.stderr).text() }).toMatchObject({ exit: 0 }); }
  finally { f.server.stop(true); }
});
