/**
 * Recording provenance — the machine + STT stack facts stamped into every
 * `metadata.json` under `~/.local/share/voicelayer/recordings/`.
 *
 * Why this exists: before metadata v2 every archived recording carried
 * `app_version: null` and no host/chip/model field, so a claim like "quality is
 * worse on the M1 Pro" could not be tested from the artifacts — there was
 * nothing on disk saying which machine, which whisper build, or which polish
 * mode produced a transcript. This module answers that, and only that: it reads
 * facts, it never changes what is recorded or when.
 *
 * AIDEV-NOTE: the shell-outs (`scutil`, `sysctl`, binary resolution,
 * `<binary> --help`) never run on the archive path, and never through
 * `Bun.spawnSync`. They run once, asynchronously and each bounded by
 * PROBE_TIMEOUT_MS, off the hot path — primed at daemon start (see
 * `primeRecordingProvenanceProbes`) and otherwise kicked off by the first
 * archive write, which does NOT wait for them. Until a probe resolves, its
 * fields are null and `provenance_probe` is `"pending"`, so a slow `scutil` can
 * never stall the archive write between the user's last word and the file
 * hitting disk, and a wedged `whisper-server --version` can never stall daemon
 * startup. Note this rules out the sync `resolveBinary()` on every path here:
 * it spawns `which` and `<candidate> --version` with no timeout. Every other
 * field is an in-process lookup.
 */
import { existsSync, readFileSync, realpathSync } from "fs";
import { hostname } from "os";

import type { STTPolishMode, STTPolishStatus } from "./stt-polish";
import { getSTTPolishMode } from "./stt-polish";
import { PACKAGE_VERSION } from "./version";
import {
  getWhisperPerformanceEffort,
  type WhisperPerformanceEffort,
} from "./whisper-performance";
import { resolveWhisperCliBinaryAsync } from "./stt";
import {
  resolveWhisperModelPath,
  resolveWhisperServerBinaryAsync,
  whisperServerLaunchRecord,
} from "./whisper-server";

/** Where `app_version` came from, so a null is never mistaken for a bug. */
export type AppVersionSource = "env" | "package.json" | "unavailable";

export interface AppVersion {
  version: string | null;
  source: AppVersionSource;
}

/**
 * Where `whisper_cpp_version` came from, so a null is never mistaken for a bug
 * and a version is never mistaken for a claim about a binary we did not use.
 * - `cellar-path`: read out of the resolved binary's own Homebrew Cellar path.
 * - `binary-help`: the binary printed a version in its help output.
 * - `unresolved`: no whisper binary resolved, or it printed no version.
 * - `pending`: the off-hot-path probe has not finished yet.
 * - `not-applicable`: this transcript did not come from a whisper backend.
 */
export type WhisperCppVersionSource =
  "cellar-path" | "binary-help" | "unresolved" | "pending" | "not-applicable";

/** Whether the async probes had resolved by the time this record was written. */
export type ProvenanceProbeStatus = "ready" | "pending";

/** The facts that require a subprocess, probed once per process, off the hot path. */
export interface MachineProvenance {
  /** Machine name only — never a user path. */
  host: string;
  /** e.g. "Apple M4 Max" / "Apple M1 Pro". Null while the probe is pending. */
  chip: string | null;
  /** "pending" until the async probe resolves. */
  status: ProvenanceProbeStatus;
}

/** The version of the whisper binary that actually produced (or would produce) the transcript. */
export interface WhisperCppVersion {
  version: string | null;
  source: WhisperCppVersionSource;
}

