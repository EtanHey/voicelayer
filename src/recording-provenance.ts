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
 * AIDEV-NOTE: the shell-outs (`scutil`, `sysctl`, `brew`) are cached once per
 * process — see `machineProvenance()`. Recording is a hot path; probing per
 * utterance would put ~100ms of subprocess spawn between the user's last word
 * and the archive write. Every other field is an in-process lookup.
 */
import { existsSync, readFileSync } from "fs";
import { hostname } from "os";

import type { STTPolishMode, STTPolishStatus } from "./stt-polish";
import { getSTTPolishMode } from "./stt-polish";
import { PACKAGE_VERSION } from "./version";
import {
  getWhisperPerformanceEffort,
  type WhisperPerformanceEffort,
} from "./whisper-performance";
import {
  resolveWhisperModelPath,
  whisperServerLaunchRecord,
} from "./whisper-server";

/** Where `app_version` came from, so a null is never mistaken for a bug. */
export type AppVersionSource = "env" | "package.json" | "unavailable";

export interface AppVersion {
  version: string | null;
  source: AppVersionSource;
}

/** The facts that require a subprocess, probed once per process. */
export interface MachineProvenance {
  /** Machine name only — never a user path. */
  host: string;
  /** e.g. "Apple M4 Max" / "Apple M1 Pro". */
  chip: string | null;
  whisper_cpp_version: string | null;
}

export interface RecordingProvenance {
  host: string;
  chip: string | null;
  whisper_backend: string | null;
  whisper_model_path: string | null;
  whisper_model_sha256: string | null;
  whisper_cpp_version: string | null;
  whisper_server_args: string | null;
  performance_effort: WhisperPerformanceEffort;
  polish_mode: STTPolishMode;
  /** Did the polish call reach the server? null when polish was not attempted. */
  polish_reachable: boolean | null;
  polish_status: STTPolishStatus | null;
  language_mode: string;
  app_version: string | null;
  app_version_source: AppVersionSource;
}

/** Every probe is injectable so tests never shell out. */
export interface RecordingProvenanceProbe {
  machine?: () => MachineProvenance;
  whisperModelPath?: () => string | null;
  whisperModelSha256?: (modelPath: string | null) => string | null;
  whisperServerArgs?: () => string | null;
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

function runCapturingStdout(cmd: string[]): string | null {
  try {
    const result = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "ignore" });
    if (result.exitCode !== 0) return null;
    const value = result.stdout.toString().trim();
    return value.length > 0 ? value : null;
  } catch {
    return null;
  }
}

function probeHost(): string {
  return runCapturingStdout(["scutil", "--get", "ComputerName"]) ?? hostname();
}

function probeChip(): string | null {
  return runCapturingStdout(["sysctl", "-n", "machdep.cpu.brand_string"]);
}

function probeWhisperCppVersion(): string | null {
  for (const brew of ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
    if (!existsSync(brew)) continue;
    const line = runCapturingStdout([
      brew,
      "list",
      "--versions",
      "whisper-cpp",
    ]);
    // `brew list --versions whisper-cpp` prints "whisper-cpp 1.7.4"; an
    // unregistered formula prints nothing and exits non-zero.
    const version = line?.split(/\s+/)[1];
    if (version) return version;
  }
  return null;
}

let cachedMachineProvenance: MachineProvenance | null = null;

/** Cached once per process — see the AIDEV-NOTE at the top of this file. */
export function machineProvenance(): MachineProvenance {
  if (cachedMachineProvenance) return cachedMachineProvenance;
  cachedMachineProvenance = {
    host: probeHost(),
    chip: probeChip(),
    whisper_cpp_version: probeWhisperCppVersion(),
  };
  return cachedMachineProvenance;
}

export function resetMachineProvenanceCacheForTests(): void {
  cachedMachineProvenance = null;
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
  const modelPath = (probe.whisperModelPath ?? defaultWhisperModelPath)();
  const launchArgs = (probe.whisperServerArgs ?? defaultWhisperServerArgs)();
  const version = (probe.appVersion ?? appVersion)();
  const polishStatus = input.polishStatus ?? null;

  return {
    host: machine.host,
    chip: machine.chip,
    whisper_backend: input.backend,
    whisper_model_path: modelPath,
    whisper_model_sha256: (probe.whisperModelSha256 ?? whisperModelSha256)(
      modelPath,
    ),
    whisper_cpp_version: machine.whisper_cpp_version,
    whisper_server_args: launchArgs,
    performance_effort: (
      probe.performanceEffort ?? (() => getWhisperPerformanceEffort())
    )(),
    polish_mode: (probe.polishMode ?? (() => getSTTPolishMode()))(),
    polish_reachable: polishReachabilityForStatus(polishStatus),
    polish_status: polishStatus,
    language_mode: input.languageMode,
    app_version: version.version,
    app_version_source: version.source,
  };
}

/**
 * The model the resident whisper-server was launched with, falling back to the
 * model this process's configuration resolves to when no server is resident.
 */
function defaultWhisperModelPath(): string | null {
  return whisperServerLaunchRecord()?.modelPath ?? resolveWhisperModelPath();
}

/**
 * The flags the resident whisper-server was actually launched with, when this
 * process launched it. Null when no resident server has been started here —
 * reporting the flags we *would* use would be a guess, not provenance.
 */
function defaultWhisperServerArgs(): string | null {
  const record = whisperServerLaunchRecord();
  if (!record) return null;
  // Drop the binary path (argv[0]) — the flags are the interesting part, and
  // the binary path is not a user path worth stamping into every recording.
  return record.args.slice(1).join(" ");
}
