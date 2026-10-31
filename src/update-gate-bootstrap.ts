import { createConnection } from "node:net";
import { lstatSync, mkdirSync, readFileSync, readdirSync, rmdirSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";
import { createInterface } from "node:readline/promises";
import { getMcpSocketPath, bootstrapDiagnosticPath, updateGateFilePath } from "./paths";
import { initializeSupervisedVoiceGate } from "./update-gate-admission";
import { readUpdateGate, sameLease, type UpdateGateLease } from "./update-gate";
import { withUpdateGateLock } from "./update-gate-storage";
import { retryInstallerAcquisition, type InstallerParticipant } from "./update-gate-installer-participant";
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
// A resident decoder is an owner to wait for after normal quit, not proof of an active request.
const audio = "(^|/| )(rec|sox|afplay)( |$)";
const native = "(^|/| )VoiceBar( |$)";
const owners = `(^|/| )whisper-server( |$)|${native}|(^|/| )voicelayer-mcp( |$)|src/mcp-server(-daemon)?\\.ts|src/cli/(speak|ask|converse)\\.ts`;
const direct = "src/cli/(speak|ask|converse)\\.ts";
function assertLegacyGateMissing(): void {
  for (const suffix of ["", ".admissions", ".bootstrap", ".controller", ".voice-diag.json", ".lock"]) {
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
  let cancelled = false, committed = false, initialized = false, phase = "", since = 0;
  let requestedLease: UpdateGateLease | undefined;
  let restoreApp = "";
  const checkpoint = async () => { await Bun.sleep(1); return cancelled; };
  const cancel = () => { cancelled = true; };
  const signals = ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"] as const;
  for (const signal of signals) process.on(signal, cancel);
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
    assertLegacyGateMissing(); // Recheck after winning the supervisor mutex.
    const idleDeadline = performance.now() + 60_000;
    for (let attempt = 0; attempt < 1200 && !cancelled; attempt++) {
      if (performance.now() >= idleDeadline) throw Error("UNKNOWN: idle observation budget exhausted; voice retained");
      let next: string;
      try { next = await idlePhase(); } catch { next = "UNKNOWN process evidence"; }
      if (next !== phase) { console.error(`[update-gate] Update when idle: ${next}; Cancel: Ctrl-C`); phase = next; }
      if (!next.startsWith("idle")) since = 0;
      else if (!since) since = Date.now();
      else if (Date.now() - since >= settleMs) break;
      if (attempt === 1199) throw Error("UNKNOWN: idle observation budget exhausted; voice retained");
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
    if (processes(native)) {
      const rows = checked(["pgrep", "-fl", native]).trim().split("\n");
      const pid = rows.length === 1 ? rows[0]?.match(/^(\d+) /)?.[1] : undefined;
      if (!pid) throw Error("UNKNOWN: ambiguous legacy native owners");
      const executable = checked(["ps", "-p", pid, "-o", "comm="]).trim();
      if (!/^\/.*\.app\/Contents\/MacOS\/VoiceBar$/.test(executable)) throw Error("UNKNOWN: legacy restore bundle unavailable");
      restoreApp = executable.replace(/\/Contents\/MacOS\/VoiceBar$/, "");
      if (!lstatSync(restoreApp).isDirectory()) throw Error("UNKNOWN: legacy restore bundle missing");
      if (await checkpoint()) return 130;
      checked(["osascript", "-e", 'tell application id "com.voicelayer.voicebar" to quit']);
    }
    console.error("[update-gate] Update when idle: waiting for all legacy voice owners to exit; Cancel: Ctrl-C");
    for (let attempt = 0; !cancelled && (processes(audio) || processes(owners)); attempt++) {
      if (attempt === 49) throw Error("UNKNOWN: legacy owners did not exit; voice retained");
      await Bun.sleep(100);
    }
    if (cancelled) return 130;
    for (const label of labels) if (loaded(label)) {
      if (await checkpoint()) return 130;
      checked(["launchctl", "bootout", `${domain}/${label}`]); unloaded.push(label);
      if (await checkpoint()) return 130;
    }
    if (!ready()) throw Error("UNKNOWN: controlled interval unavailable");
    assertLegacyGateMissing();
    if (await checkpoint()) return 130;
    initialized = initializeSupervisedVoiceGate(); // G2 proves exclusive creation under G1's lock.
    if (!initialized) throw Error("UNKNOWN: bootstrap initialization refused; existing evidence retained");
    if (await checkpoint()) return 130;
    let observedReady = false, observedAt = 0;
    const sample = () => {
      observedReady = false;
      if (!ready()) throw Error("UNKNOWN: legacy controlled interval lost");
      observedAt = performance.now(); observedReady = true;
    };
    const participant: InstallerParticipant = {
      async refresh(lease) {
        sample();
        const ack = { lease, activeOperations: 0 as const, openArchives: 0 as const };
        return { phase: "supervised-bootstrap", ready: true, native: ack, daemon: ack };
      },
      // G1 lock callbacks must never spawn processes or throw on external evidence.
      verify: () => observedReady && performance.now() - observedAt <= 1000,
      async withAcquisitionProof(read) {
        sample();
        const result = await retryInstallerAcquisition(read, observedAt + 250);
        sample();
        return result;
      },
      async quit() { sample(); }, // Already normally quit; never signal a second time.
    };
    const result = await runGatedInstall(command, undefined, { participant, cancelled: () => cancelled,
      onRequested: lease => { requestedLease = lease; }, onCommitted: () => { committed = true; } });
    return result;
  } finally {
    const failures: unknown[] = [];
    const attempt = (work: () => void) => { try { work(); } catch (error) { failures.push(error); } };
    if (!committed && initialized) attempt(() => {
      // Never reset an arbitrary OPEN state. Remove only our initial generation or
      // G2's exact CANCEL result, with an empty ledger and no fault/controller.
      const refusal = withUpdateGateLock(path => {
        try {
          const state = readUpdateGate(JSON.parse(readFileSync(path, "utf8")));
          if (state.kind !== "OPEN" || (requestedLease ? !state.released || !sameLease(state.released, requestedLease)
            : state.generation !== 0 || state.released !== null)) return "gate ownership changed";
          for (const suffix of [".voice-diag.json", ".controller"]) {
            try { lstatSync(path + suffix); return "fault/controller retained"; }
            catch (error) { if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") return "evidence unreadable"; }
          }
          const ledger = lstatSync(path + ".admissions");
          if (lstatSync(path).isSymbolicLink() || !ledger.isDirectory() || ledger.isSymbolicLink() || readdirSync(path + ".admissions").length)
            return "admissions retained";
        } catch { return "cleanup evidence unreadable"; }
        unlinkSync(path); rmdirSync(path + ".admissions");
        return null;
      });
      if (refusal) throw Error(`RECOVERY_REQUIRED: bootstrap retry refused: ${refusal}`);
    });
    if (!committed) {
      for (const label of changed) attempt(() => { checked(["launchctl", "enable", `${domain}/${label}`]); });
      for (const label of unloaded) attempt(() => { checked(["launchctl", "bootstrap", domain, `${process.env.HOME}/Library/LaunchAgents/${label}.plist`]); });
    }
    // Gate faults never cost dictation: restore the observed app even after a
    // committed installer fault. Admission stays closed; no synthetic reopen.
    if (restoreApp) {
      try {
        if (!processes(native)) checked(["open", restoreApp]);
        let restored = false;
        for (let attempt = 0; attempt < 50; attempt++) {
          if (processes(native)) { restored = true; break; }
          await Bun.sleep(100);
        }
        if (!restored) throw Error("RECOVERY_REQUIRED: observed VoiceBar did not return");
      } catch (error) { failures.push(error); }
    }
    attempt(() => rmdirSync(mutex)); // Only our own empty supervisor lock, never G1's or another owner's.
    for (const signal of signals) process.off(signal, cancel);
    if (failures.length) throw new AggregateError(failures,
      `UNKNOWN: legacy restoration incomplete: ${failures.map(error => String(error)).join("; ")}`);
  }
}
