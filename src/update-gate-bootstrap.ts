import { createConnection } from "node:net";
import { lstatSync, mkdirSync, readFileSync, rmdirSync } from "node:fs";
import { dirname } from "node:path";
import { createInterface } from "node:readline/promises";
import { getMcpSocketPath, bootstrapDiagnosticPath, updateGateFilePath } from "./paths";
import { initializeVoiceGate } from "./update-gate-admission";
import { runGatedInstall } from "./update-gate-installer";

function binary(command: string[]) {
  const r = Bun.spawnSync(command, { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 5000 });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}
function checked(command: string[]) {
  const r = binary(command);
  if (r.code !== 0) throw Error(`UNKNOWN: ${command[0]} ${command[1]} failed`);
  return r.out;
}
function processes(pattern: string): boolean {
  const r = binary(["pgrep", "-fl", pattern]);
  if (r.code === 1) return false;
  if (r.code !== 0 || !/^\d+ /m.test(r.out)) throw Error("UNKNOWN: process inventory unreadable");
  return true;
}
// Presence is deliberately conservative, including a resident whisper-server.
const audio = "(^|/| )(rec|sox|afplay|whisper-server)( |$)";
const native = "(^|/| )VoiceBar( |$)";
const owners = `${native}|(^|/| )voicelayer-mcp( |$)|src/mcp-server(-daemon)?\\.ts|src/cli/(speak|ask|converse)\\.ts`;
const direct = "src/cli/(speak|ask|converse)\\.ts";
function assertLegacyGateMissing(): void {
  for (const suffix of ["", ".admissions", ".bootstrap", ".voice-diag.json", ".lock"]) {
    try { lstatSync(updateGateFilePath() + suffix); throw Error("UNKNOWN: existing gate requires recovery"); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  }
}
async function legacyHealth(): Promise<Record<string, unknown> | null> {
  return await new Promise(resolve => {
    const socket = createConnection(getMcpSocketPath()); let buffer = "";
    const finish = (value: Record<string, unknown> | null) => { clearTimeout(timer); socket.destroy(); resolve(value); };
    const timer = setTimeout(() => finish(null), 500);
    socket.on("connect", () => socket.write('{"cmd":"health","type":"health"}\n'));
    socket.on("data", bytes => {
      buffer += bytes.toString();
      if (buffer.length > 65536) return finish(null);
      if (!buffer.includes("\n")) return;
      try {
        const value = JSON.parse(buffer.split("\n")[0]!);
        finish(value?.type === "health" ? value : null);
      } catch { finish(null); }
    });
    socket.on("error", () => finish(null)); socket.on("end", () => finish(null));
  });
}
async function confirmAtMac(): Promise<boolean> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw Error("TTY confirmation required at this Mac");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return (await rl.question("Supervised legacy bootstrap: finish voice work; do not start voice, log in, or launch VoiceBar until complete. Recovery audio is preserved. Type AT THIS MAC to continue: ")).trim() === "AT THIS MAC";
  } finally { rl.close(); }
}
/** Explicit supervision is the admission boundary legacy builds cannot enforce. */
export async function runSupervisedBootstrap(command: string[], confirm = confirmAtMac, settleMs = 2000): Promise<number> {
  if (confirm !== confirmAtMac && process.env.VOICELAYER_TEST_ISOLATED !== "1") throw Error("TTY confirmation cannot be replaced outside isolated tests");
  if (!await confirm()) throw Error("UNKNOWN: supervised bootstrap declined");
  if (confirm === confirmAtMac && (command[0] !== "bash" || !command[1]?.endsWith("/scripts/voicelayer-update.sh"))) throw Error("UNKNOWN: bootstrap requires the approved update reconciliation script");
  if (!/^[0-9a-f]{40}$/.test(process.env.VOICELAYER_UPDATE_TARGET_SHA ?? "")) throw Error("UNKNOWN: target SHA required");
  assertLegacyGateMissing();
  const mutex = updateGateFilePath() + ".bootstrap-lock";
  mkdirSync(dirname(mutex), { recursive: true, mode: 0o700 });
  try { mkdirSync(mutex, { mode: 0o700 }); }
  catch { throw Error("UNKNOWN: another bootstrap or recovery owns this host"); }
  console.error("[update-gate] evidence source: supervised-bootstrap; no force-stop; Cancel: Ctrl-C");
  let cancelled = false, committed = false, phase = "", since = 0;
  const cancel = () => { cancelled = true; };
  process.on("SIGINT", cancel); process.on("SIGTERM", cancel);
  const domain = `gui/${process.getuid!()}`;
  const labels = ["com.voicelayer.voicebar", "com.voicelayer.mcp-daemon"];
  const changed: string[] = [];
  const unloaded: string[] = [];
  function disabled(label: string): boolean {
    const out = checked(["launchctl", "print-disabled", domain]);
    if (!/\{[\s\S]*\}/.test(out)) throw Error("UNKNOWN: launchd disabled inventory unreadable");
    const match = out.match(new RegExp(`"${label.replaceAll(".", "\\.")}"\\s*=>\\s*(true|false)`));
    return match?.[1] === "true"; // Absent from a successful listing means enabled.
  }
  function loaded(label: string): boolean {
    const r = binary(["launchctl", "print", `${domain}/${label}`]);
    if (r.code === 0) return true;
    if (/Could not find (specified )?service/i.test(r.err)) return false;
    throw Error("UNKNOWN: launchd inventory unreadable");
  }
  function ready(): boolean {
    return !processes(audio) && !processes(owners) && labels.every(label => disabled(label) && !loaded(label));
  }
  async function idlePhase(): Promise<string> {
    if (processes(audio)) return "audio/decoding";
    if (processes(direct)) return "direct CLI voice work";
    const health = await legacyHealth();
    if (health && (!Number.isInteger(health.queue_depth) || Number(health.queue_depth) < 0 ||
      !["idle", "recording", "transcribing"].includes(String(health.recording_state)))) return "UNKNOWN legacy health";
    if (health && health.recording_state !== "idle") return String(health.recording_state);
    if (health && health.queue_depth !== 0) return "queued speech";
    let line: string;
    try { line = readFileSync(bootstrapDiagnosticPath(), "utf8").split("\n").filter(s => s.includes("[diag]")).at(-1) ?? ""; }
    catch { return "UNKNOWN diagnostics"; }
    if (/state_transcribing|voiceMode=transcribing/.test(line)) return "transcribing";
    const mode = line.match(/voiceMode=(\w+)/)?.[1];
    if (mode && mode !== "idle") return `native ${mode}`;
    if (!/voiceMode=idle(?:\s|$)|\[diag\] state_idle(?:\s|$)/.test(line)) return "UNKNOWN/busy diagnostics";
    return health ? "idle" : "idle (socket UNKNOWN; human + clean process/diagnostic evidence)";
  }
  try {
    while (!cancelled) {
      let next: string;
      try { next = await idlePhase(); } catch { next = "UNKNOWN process evidence"; }
      if (next !== phase) { console.error(`[update-gate] Update when idle: ${next}; Cancel: Ctrl-C`); phase = next; }
      if (!next.startsWith("idle")) since = 0;
      else if (!since) since = Date.now();
      else if (Date.now() - since >= settleMs) break;
      await Bun.sleep(50);
    }
    if (cancelled) return 130;
    // disable never unloads or signals a running job. Do not bootout live owners.
    for (const label of labels) if (!disabled(label)) {
      changed.push(label); checked(["launchctl", "disable", `${domain}/${label}`]);
    }
    if (cancelled) return 130;
    if (!(await idlePhase()).startsWith("idle") || labels.some(label => !disabled(label))) throw Error("UNKNOWN: idle lost after disabling autostart");
    if (cancelled) return 130;
    if (processes(native)) checked(["osascript", "-e", 'tell application id "com.voicelayer.voicebar" to quit']);
    console.error("[update-gate] Update when idle: waiting for all legacy voice owners to exit; Cancel: Ctrl-C");
    while (!cancelled && (processes(audio) || processes(owners))) await Bun.sleep(100);
    if (cancelled) return 130;
    for (const label of labels) if (loaded(label)) {
      checked(["launchctl", "bootout", `${domain}/${label}`]); unloaded.push(label);
    }
    if (!ready()) throw Error("UNKNOWN: controlled interval unavailable");
    assertLegacyGateMissing();
    initializeVoiceGate(); // G2's exclusive initialization; all commits remain G2-owned.
    const result = await runGatedInstall(command, { evidence: () => ({ phase: "supervised-bootstrap", ready: ready() }), onCommitted: () => { committed = true; } });
    return result;
  } finally {
    process.off("SIGINT", cancel); process.off("SIGTERM", cancel);
    // A committed failure retains the disabled state for supervised recovery.
    if (!committed) {
      for (const label of changed) checked(["launchctl", "enable", `${domain}/${label}`]);
      for (const label of unloaded) checked(["launchctl", "bootstrap", domain, `${process.env.HOME}/Library/LaunchAgents/${label}.plist`]);
    }
    rmdirSync(mutex); // Only our own empty lock; a crash requires supervised recovery.
  }
}
