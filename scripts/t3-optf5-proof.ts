#!/usr/bin/env bun
// T3GATE1 — installed-candidate T3 Option+F5 proof for VoiceBar releases.
//
// Etan, 2026-10-18: "the fact t3 code mark+option+f5 broke like that is an unacceptable
// regression ... make sure it absolutly never happens again". The 2.2.45 regression shipped
// because the T3 check was an acceptance rule, not a publication gate. This file is both
// halves of the gate:
//
//   start  — snapshot the installed app, T3 build, log offset and time BEFORE the keypress.
//   finish — after the operator (or a harness) selects the synthetic paragraph in a rendered
//            T3 assistant message and presses Option+F5, read only what the resident wrote
//            since `start` and write the proof JSON. This script never sends input itself.
//   check  — called by scripts/verify-voicebar-release.sh before the cask bump. Refuses a
//            missing, mismatched or stale proof. There is no bypass.
//
// Evidence form is RULINGS.md 2026-10-18T02:53Z: TTS history text exact-match, a fresh
// speak_text command UUID, and no read error. Request logs stay redacted: the proof keeps
// hashes only, never the paragraph text.

import { createHash } from "crypto";
import { existsSync, openSync, readFileSync, readSync, closeSync, statSync, writeFileSync } from "fs";
import { homedir } from "os";

export const PROOF_SCHEMA = "voicelayer.t3-optf5-proof.v1";
const T3_BUNDLE_ID = "com.t3tools.t3code";
const STATE_SCHEMA = "voicelayer.t3-optf5-proof-state.v1";
// The operator selects, presses and finishes in one sitting; a longer window cannot be
// attributed to one keypress.
const MAX_WINDOW_MS = 10 * 60 * 1000;
// speak_text is accepted, synthesized and added to history within seconds of the capture.
const MAX_CAPTURE_TO_HISTORY_MS = 30 * 1000;
const MAX_FUTURE_SKEW_MS = 5 * 60 * 1000;
const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const COMMIT_RE = /^[0-9a-f]{40}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

export interface T3OptF5Proof {
  schema: string;
  gitCommit: string;
  buildTimeUTC: string;
  t3Build: string;
  timestamp: string;
  expectedTextSha256: string;
  historyTextSha256: string;
  speakTextCommandId: string;
  readError: boolean;
}

class GateError extends Error {}

const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");

function fail(message: string): never {
  throw new GateError(message);
}

// ---- check -----------------------------------------------------------------------------

export function checkProof(
  raw: unknown,
  candidate: { gitCommit: string; buildTimeUTC: string },
  now = Date.now(),
): T3OptF5Proof {
  if (!COMMIT_RE.test(candidate.gitCommit)) {
    fail(`candidate Info.plist GitCommit is missing or not a full SHA ('${candidate.gitCommit}')`);
  }
  const buildMs = ISO_RE.test(candidate.buildTimeUTC) ? Date.parse(candidate.buildTimeUTC) : NaN;
  if (!Number.isFinite(buildMs)) {
    fail(`candidate Info.plist BuildTimeUTC is missing or unparseable ('${candidate.buildTimeUTC}')`);
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) fail("proof is not a JSON object");
  const p = raw as Record<string, unknown>;
  if (p.schema !== PROOF_SCHEMA) fail(`proof schema is '${String(p.schema)}', expected '${PROOF_SCHEMA}'`);
  if (p.gitCommit !== candidate.gitCommit) {
    fail(`proof GitCommit '${String(p.gitCommit)}' does not equal candidate Info.plist GitCommit '${candidate.gitCommit}'`);
  }
  // Same commit rebuilt is a different binary; the proof covers only the build it ran on.
  if (p.buildTimeUTC !== candidate.buildTimeUTC) {
    fail(`proof BuildTimeUTC '${String(p.buildTimeUTC)}' does not equal candidate Info.plist BuildTimeUTC '${candidate.buildTimeUTC}'`);
  }
  if (typeof p.t3Build !== "string" || p.t3Build.trim() === "") fail("proof has no T3 build");
  if (typeof p.timestamp !== "string" || !ISO_RE.test(p.timestamp) || !Number.isFinite(Date.parse(p.timestamp))) {
    fail(`proof timestamp '${String(p.timestamp)}' is not an ISO-8601 UTC time`);
  }
  const proofMs = Date.parse(p.timestamp);
  if (proofMs < buildMs) {
    fail(`proof is stale: ${p.timestamp} is older than the candidate build ${candidate.buildTimeUTC}`);
  }
  if (proofMs > now + MAX_FUTURE_SKEW_MS) fail(`proof timestamp ${p.timestamp} is in the future`);
  if (typeof p.expectedTextSha256 !== "string" || !SHA_RE.test(p.expectedTextSha256)) {
    fail("proof expectedTextSha256 is not a lowercase sha256");
  }
  if (typeof p.historyTextSha256 !== "string" || !SHA_RE.test(p.historyTextSha256)) {
    fail("proof historyTextSha256 is not a lowercase sha256");
  }
  if (p.expectedTextSha256 !== p.historyTextSha256) {
    fail("expected-text sha256 does not equal TTS-history text sha256: T3 did not read the selected paragraph");
  }
  if (typeof p.speakTextCommandId !== "string" || !UUID_RE.test(p.speakTextCommandId)) {
    fail(`proof speak_text command id '${String(p.speakTextCommandId)}' is not a UUID`);
  }
  if (p.readError !== false) fail(`proof readError is ${JSON.stringify(p.readError)}, must be false`);
  return p as unknown as T3OptF5Proof;
}

