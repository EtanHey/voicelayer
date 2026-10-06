/**
 * Tests for log rotation — rotates at 10MB, keeps one backup.
 */
import { describe, it, expect, afterEach, spyOn } from "bun:test";
import * as fs from "fs";
import { TEST_TMP } from "./setup/test-tmp";
import { writeFileSync, existsSync, readFileSync, unlinkSync } from "fs";
import {
  rotateIfNeeded,
  startLogRotation,
  stopLogRotation,
} from "../log-rotation";

const TEST_LOG = `${TEST_TMP}/voicelayer-test-logrotate.log`;
const TEST_LOG_ROTATED = `${TEST_TMP}/voicelayer-test-logrotate.log.1`;

function cleanup() {
  for (const f of [TEST_LOG, TEST_LOG_ROTATED]) {
    try {
      unlinkSync(f);
    } catch {}
  }
}

describe("log-rotation", () => {
  afterEach(() => {
    stopLogRotation();
    cleanup();
  });

  it("does not rotate small files", () => {
    writeFileSync(TEST_LOG, "small log content");
    const rotated = rotateIfNeeded(TEST_LOG);
    expect(rotated).toBe(false);
    expect(existsSync(TEST_LOG)).toBe(true);
    expect(existsSync(TEST_LOG_ROTATED)).toBe(false);
  });

  it("rotates files exceeding maxSize", () => {
    // Create a file just over the threshold (use 1KB for test)
    const content = "x".repeat(2000);
    writeFileSync(TEST_LOG, content);
    const rotated = rotateIfNeeded(TEST_LOG, 1000);
    expect(rotated).toBe(true);
    // Original should be moved to .1 (rename removes original)
    expect(existsSync(TEST_LOG)).toBe(false);
    expect(existsSync(TEST_LOG_ROTATED)).toBe(true);
    const rotatedContent = readFileSync(TEST_LOG_ROTATED, "utf-8");
    expect(rotatedContent).toBe(content);
  });

  it("does not rotate non-existent files", () => {
    const rotated = rotateIfNeeded(`${TEST_TMP}/voicelayer-nonexistent-log.log`);
    expect(rotated).toBe(false);
  });

  it("overwrites previous rotation", () => {
    // Create first rotation
    writeFileSync(TEST_LOG_ROTATED, "old rotation");
    const content = "y".repeat(2000);
    writeFileSync(TEST_LOG, content);
    rotateIfNeeded(TEST_LOG, 1000);

    // .1 should have new content, not old
    const rotatedContent = readFileSync(TEST_LOG_ROTATED, "utf-8");
    expect(rotatedContent).toBe(content);
  });

  it("startLogRotation and stopLogRotation do not throw", () => {
    // Just verify no errors — actual rotation is timer-based
    expect(() => startLogRotation([TEST_LOG], 60000)).not.toThrow();
    expect(() => stopLogRotation()).not.toThrow();
  });

  it("startLogRotation is idempotent", () => {
    startLogRotation([TEST_LOG], 60000);
    startLogRotation([TEST_LOG], 60000); // Should not create duplicate timer
    stopLogRotation();
  });
});

// Capture the real interval callback and mock all filesystem operations so even
// a regression selecting production paths cannot access the resident logs.
const isolationKeys = [
  "VOICELAYER_TMP_ROOT", "VOICELAYER_STATE_DIR",
  "VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH",
  "QA_VOICE_SOCKET_PATH", "QA_VOICE_MCP_SOCKET_PATH",
  "QA_VOICE_MCP_PID_PATH", "QA_VOICE_MCP_HEARTBEAT_PATH",
];

function rotationProbe(env: Record<string, string>, paths?: string[]) {
  const saved = isolationKeys.map((key) => process.env[key]);
  for (const key of isolationKeys) delete process.env[key];
  Object.assign(process.env, env);
  let tick: (() => void) | undefined;
  const timer = spyOn(globalThis, "setInterval").mockImplementation((callback: any) => {
    tick = callback;
    return { unref() {} } as any;
  });
  const clear = spyOn(globalThis, "clearInterval").mockImplementation(() => {});
  const exists = spyOn(fs, "existsSync").mockReturnValue(true);
  const stat = spyOn(fs, "statSync").mockReturnValue({ size: 11 * 1024 * 1024 } as any);
  const rename = spyOn(fs, "renameSync").mockImplementation(() => {});
  try {
    startLogRotation(paths);
    tick?.();
    return {
      exists: exists.mock.calls.map(([path]) => path),
      stat: stat.mock.calls.map(([path]) => path),
      rename: rename.mock.calls.map(([from, to]) => [from, to]),
    };
  } finally {
    stopLogRotation();
    rename.mockRestore(); stat.mockRestore(); exists.mockRestore();
    clear.mockRestore(); timer.mockRestore();
    isolationKeys.forEach((key, i) => {
      if (saved[i] === undefined) delete process.env[key];
      else process.env[key] = saved[i];
    });
  }
}

describe("log rotation isolation", () => {
  for (const key of isolationKeys) {
    it(`does not access implicit resident logs with ${key}`, () => {
      expect(rotationProbe({ [key]: `${TEST_TMP}/isolated` })).toEqual({
        exists: [], stat: [], rename: [],
      });
    });
  }

  it("retains byte-identical resident defaults without isolation overrides", () => {
    const paths = [
      "/tmp/voicelayer-mcp-daemon.stdout.log",
      "/tmp/voicelayer-mcp-daemon.stderr.log",
    ];
    const result = rotationProbe({});
    expect(result.exists).toEqual(paths);
    expect(result.stat).toEqual(paths);
    expect(result.rename).toEqual(paths.map((path) => [path, `${path}.1`]));
  });

  it("rotates only explicitly supplied isolated output files", () => {
    const paths = [`${TEST_TMP}/stdout.log`, `${TEST_TMP}/stderr.log`];
    const result = rotationProbe({ VOICELAYER_TMP_ROOT: TEST_TMP }, paths);
    expect(result.exists).toEqual(paths);
    expect(result.stat).toEqual(paths);
    expect(result.rename).toEqual(paths.map((path) => [path, `${path}.1`]));
  });
});
