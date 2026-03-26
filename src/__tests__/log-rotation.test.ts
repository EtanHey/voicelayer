/**
 * Tests for log rotation — rotates at 10MB, keeps one backup.
 */
import { describe, it, expect, afterEach } from "bun:test";
import {
  writeFileSync,
  existsSync,
  statSync,
  readFileSync,
  unlinkSync,
} from "fs";
import {
  rotateIfNeeded,
  startLogRotation,
  stopLogRotation,
} from "../log-rotation";

const TEST_LOG = "/tmp/voicelayer-test-logrotate.log";
const TEST_LOG_ROTATED = "/tmp/voicelayer-test-logrotate.log.1";

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
    // Original should be moved to .1
    expect(existsSync(TEST_LOG_ROTATED)).toBe(true);
    const rotatedContent = readFileSync(TEST_LOG_ROTATED, "utf-8");
    expect(rotatedContent).toBe(content);
  });

  it("does not rotate non-existent files", () => {
    const rotated = rotateIfNeeded("/tmp/voicelayer-nonexistent-log.log");
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
