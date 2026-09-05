/**
 * Ownership records for the whisper-server sidecar.
 *
 * AIDEV-NOTE: This module exists because of a live-server kill loop on
 * 2026-09-05. Any *second* process that called `ensureServer()` — a worker
 * script, a `bun test` run, the corpus verify daemon — found a healthy
 * daemon-owned whisper-server on the port, saw that its own in-memory
 * `serverState` was null, concluded the server must be a stale orphan, and
 * SIGKILLed it. Five kills in one evening; each one cost a cold model load on
 * the next dictation.
 *
 * In-memory state cannot answer "did *anyone* launch this?" — only "did *I*
 * launch this?". The launcher therefore writes an ownership record next to the
 * port so a non-owner can tell a live server it does not own from an orphan.
 *
 * The record lives in the user-owned state dir (mode 0700), not /tmp: /tmp is
 * world-writable, and a spoofed ownership record is a way to talk this process
 * into or out of killing something.
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "fs";
import { homedir } from "os";
import { join } from "path";

/** Env override for the ownership directory (tests point this at a scratch dir). */
const OWNERSHIP_DIR_ENV = "VOICELAYER_WHISPER_OWNERSHIP_DIR";

/** Default bound on letting `lsof` answer who is listening on a port. */
const PORT_OWNER_TIMEOUT_MS = 1500;

/**
 * Who launched the whisper-server currently listening on a port.
 *
 * Snake_case on purpose: this is an on-disk interchange format read by
 * processes that may not share this module's version.
 */
export interface WhisperServerOwnershipRecord {
  /** PID of the whisper-server process itself. */
  pid: number;
  /** PID of the process that launched it. */
  owner_pid: number;
  /** ISO-8601 instant the server was observed healthy. */
  started_at: string;
  /** Binary the server was launched from. */
  binary: string;
  /** Full argv the server was launched with. */
  args: string[];
  /** Model the server was launched with. */
  model_path: string;
  /** Performance effort tier the server was launched with. */
  performance_effort: string;
  /** Acceleration mode the server was launched with. */
  acceleration_mode: string;
}

function ownershipDir(): string {
  const override = process.env[OWNERSHIP_DIR_ENV]?.trim();
  if (override) return override;
  return join(homedir(), ".local", "state", "voicelayer");
}

/** Path of the ownership record for `port`. */
export function whisperServerOwnershipPath(port: number): string {
  return join(ownershipDir(), `whisper-server-${port}.owner.json`);
}

/**
 * Record that this process launched the server on `port`.
 *
 * Written atomically: a reader that catches us mid-write must never see a
 * truncated record, because "unparseable record" reads as "no owner".
 */
export function writeWhisperServerOwnership(
  port: number,
  record: WhisperServerOwnershipRecord,
): void {
  const dir = ownershipDir();
  const target = whisperServerOwnershipPath(port);
  const temp = `${target}.${process.pid}.tmp`;
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(temp, `${JSON.stringify(record, null, 2)}\n`, {
      mode: 0o600,
    });
    renameSync(temp, target);
  } catch (error) {
    // Ownership is an optimization for *other* processes; failing to record it
    // must never fail a launch that otherwise succeeded.
    try {
      rmSync(temp, { force: true });
    } catch {}
    console.error(
      `[voicelayer] Could not record whisper-server ownership for port ${port}: ${String(error)}`,
    );
  }
}

function isOwnershipRecord(
  value: unknown,
): value is WhisperServerOwnershipRecord {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.pid === "number" &&
    Number.isFinite(candidate.pid) &&
    candidate.pid > 0 &&
    typeof candidate.owner_pid === "number" &&
    Number.isFinite(candidate.owner_pid) &&
    typeof candidate.binary === "string" &&
    Array.isArray(candidate.args) &&
    candidate.args.every((arg) => typeof arg === "string")
  );
}

/** The ownership record for `port`, or null when absent or unreadable. */
export function readWhisperServerOwnership(
  port: number,
): WhisperServerOwnershipRecord | null {
  const target = whisperServerOwnershipPath(port);
  if (!existsSync(target)) return null;
  try {
    const parsed: unknown = JSON.parse(readFileSync(target, "utf-8"));
    if (!isOwnershipRecord(parsed)) return null;
    return {
      pid: parsed.pid,
      owner_pid: parsed.owner_pid,
      started_at:
        typeof parsed.started_at === "string" ? parsed.started_at : "",
      binary: parsed.binary,
      args: parsed.args,
      model_path:
        typeof parsed.model_path === "string" ? parsed.model_path : "",
      performance_effort:
        typeof parsed.performance_effort === "string"
          ? parsed.performance_effort
          : "",
      acceleration_mode:
        typeof parsed.acceleration_mode === "string"
          ? parsed.acceleration_mode
          : "",
    };
  } catch {
    return null;
  }
}

/** Remove the ownership record for `port`. Safe when there is none. */
export function clearWhisperServerOwnership(port: number): void {
  try {
    rmSync(whisperServerOwnershipPath(port), { force: true });
  } catch {}
}

/**
 * PIDs listening on `port`, per `lsof`.
 *
 * Unlike `findExternalWhisperServerPids` this does not filter by command name:
 * the question here is "who holds this port", not "who looks killable". It is
 * the single implementation behind both port-owner questions in
 * whisper-server.ts — "is the healthy listener our child" and "does the
 * ownership record name the process actually holding the port" — so the two
 * can never drift apart. Bounded, because this runs on the dictation hot path.
 */
export function portOwnerPids(
  port: number,
  timeoutMs: number = PORT_OWNER_TIMEOUT_MS,
): number[] {
  try {
    const result = Bun.spawnSync(
      ["lsof", "-t", `-iTCP:${port}`, "-sTCP:LISTEN"],
      {
        stdout: "pipe",
        stderr: "ignore",
        timeout: timeoutMs,
        killSignal: "SIGKILL",
      },
    );
    if (result.exitCode !== 0) return [];
    return result.stdout
      .toString()
      .split(/\s+/)
      .map((raw) => Number.parseInt(raw, 10))
      .filter((pid) => Number.isFinite(pid) && pid > 0);
  } catch {
    return [];
  }
}
