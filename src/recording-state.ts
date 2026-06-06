import { existsSync, readFileSync } from "fs";
import { recordingStateFilePath, safeWriteFileSync } from "./paths";

export type RecordingState = "idle" | "recording" | "transcribing";

const VALID_STATES = new Set<RecordingState>([
  "idle",
  "recording",
  "transcribing",
]);

let recordingState: RecordingState = "idle";

interface PersistedRecordingState {
  state: RecordingState;
  pid: number;
  updated_at: string;
}

function isRecordingState(value: unknown): value is RecordingState {
  return typeof value === "string" && VALID_STATES.has(value as RecordingState);
}

function isPidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function readPersistedRecordingState(): PersistedRecordingState | null {
  const filePath = recordingStateFilePath();
  if (!existsSync(filePath)) return null;

  try {
    const parsed: unknown = JSON.parse(readFileSync(filePath, "utf-8"));
    if (!parsed || typeof parsed !== "object") return null;
    const record = parsed as Record<string, unknown>;
    if (!isRecordingState(record.state)) return null;
    if (typeof record.pid !== "number") return null;
    if (typeof record.updated_at !== "string") return null;
    return {
      state: record.state,
      pid: record.pid,
      updated_at: record.updated_at,
    };
  } catch {
    return null;
  }
}

function persistRecordingState(state: RecordingState): void {
  try {
    safeWriteFileSync(
      recordingStateFilePath(),
      JSON.stringify({
        state,
        pid: process.pid,
        updated_at: new Date().toISOString(),
      }),
    );
  } catch {}
}

export function setRecordingState(state: RecordingState): void {
  recordingState = state;
  persistRecordingState(state);
}

export function getRecordingState(): RecordingState {
  return recordingState;
}

export function getEffectiveRecordingState(): RecordingState {
  if (recordingState !== "idle") return recordingState;

  const persisted = readPersistedRecordingState();
  if (!persisted || persisted.state === "idle") return "idle";
  return isPidAlive(persisted.pid) ? persisted.state : "idle";
}