// ---- artifact readers ------------------------------------------------------------------

function readPlistString(plistPath: string, key: string): string {
  if (!existsSync(plistPath)) fail(`Info.plist not found: ${plistPath}`);
  const buddy = "/usr/libexec/PlistBuddy";
  if (existsSync(buddy)) {
    const r = Bun.spawnSync([buddy, "-c", `Print :${key}`, plistPath], { stdout: "pipe", stderr: "pipe" });
    return r.exitCode === 0 ? r.stdout.toString().trim() : "";
  }
  const xml = readFileSync(plistPath, "utf8");
  const m = xml.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`));
  return m ? m[1].trim() : "";
}

function t3BuildOf(t3App: string): string {
  const plist = `${t3App}/Contents/Info.plist`;
  const bundleId = readPlistString(plist, "CFBundleIdentifier");
  if (bundleId !== T3_BUNDLE_ID) fail(`${t3App} is '${bundleId}', not ${T3_BUNDLE_ID}`);
  const name = readPlistString(plist, "CFBundleName") || t3App.replace(/^.*\//, "").replace(/\.app$/, "");
  const short = readPlistString(plist, "CFBundleShortVersionString");
  const build = readPlistString(plist, "CFBundleVersion");
  if (!short && !build) fail(`${t3App} has no version`);
  return `${name} ${short} (${build})`;
}

function installedIdentity(app: string) {
  const plist = `${app}/Contents/Info.plist`;
  const gitCommit = readPlistString(plist, "GitCommit");
  const buildTimeUTC = readPlistString(plist, "BuildTimeUTC");
  if (!COMMIT_RE.test(gitCommit)) fail(`installed ${app} has no GitCommit in Info.plist`);
  if (!ISO_RE.test(buildTimeUTC)) fail(`installed ${app} has no BuildTimeUTC in Info.plist`);
  return { gitCommit, buildTimeUTC };
}

interface ProcessRow {
  pid: number;
  ppid: number;
  command: string;
}

function processRows(): ProcessRow[] {
  const out = Bun.spawnSync(["ps", "-axo", "pid=,ppid=,command="], { stdout: "pipe", stderr: "pipe" });
  if (out.exitCode !== 0) fail("cannot list processes");
  return out.stdout
    .toString()
    .split("\n")
    .flatMap((line) => {
      const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
      return m ? [{ pid: Number(m[1]), ppid: Number(m[2]), command: m[3] }] : [];
    });
}

function processStartMs(pid: number): number {
  const out = Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(pid)], { stdout: "pipe", stderr: "pipe" });
  const parsed = out.exitCode === 0 ? Date.parse(out.stdout.toString().trim()) : NaN;
  if (!Number.isFinite(parsed)) fail(`cannot read the start time of process ${pid}`);
  return parsed;
}

// The proof must come from the installed bundle's own running processes. Info.plist on disk
// is not enough: a bundle swapped under a running VoiceBar would stamp the new GitCommit on
// events the old binary produced. Installing (copy, unzip, or brew's extract) rewrites the
// bundle files, so their ctime is the install time; both VoiceBar and its daemon child must
// have started in a later whole second (`ps lstart` has one-second resolution, so a
// same-second start cannot be proven to follow the install and fails closed).
function installedRuntime(app: string): { voiceBarPid: number; daemonPids: number[] } {
  const binary = `${app}/Contents/MacOS/VoiceBar`;
  const installedSecond = Math.floor(statSync(`${app}/Contents/Info.plist`).ctimeMs / 1000);
  const rows = processRows();
  const voiceBars = rows.filter((row) => row.command === binary || row.command.startsWith(`${binary} `));
  if (voiceBars.length === 0) fail(`no running VoiceBar from ${binary}; launch the installed candidate first`);
  if (voiceBars.length > 1) fail(`${voiceBars.length} VoiceBar processes run from ${binary}; one resident only`);
  const voiceBarPid = voiceBars[0].pid;
  const daemonPids = rows
    .filter((row) => row.ppid === voiceBarPid && row.command.includes("mcp-server-daemon"))
    .map((row) => row.pid);
  if (daemonPids.length === 0) fail(`VoiceBar ${voiceBarPid} has no running mcp-server-daemon child`);
  const processes: [string, number][] = [["VoiceBar", voiceBarPid], ...daemonPids.map((d): [string, number] => ["mcp-server-daemon", d])];
  for (const [label, pid] of processes) {
    if (Math.floor(processStartMs(pid) / 1000) <= installedSecond) {
      fail(`${label} process ${pid} is older than the installed bundle; relaunch VoiceBar after installing`);
    }
  }
  return { voiceBarPid, daemonPids };
}

function readFrom(path: string, offset: number): string {
  if (!existsSync(path)) fail(`log not found: ${path}`);
  const size = statSync(path).size;
  if (size < offset) fail(`${path} shrank since start (rotated or truncated); rerun start`);
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(size - offset);
    readSync(fd, buf, 0, buf.length, offset);
    return buf.toString("utf8");
  } finally {
    closeSync(fd);
  }
}

function loadHistory(path: string): { text: string; timestamp: number }[] {
  if (!existsSync(path)) return [];
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(raw)) fail(`${path} is not a TTS history array`);
  return raw.filter(
    (e): e is { text: string; timestamp: number } =>
      typeof e?.text === "string" && typeof e?.timestamp === "number",
  );
}

// VoiceBar's NSLog prefix: local wall-clock "YYYY-MM-DD HH:MM:SS.mmm".
function parseNSLogTime(line: string): number {
  const m = line.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})/);
  if (!m) return NaN;
  const [y, mo, d, h, mi, s, ms] = m.slice(1).map(Number);
  return new Date(y, mo - 1, d, h, mi, s, ms).getTime();
}

function expectedTextOf(path: string): string {
  if (!existsSync(path)) fail(`expected text file not found: ${path}`);
  // Editors add one final newline; the selection never carries it.
  const text = readFileSync(path, "utf8").replace(/\r?\n$/, "");
  if (text.trim() === "") fail("expected text is empty");
  return text;
}

// ---- start / finish --------------------------------------------------------------------

interface ProofState {
  schema: string;
  startedAt: number;
  app: string;
  gitCommit: string;
  buildTimeUTC: string;
  voiceBarPid: number;
  t3App: string;
  t3Build: string;
  voicebarLog: string;
  logOffset: number;
  historyFile: string;
  expectedTextSha256: string;
  // A count, not text: VoiceBar's selection_capture line logs the selection's UTF-16 length.
  expectedUtf16Count: number;
}

function start(args: Map<string, string>) {
  const app = args.get("--app") ?? "/Applications/VoiceBar.app";
  const t3App = need(args, "--t3-app");
  const voicebarLog = args.get("--voicebar-log") ?? `${homedir()}/Library/Logs/voicelayer/voicebar-err.log`;
  const historyFile = args.get("--history-file") ?? "/tmp/voicelayer-history.json";
  const statePath = need(args, "--state");
  const expected = expectedTextOf(need(args, "--expected-text-file"));
  if (!existsSync(voicebarLog)) fail(`VoiceBar log not found: ${voicebarLog}`);
  const identity = installedIdentity(app);
  const runtime = installedRuntime(app);
  const state: ProofState = {
    schema: STATE_SCHEMA,
    startedAt: Date.now(),
    app,
    gitCommit: identity.gitCommit,
    buildTimeUTC: identity.buildTimeUTC,
    voiceBarPid: runtime.voiceBarPid,
    t3App,
    t3Build: t3BuildOf(t3App),
    voicebarLog,
    logOffset: statSync(voicebarLog).size,
    historyFile,
    expectedTextSha256: sha256(expected),
    expectedUtf16Count: expected.length,
  };
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`);
  console.log(`[t3-optf5-proof] armed: VoiceBar ${state.gitCommit}, ${state.t3Build}`);
  console.log("[t3-optf5-proof] now select the synthetic paragraph in a rendered T3 assistant message,");
  console.log("[t3-optf5-proof] press Option+F5 once (output muted), wait for it to finish, then run finish.");
}