export interface RecordingProvenance {
  host: string;
  chip: string | null;
  whisper_backend: string | null;
  whisper_model_path: string | null;
  whisper_model_sha256: string | null;
  whisper_cpp_version: string | null;
  whisper_cpp_version_source: WhisperCppVersionSource;
  whisper_server_args: string | null;
  whisper_server_pid: number | null;
  whisper_server_started_at: string | null;
  /** Null for non-whisper backends — effort is a whisper.cpp search setting. */
  performance_effort: WhisperPerformanceEffort | null;
  polish_mode: STTPolishMode;
  /** Did the polish call reach the server? null when polish was not attempted. */
  polish_reachable: boolean | null;
  polish_status: STTPolishStatus | null;
  language_mode: string;
  app_version: string | null;
  app_version_source: AppVersionSource;
  /** "pending" when the subprocess probes had not resolved at write time. */
  provenance_probe: ProvenanceProbeStatus;
}

/** Every probe is injectable so tests never shell out. */
export interface RecordingProvenanceProbe {
  machine?: () => MachineProvenance;
  whisperCppVersion?: () => WhisperCppVersion;
  whisperModelPath?: () => string | null;
  whisperModelSha256?: (modelPath: string | null) => string | null;
  whisperServerArgs?: () => string | null;
  whisperServerProcess?: () => {
    pid: number | null;
    startedAt: string | null;
  };
  performanceEffort?: () => WhisperPerformanceEffort;
  polishMode?: () => STTPolishMode;
  appVersion?: () => AppVersion;
}

export interface RecordingProvenanceInput {
  /** The STT backend that produced the transcript; null before finalization. */
  backend: string | null;
  languageMode: string;
  /** The polish outcome for this utterance, when the code path has it. */
  polishStatus?: STTPolishStatus | null;
  probe?: RecordingProvenanceProbe;
}

const APP_VERSION_ENV = "VOICELAYER_APP_VERSION";

/**
 * Per-probe wall-clock bound. Every probe is off the hot path, so this only has
 * to stop a wedged `scutil`/`sysctl` from leaking a live subprocess forever.
 */
const PROBE_TIMEOUT_MS = 1_500;

/**
 * Which local whisper executable produced a transcript: the resident HTTP
 * server, or the one-shot CLI (`whisper-cli`/`whisper-cpp`). They are different
 * binaries with different versions, and only the server has a launch record.
 */
export type WhisperBackendKind = "server" | "cli";

/** Base backend name -> which binary actually ran. */
const WHISPER_BACKEND_KINDS: Record<string, WhisperBackendKind> = {
  "whisper-server": "server",
  "whisper.cpp": "cli",
};

/**
 * Reduce a recorded backend string to the local whisper executable that
 * produced the text, or null when no local whisper did.
 *
 * `STTResult.backend` is decorated, not a bare name (see `src/stt.ts`):
 *  - `a->b` is a fallback chain, so the LAST segment is what produced the text
 *    (`whisper-server->whisper.cpp` means the CLI transcribed it);
 *  - `+suffix` marks post-processing passes on the same backend
 *    (`whisper-server+chunks+witness`, `whisper-server+head+clean`), so the
 *    FIRST token is the base name.
 *
 * Matching exact names only — which is what this did before — nulled the
 * whisper provenance for the *common* case, since a plain undecorated
 * `whisper-server` result is the exception rather than the rule.
 */
export function normalizeWhisperBackend(
  backend: string | null,
): WhisperBackendKind | null {
  if (!backend) return null;
  const produced = backend.split("->").pop()?.trim() ?? "";
  const base = produced.split("+")[0]?.trim() ?? "";
  return WHISPER_BACKEND_KINDS[base] ?? null;
}

/**
 * Did a local whisper build produce this transcript? Anything else
 * (`wispr-flow`, `not-transcribed`, null before finalization) gets null whisper
 * fields — a Wispr transcript stamped with the local model path is
 * plausible-but-false provenance, which is worse than no provenance.
 */
export function isWhisperBackend(backend: string | null): boolean {
  return normalizeWhisperBackend(backend) !== null;
}

type ProbeRunner = (cmd: string[], timeoutMs: number) => Promise<string | null>;

