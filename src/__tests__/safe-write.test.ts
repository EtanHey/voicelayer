/**
 * S1 Security: safeWriteFileSync rejects symlinks.
 *
 * writeFileSync follows symlinks by default. Flag files at predictable
 * /tmp paths (e.g., .claude_tts_disabled) are vulnerable to symlink attacks.
 * A local attacker pre-creates a symlink → our write overwrites the target.
 *
 * safeWriteFileSync MUST refuse to write if the target is a symlink.
 */

import { describe, it, expect, afterEach } from "bun:test";
import {
  existsSync,
  unlinkSync,
  symlinkSync,
  writeFileSync,
  readFileSync,
  mkdirSync,
  lstatSync,
} from "fs";
import { join } from "path";
import { safeWriteFileSync } from "../paths";

const TEST_DIR = "/tmp/voicelayer-test-safe-write";
const TARGET_FILE = join(TEST_DIR, "target.txt");
const SYMLINK_PATH = join(TEST_DIR, "evil-symlink");
const NORMAL_PATH = join(TEST_DIR, "normal-file.txt");

function cleanup() {
  for (const f of [TARGET_FILE, SYMLINK_PATH, NORMAL_PATH]) {
    try {
      // Use lstat — existsSync returns false for dangling symlinks
      lstatSync(f);
      unlinkSync(f);
    } catch {}
  }
}

describe("S1: safeWriteFileSync rejects symlinks", () => {
  afterEach(cleanup);

  it("refuses to write to a path that is a symlink", () => {
    cleanup(); // Ensure clean state from any prior failed run
    mkdirSync(TEST_DIR, { recursive: true });

    // Create a target file (simulates ~/.bash_profile)
    writeFileSync(TARGET_FILE, "original content");

    // Attacker creates a symlink pointing to the target
    symlinkSync(TARGET_FILE, SYMLINK_PATH);

    // safeWriteFileSync should refuse to follow the symlink
    safeWriteFileSync(SYMLINK_PATH, "malicious overwrite");

    // Target file should be untouched
    expect(readFileSync(TARGET_FILE, "utf-8")).toBe("original content");
  });

  it("writes normally to a regular file path", () => {
    mkdirSync(TEST_DIR, { recursive: true });

    safeWriteFileSync(NORMAL_PATH, "safe content");

    expect(existsSync(NORMAL_PATH)).toBe(true);
    expect(readFileSync(NORMAL_PATH, "utf-8")).toBe("safe content");
  });

  it("writes normally when file does not exist yet", () => {
    mkdirSync(TEST_DIR, { recursive: true });

    const newPath = join(TEST_DIR, "brand-new.txt");
    safeWriteFileSync(newPath, "new content");

    expect(readFileSync(newPath, "utf-8")).toBe("new content");

    // Clean up
    unlinkSync(newPath);
  });
});