function finish(args: Map<string, string>) {
  const statePath = need(args, "--state");
  const out = need(args, "--out");
  const state = JSON.parse(readFileSync(statePath, "utf8")) as ProofState;
  if (state.schema !== STATE_SCHEMA) fail(`${statePath} is not a start state file`);
  const now = Date.now();
  if (now - state.startedAt > MAX_WINDOW_MS) fail("more than 10 minutes since start; rerun start and press again");
  const identity = installedIdentity(state.app);
  if (identity.gitCommit !== state.gitCommit || identity.buildTimeUTC !== state.buildTimeUTC) {
    fail(`installed VoiceBar changed since start (was ${state.gitCommit} built ${state.buildTimeUTC})`);
  }
  if (installedRuntime(state.app).voiceBarPid !== state.voiceBarPid) {
    fail(`the running VoiceBar changed since start (was process ${state.voiceBarPid})`);
  }

  const lines = readFrom(state.voicebarLog, state.logOffset).split("\n");
  const captures = lines
    .map((line, index) => ({ line, index }))
    .filter(({ line }) => line.includes("[VoiceBar][diag] selection_capture "));
  if (captures.length === 0) fail("no selection_capture or speak_text since start: Option+F5 was not received");
  if (captures.length > 1) fail(`${captures.length} selection_capture events since start; one keypress per proof`);
  const capture = captures[0];
  const field = (name: string) => capture.line.match(new RegExp(`(?:^| )${name}=(\\S+)`))?.[1] ?? "";
  if (field("frontmostApp") !== T3_BUNDLE_ID) {
    fail(`selection_capture came from '${field("frontmostApp")}', not T3 Code (${T3_BUNDLE_ID})`);
  }
  const capturePid = Number(capture.line.match(/ VoiceBar\[(\d+):/)?.[1]);
  if (capturePid !== state.voiceBarPid) {
    fail(`selection_capture was logged by VoiceBar process ${capturePid}, not the installed candidate's ${state.voiceBarPid}`);
  }
  const captureMs = parseNSLogTime(capture.line);
  if (!Number.isFinite(captureMs) || captureMs < state.startedAt - 1000) {
    fail("selection_capture time is missing or before start");
  }
  const readError = field("outcome") !== "completed";
  if (readError) fail(`read error: selection_capture outcome=${field("outcome")} ax_read=${field("ax_read")}`);
  // Ties this capture to the synthetic paragraph without logging text. One trailing newline
  // (a triple-click selection) is tolerated; anything else is a different selection.
  const utf16 = Number(field("utf16_count"));
  if (utf16 !== state.expectedUtf16Count && utf16 !== state.expectedUtf16Count + 1) {
    fail(`selection_capture utf16_count=${field("utf16_count")} is not the expected paragraph's ${state.expectedUtf16Count}`);
  }

  // Every speak_text since start counts, so another speech in the window is ambiguous rather
  // than silently ignored; the one command must follow the capture.
  const speaks = lines
    .map((line, index) => ({
      index,
      id: line.match(/\[socket-client\] Command from VoiceBar: \{"cmd":"speak_text","id":"([^"]+)"\}/)?.[1],
    }))
    .filter((s): s is { index: number; id: string } => s.id !== undefined);
  if (speaks.length !== 1 || speaks[0].index < capture.index) {
    fail(`expected exactly one speak_text command since start, after the capture; found ${speaks.length}`);
  }
  const speakId = speaks[0].id;

  const entries = loadHistory(state.historyFile).filter((e) => e.timestamp >= state.startedAt);
  if (entries.length !== 1) fail(`expected exactly one new TTS history entry since start, found ${entries.length}`);
  const entry = entries[0];
  if (entry.timestamp < captureMs || entry.timestamp - captureMs > MAX_CAPTURE_TO_HISTORY_MS) {
    fail("the TTS history entry is not within 30 s after the capture");
  }

  const proof: T3OptF5Proof = {
    schema: PROOF_SCHEMA,
    gitCommit: state.gitCommit,
    buildTimeUTC: state.buildTimeUTC,
    t3Build: state.t3Build,
    timestamp: new Date(entry.timestamp).toISOString(),
    expectedTextSha256: state.expectedTextSha256,
    historyTextSha256: sha256(entry.text),
    speakTextCommandId: speakId,
    readError,
  };
  writeFileSync(out, `${JSON.stringify(proof, null, 2)}\n`);
  if (proof.expectedTextSha256 !== proof.historyTextSha256) {
    fail(`expected-text sha256 does not equal TTS-history text sha256; FAIL proof recorded at ${out}`);
  }
  console.log(`[t3-optf5-proof] PASS: ${out} (speak_text ${proof.speakTextCommandId}, VoiceBar ${proof.gitCommit})`);
}

function check(args: Map<string, string>) {
  const path = need(args, "--proof");
  if (!existsSync(path)) fail(`proof file not found: ${path}`);
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    fail(`proof file is not valid JSON: ${path}`);
  }
  const p = checkProof(raw, {
    gitCommit: args.get("--candidate-commit") ?? "",
    buildTimeUTC: args.get("--candidate-build-time") ?? "",
  });
  console.log(
    `[t3-optf5-proof] PASS: T3 Option+F5 proof matches candidate ${p.gitCommit} (${p.t3Build}, speak_text ${p.speakTextCommandId}, ${p.timestamp})`,
  );
}