/**
 * Run a probe command asynchronously, bounded by `timeoutMs`.
 *
 * Async (`Bun.spawn`) rather than `Bun.spawnSync` on purpose: a sync spawn holds
 * the Bun event loop for as long as the child takes, which is exactly the stall
 * this module must never put between a finished utterance and its archive write.
 * The timeout is enforced here rather than trusted to the spawn option so the
 * bound holds regardless of Bun version.
 */
async function runProbeCommand(
  cmd: string[],
  timeoutMs: number = PROBE_TIMEOUT_MS,
): Promise<string | null> {
  try {
    const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "ignore" });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        proc.kill("SIGKILL");
      } catch {}
    }, timeoutMs);
    try {
      const [out, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        proc.exited,
      ]);
      if (timedOut || exitCode !== 0) return null;
      const value = out.trim();
      return value.length > 0 ? value : null;
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return null;
  }
}

/** Same as `runProbeCommand` but folds stderr in — `--help` often goes there. */
async function runProbeCommandMergingStderr(
  cmd: string[],
  timeoutMs: number = PROBE_TIMEOUT_MS,
): Promise<string | null> {
  try {
    const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        proc.kill("SIGKILL");
      } catch {}
    }, timeoutMs);
    try {
      const [out, err] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      if (timedOut) return null;
      const value = `${out}\n${err}`.trim();
      return value.length > 0 ? value : null;
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return null;
  }
}

let probeRunner: ProbeRunner = runProbeCommand;
let helpProbeRunner: ProbeRunner = runProbeCommandMergingStderr;

/** Injection seam so tests can drive the async probes without shelling out. */
export function __setProvenanceProbeRunnersForTests(runners: {
  run?: ProbeRunner;
  runMergingStderr?: ProbeRunner;
}): void {
  probeRunner = runners.run ?? runProbeCommand;
  helpProbeRunner = runners.runMergingStderr ?? runProbeCommandMergingStderr;
}

export function __resetProvenanceProbeRunnersForTests(): void {
  probeRunner = runProbeCommand;
  helpProbeRunner = runProbeCommandMergingStderr;
}

/** Exposed for the timeout test — the real bound, on a real subprocess. */
export const __runProbeCommandForTests = runProbeCommand;

async function probeHost(): Promise<string> {
  return (
    (await probeRunner(
      ["scutil", "--get", "ComputerName"],
      PROBE_TIMEOUT_MS,
    )) ?? hostname()
  );
}

async function probeChip(): Promise<string | null> {
  return probeRunner(
    ["sysctl", "-n", "machdep.cpu.brand_string"],
    PROBE_TIMEOUT_MS,
  );
}

// ---------------------------------------------------------------------------
// Machine probe cache (host + chip)
// ---------------------------------------------------------------------------

let cachedMachineProvenance: MachineProvenance | null = null;
let machineProbeInFlight: Promise<MachineProvenance> | null = null;

/** What we can say about the machine without spawning anything. */
function pendingMachineProvenance(): MachineProvenance {
  return { host: hostname(), chip: null, status: "pending" };
}

/**
 * Kick off (or join) the async machine probe. Callers on the recording path
 * must not await this — see `machineProvenance()`.
 */
export function primeMachineProvenance(): Promise<MachineProvenance> {
  if (cachedMachineProvenance) return Promise.resolve(cachedMachineProvenance);
  if (machineProbeInFlight) return machineProbeInFlight;
  // `.then()` rather than an immediately-invoked async function: the body of an
  // async IIFE runs synchronously up to its first await, and this is called
  // from the archive path. A microtask boundary guarantees the caller returns
  // before any probe work starts.
  machineProbeInFlight = Promise.resolve().then(async () => {
    const [host, chip] = await Promise.all([probeHost(), probeChip()]);
    cachedMachineProvenance = { host, chip, status: "ready" };
    machineProbeInFlight = null;
    return cachedMachineProvenance;
  });
  return machineProbeInFlight;
}

