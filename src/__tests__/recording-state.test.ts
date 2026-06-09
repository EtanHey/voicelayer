import { afterEach, describe, expect, it } from "bun:test";
import {
  lstatSync,
  mkdirSync,
  readFileSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { join } from "path";
import {
  getEffectiveRecordingState,
  getRecordingState,
  setRecordingState,
} from "../recording-state";

const TEST_DIR = `/tmp/voicelayer-recording-state-${process.pid}`;
const NORMAL_STATE_FILE = join(TEST_DIR, "recording-state.json");
const TARGET_FILE = join(TEST_DIR, "target.json");
const SYMLINK_STATE_FILE = join(TEST_DIR, "recording-state-symlink.json");

function cleanup() {
  for (const file of [NORMAL_STATE_FILE, TARGET_FILE, SYMLINK_STATE_FILE]) {
    try {
      lstatSync(file);
      unlinkSync(file);
    } catch {}
  }
}

describe("recording-state publication", () => {
  const originalRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;

  afterEach(() => {
    process.env.QA_VOICE_RECORDING_STATE_PATH = NORMAL_STATE_FILE;
    try {
      setRecordingState("idle");
    } catch {}
    if (originalRecordingStatePath === undefined) {
      delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_STATE_PATH = originalRecordingStatePath;
    }
    cleanup();
  });

  it("does not enter recording when the cross-process state file cannot be published", () => {
    cleanup();
    mkdirSync(TEST_DIR, { recursive: true });
    process.env.QA_VOICE_RECORDING_STATE_PATH = NORMAL_STATE_FILE;
    setRecordingState("idle");

    writeFileSync(TARGET_FILE, "not recording state");
    symlinkSync(TARGET_FILE, SYMLINK_STATE_FILE);
    process.env.QA_VOICE_RECORDING_STATE_PATH = SYMLINK_STATE_FILE;

    expect(() => setRecordingState("recording")).toThrow(
      "Unable to publish recording state",
    );
    expect(getRecordingState()).toBe("idle");
    expect(getEffectiveRecordingState()).toBe("idle");
    expect(readFileSync(TARGET_FILE, "utf-8")).toBe("not recording state");
  });
});