function need(args: Map<string, string>, flag: string): string {
  const value = args.get(flag);
  if (!value) fail(`${flag} is required`);
  return value;
}

function parseArgs(argv: string[]): Map<string, string> {
  const args = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith("--") || argv[i + 1] === undefined) fail(`bad argument: ${argv[i]}`);
    args.set(argv[i], argv[i + 1]);
  }
  return args;
}

const USAGE = `Usage:
  bun scripts/t3-optf5-proof.ts start  --state FILE --t3-app "/Applications/T3 Code (Alpha).app" --expected-text-file FILE
                                       [--app /Applications/VoiceBar.app] [--voicebar-log PATH] [--history-file PATH]
  bun scripts/t3-optf5-proof.ts finish --state FILE --out PROOF.json
  bun scripts/t3-optf5-proof.ts check  --proof PROOF.json --candidate-commit SHA --candidate-build-time ISO`;

if (import.meta.main) {
  const [command, ...rest] = process.argv.slice(2);
  try {
    const args = parseArgs(rest);
    if (command === "start") start(args);
    else if (command === "finish") finish(args);
    else if (command === "check") check(args);
    else {
      console.error(USAGE);
      process.exit(2);
    }
  } catch (error) {
    if (!(error instanceof GateError)) throw error;
    const prefix = command === "check" ? "REFUSED: T3 Option+F5 proof" : "FAIL";
    console.error(`[t3-optf5-proof] ${prefix}: ${error.message}`);
    process.exit(1);
  }
}