/**
 * The machine facts as of *now*, never waiting. Returns a `pending` record (and
 * starts the probe) until the probe has resolved.
 */
export function machineProvenance(): MachineProvenance {
  if (cachedMachineProvenance) return cachedMachineProvenance;
  void primeMachineProvenance();
  return pendingMachineProvenance();
}

export function resetMachineProvenanceCacheForTests(): void {
  cachedMachineProvenance = null;
  machineProbeInFlight = null;
}

// ---------------------------------------------------------------------------
// whisper.cpp version, derived from the binary that is actually used
// ---------------------------------------------------------------------------

/**
 * Cached per (kind, resolved binary path), not per process: the server and the
 * CLI are different executables with independent versions, and if a later
 * whisper-server launch resolves a different binary than the one on PATH at
 * daemon start, the version follows the binary instead of going stale.
 */
const whisperCppVersionCache = new Map<string, WhisperCppVersion>();
const whisperCppVersionInFlight = new Map<string, Promise<WhisperCppVersion>>();

/**
 * Sentinel for "no launch record — resolve this kind's binary from PATH".
 *
 * Reading the launch record is an in-process lookup, so it is safe on the hot
 * path; *resolving* a binary from PATH is not — even the async resolver spawns
 * `which` — so resolution only ever happens inside the async prime below.
 *
 * The launch record describes the resident server and nothing else, so it is
 * consulted for `kind: "server"` alone: a `whisper.cpp` transcript came out of
 * the CLI, whose version has nothing to do with a whisper-server that happens
 * to be up.
 */
const RESOLVED_BINARY_KEY = "resolve-from-path";

function whisperCppVersionBinaryKey(kind: WhisperBackendKind): string {
  if (kind !== "server") return RESOLVED_BINARY_KEY;
  return whisperServerLaunchRecord()?.binary ?? RESOLVED_BINARY_KEY;
}

function whisperCppVersionCacheKey(kind: WhisperBackendKind): string {
  return `${kind}\u0000${whisperCppVersionBinaryKey(kind)}`;
}

/** Injection seam for the two async binary resolvers (tests + the RED case). */
type BinaryResolver = () => Promise<string | null>;

/**
 * Total budget for resolving one whisper binary, on top of the per-probe bound
 * inside the resolver itself.
 *
 * The per-probe timeout stops a single wedged child; this stops the *sequence*
 * (`which`, then up to four `<candidate> --version` probes) from leaving the
 * prime promise outstanding for the life of the process. Resolution is normally
 * milliseconds on a warm PATH, so exceeding this means something is wrong and
 * `"unresolved"` is the honest answer.
 *
 * A timeout is deliberately NOT cached: the next prime retries rather than
 * pinning the session to a null version because of one bad moment.
 */
const RESOLVE_BUDGET_MS = 1_500;

const RESOLVE_TIMED_OUT = Symbol("resolve-timed-out");

