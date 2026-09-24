import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import {
  getPersistedWhisperPerformanceEffort,
  restorePersistedWhisperPerformanceEffort,
  setWhisperPerformanceEffort,
} from "../whisper-performance";

describe("restoring the saved effort (#142 follow-up)", () => {
  const dir = join(TEST_TMP, "whisper-performance");
  const env = { QA_VOICE_WHISPER_PERFORMANCE_PATH: join(dir, "effort.json") } as NodeJS.ProcessEnv;
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  test("a saved value is written back", () => {
    mkdirSync(dir, { recursive: true });
    setWhisperPerformanceEffort("fast", env);
    restorePersistedWhisperPerformanceEffort("balanced", env);
    expect(getPersistedWhisperPerformanceEffort(env)).toBe("balanced");
  });

  test("nothing saved before means no file after", () => {
    mkdirSync(dir, { recursive: true });
    setWhisperPerformanceEffort("fast", env);
    restorePersistedWhisperPerformanceEffort(null, env);
    expect(existsSync(env.QA_VOICE_WHISPER_PERFORMANCE_PATH!)).toBe(false);
    expect(getPersistedWhisperPerformanceEffort(env)).toBeNull();
  });

  test("the persisted getter ignores the environment override", () => {
    mkdirSync(dir, { recursive: true });
    setWhisperPerformanceEffort("accurate", env);
    expect(getPersistedWhisperPerformanceEffort({ ...env, QA_VOICE_WHISPER_PERFORMANCE_EFFORT: "fast" }))
      .toBe("accurate");
  });
});