async function resolveWithinBudget(
  resolver: BinaryResolver,
): Promise<string | null | typeof RESOLVE_TIMED_OUT> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const budget = new Promise<typeof RESOLVE_TIMED_OUT>((resolve) => {
    timer = setTimeout(() => resolve(RESOLVE_TIMED_OUT), RESOLVE_BUDGET_MS);
  });
  try {
    return await Promise.race([resolver(), budget]);
  } catch {
    return null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

const defaultServerResolver: BinaryResolver = () =>
  resolveWhisperServerBinaryAsync(PROBE_TIMEOUT_MS);
const defaultCliResolver: BinaryResolver = () =>
  resolveWhisperCliBinaryAsync(PROBE_TIMEOUT_MS);

let serverBinaryResolver: BinaryResolver = defaultServerResolver;
let cliBinaryResolver: BinaryResolver = defaultCliResolver;

export function __setWhisperBinaryResolversForTests(resolvers: {
  server?: BinaryResolver;
  cli?: BinaryResolver;
}): void {
  serverBinaryResolver = resolvers.server ?? defaultServerResolver;
  cliBinaryResolver = resolvers.cli ?? defaultCliResolver;
}

export function __resetWhisperBinaryResolversForTests(): void {
  __setWhisperBinaryResolversForTests({});
}

/** `/opt/homebrew/Cellar/whisper-cpp/1.7.4/bin/whisper-server` -> `1.7.4`. */
function cellarVersionFromPath(binaryPath: string): string | null {
  const match = binaryPath.match(/\/Cellar\/whisper-cpp\/([^/]+)\//);
  return match?.[1] ?? null;
}

function versionTokenFromHelpLine(line: string): string | null {
  const match = line.match(/\bv?(\d+\.\d+(?:\.\d+)?)\b/);
  return match?.[1] ?? null;
}

async function probeWhisperCppVersion(
  binaryPath: string,
): Promise<WhisperCppVersion> {
  // Homebrew's `bin/whisper-server` is a symlink into the Cellar, and the
  // Cellar path carries the exact formula version — no subprocess needed, and
  // no `brew list` (which reports the *installed* formula, not the binary in
  // use, and is a second source of truth).
  let realPath = binaryPath;
  try {
    realPath = realpathSync(binaryPath);
  } catch {
    // Not resolvable — fall through to the help probe on the original path.
  }
  const cellar =
    cellarVersionFromPath(realPath) ?? cellarVersionFromPath(binaryPath);
  if (cellar) return { version: cellar, source: "cellar-path" };

  const help = await helpProbeRunner([binaryPath, "--help"], PROBE_TIMEOUT_MS);
  const firstLine = help?.split("\n")[0]?.trim();
  const fromHelp = firstLine ? versionTokenFromHelpLine(firstLine) : null;
  if (fromHelp) return { version: fromHelp, source: "binary-help" };

  return { version: null, source: "unresolved" };
}

/**
 * Kick off (or join) the version probe for the binary of the given kind.
 *
 * Every step here is async and bounded, including the PATH resolution: the sync
 * `resolveBinary` spawns `which` and `<candidate> --version` through
 * `Bun.spawnSync` with no timeout, so a wedged binary would block the daemon
 * startup this prime is called from.
 */
export function primeWhisperCppVersion(
  kind: WhisperBackendKind = "server",
): Promise<WhisperCppVersion> {
  const key = whisperCppVersionCacheKey(kind);
  const cached = whisperCppVersionCache.get(key);
  if (cached) return Promise.resolve(cached);
  const inFlight = whisperCppVersionInFlight.get(key);
  if (inFlight) return inFlight;
  const launchBinary = whisperCppVersionBinaryKey(kind);
  // `.then()` for the same reason as the machine probe: nothing here — not even
  // the PATH resolution — may run inside an archive write's synchronous frame.
  const probe = Promise.resolve().then(async () => {
    try {
      const binaryPath =
        launchBinary === RESOLVED_BINARY_KEY
          ? await resolveWithinBudget(
              kind === "server" ? serverBinaryResolver : cliBinaryResolver,
            )
          : launchBinary;
      if (binaryPath === RESOLVE_TIMED_OUT) {
        // Not cached — a wedged resolver must not pin the whole session to a
        // null version. The next prime tries again.
        return { version: null, source: "unresolved" } as WhisperCppVersion;
      }
      const result: WhisperCppVersion = binaryPath
        ? await probeWhisperCppVersion(binaryPath)
        : { version: null, source: "unresolved" };
      whisperCppVersionCache.set(key, result);
      return result;
    } finally {
      whisperCppVersionInFlight.delete(key);
    }
  });
  whisperCppVersionInFlight.set(key, probe);
  return probe;
}

/** The version as of *now*, never waiting. `pending` until the probe resolves. */
export function whisperCppVersion(
  kind: WhisperBackendKind = "server",
): WhisperCppVersion {
  const cached = whisperCppVersionCache.get(whisperCppVersionCacheKey(kind));
  if (cached) return cached;
  void primeWhisperCppVersion(kind);
  return { version: null, source: "pending" };
}

export function resetWhisperCppVersionCacheForTests(): void {
  whisperCppVersionCache.clear();
  whisperCppVersionInFlight.clear();
}

/**
 * Warm every subprocess probe. Called once at daemon start so the first
 * recording of a session already has real host/chip/version facts; recordings
 * never wait on it either way.
 */
export function primeRecordingProvenanceProbes(): Promise<void> {
  return Promise.all([
    primeMachineProvenance(),
    // Both executables: a session can produce `whisper-server` transcripts and
    // `whisper.cpp` ones (the fallback chain), and they are different binaries.
    primeWhisperCppVersion("server"),
    primeWhisperCppVersion("cli"),
  ]).then(() => undefined);
}

/**
 * SHA-256 of the whisper model, from the `.sha256` sidecar when one exists.
 * The model is ~800MB, so it is never hashed inline on a recording path.
 */
export function whisperModelSha256(modelPath: string | null): string | null {
  if (!modelPath) return null;
  const sidecar = `${modelPath}.sha256`;
  if (!existsSync(sidecar)) return null;
  try {
    const token = readFileSync(sidecar, "utf8").trim().split(/\s+/)[0];
    return token && /^[0-9a-f]{64}$/i.test(token) ? token.toLowerCase() : null;
  } catch {
    return null;
  }
}

/**
 * The app version, and where it came from.
 *
 * VoiceBar only adopts a source root whose `package.json` version equals the
 * bundle's `CFBundleShortVersionString` (see
 * `flow-bar/Sources/VoiceBar/VoiceBarDaemonController.swift`), so for a
 * VoiceBar-launched daemon the package version *is* the app version. The env
 * override is the seam for a future Swift change that passes it explicitly.
 */
export function appVersion(env: NodeJS.ProcessEnv = process.env): AppVersion {
  const fromEnv = env[APP_VERSION_ENV]?.trim();
  if (fromEnv) return { version: fromEnv, source: "env" };
  if (PACKAGE_VERSION)
    return { version: PACKAGE_VERSION, source: "package.json" };
  return { version: null, source: "unavailable" };
}

/**
 * Reachability comes from the polish call the pipeline already made — there is
 * deliberately no second health probe here (a probe per recording would double
 * the polish server's request rate for no new information).
 */
export function polishReachabilityForStatus(
  status: STTPolishStatus | null | undefined,
): boolean | null {
  if (!status) return null;
  switch (status) {
    case "applied":
    case "rejected":
    case "shadowed":
      return true;
    case "failed":
    case "unavailable":
      return false;
    case "skipped":
      // Polish was never attempted (mode off, or empty text) — "reachable" is
      // unknown, not false.
      return null;
  }
}

export function buildRecordingProvenance(
  input: RecordingProvenanceInput,
): RecordingProvenance {
  const probe = input.probe ?? {};
  const machine = (probe.machine ?? machineProvenance)();
  const version = (probe.appVersion ?? appVersion)();
  const polishStatus = input.polishStatus ?? null;
  const kind = normalizeWhisperBackend(input.backend);

  if (kind === null) {
    // Not a whisper transcript: every whisper-specific field stays null rather
    // than describing a local build that had nothing to do with this text.
    return {
      host: machine.host,
      chip: machine.chip,
      whisper_backend: input.backend,
      whisper_model_path: null,
      whisper_model_sha256: null,
      whisper_cpp_version: null,
      whisper_cpp_version_source: "not-applicable",
      whisper_server_args: null,
      whisper_server_pid: null,
      whisper_server_started_at: null,
      performance_effort: null,
      polish_mode: (probe.polishMode ?? (() => getSTTPolishMode()))(),
      polish_reachable: polishReachabilityForStatus(polishStatus),
      polish_status: polishStatus,
      language_mode: input.languageMode,
      app_version: version.version,
      app_version_source: version.source,
      provenance_probe: machine.status,
    };
  }

  // A `whisper.cpp` transcript came out of the one-shot CLI, so nothing about
  // the resident server describes it: not its binary version, not its launch
  // flags, not its PID, and not the effort it was launched with. Only the
  // `server` kind reads the launch record.
  const modelPath = (
    probe.whisperModelPath ?? (() => defaultWhisperModelPath(kind))
  )();
  const launchArgs = (
    probe.whisperServerArgs ?? (() => defaultWhisperServerArgs(kind))
  )();
  const cppVersion = (
    probe.whisperCppVersion ?? (() => whisperCppVersion(kind))
  )();
  const serverProcess = (
    probe.whisperServerProcess ?? (() => defaultWhisperServerProcess(kind))
  )();

  return {
    host: machine.host,
    chip: machine.chip,
    whisper_backend: input.backend,
    whisper_model_path: modelPath,
    whisper_model_sha256: (probe.whisperModelSha256 ?? whisperModelSha256)(
      modelPath,
    ),
    whisper_cpp_version: cppVersion.version,
    whisper_cpp_version_source: cppVersion.source,
    whisper_server_args: launchArgs,
    whisper_server_pid: serverProcess.pid,
    whisper_server_started_at: serverProcess.startedAt,
    performance_effort: (
      probe.performanceEffort ?? (() => defaultPerformanceEffort(kind))
    )(),
    polish_mode: (probe.polishMode ?? (() => getSTTPolishMode()))(),
    polish_reachable: polishReachabilityForStatus(polishStatus),
    polish_status: polishStatus,
    language_mode: input.languageMode,
    app_version: version.version,
    app_version_source: version.source,
    provenance_probe:
      machine.status === "ready" && cppVersion.source !== "pending"
        ? "ready"
        : "pending",
  };
}

/**
 * The model the resident whisper-server was launched with, falling back to the
 * model this process's configuration resolves to when no server is resident.
 * The CLI resolves its own model per invocation and never adopts the server's,
 * so `kind: "cli"` always reports the configured model.
 */
function defaultWhisperModelPath(kind: WhisperBackendKind): string | null {
  if (kind === "cli") return resolveWhisperModelPath();
  return whisperServerLaunchRecord()?.modelPath ?? resolveWhisperModelPath();
}

/**
 * The flags the resident whisper-server was actually launched with, when this
 * process launched it. Null when no resident server has been started here —
 * reporting the flags we *would* use would be a guess, not provenance.
 */
function defaultWhisperServerArgs(kind: WhisperBackendKind): string | null {
  if (kind === "cli") return null;
  const record = whisperServerLaunchRecord();
  if (!record) return null;
  // Drop the binary path (argv[0]) — the flags are the interesting part, and
  // the binary path is not a user path worth stamping into every recording.
  return record.args.slice(1).join(" ");
}

/** PID + start time of the resident server, so a log line can be tied to a recording. */
function defaultWhisperServerProcess(kind: WhisperBackendKind): {
  pid: number | null;
  startedAt: string | null;
} {
  if (kind === "cli") return { pid: null, startedAt: null };
  const record = whisperServerLaunchRecord();
  return {
    pid: record?.pid ?? null,
    startedAt: record?.startedAt ?? null,
  };
}

/**
 * The effort the resident server was *launched* with, not the current setting:
 * changing the setting mid-transcription must not retroactively relabel the
 * recording. Falls back to the configured effort only when no server is resident.
 */
function defaultPerformanceEffort(
  kind: WhisperBackendKind,
): WhisperPerformanceEffort {
  // The CLI reads the effort setting per invocation, so the configured value is
  // the truth for it; only a resident server has a launched-with effort.
  if (kind === "cli") return getWhisperPerformanceEffort();
  return (
    whisperServerLaunchRecord()?.performanceEffort ??
    getWhisperPerformanceEffort()
  );
}
