/**
 * Tests for binary resolution in daemon/LaunchAgent context.
 */

import { describe, it, expect } from "bun:test";
import { initEnrichedPATH, resolveBinary } from "../resolve-binary";

describe("initEnrichedPATH", () => {
  it("returns a non-empty string", () => {
    const path = initEnrichedPATH();
    expect(path.length).toBeGreaterThan(0);
  });

  it("includes /usr/bin", () => {
    const path = initEnrichedPATH();
    expect(path).toContain("/usr/bin");
  });

  it("includes fallback Homebrew path", () => {
    const path = initEnrichedPATH();
    expect(path).toContain("/opt/homebrew/bin");
  });

  it("sets process.env.PATH", () => {
    initEnrichedPATH();
    expect(process.env.PATH).toContain("/opt/homebrew/bin");
  });

  it("returns cached result on second call", () => {
    const first = initEnrichedPATH();
    const second = initEnrichedPATH();
    expect(first).toBe(second);
  });
});

describe("resolveBinary", () => {
  it("finds system binaries via which", () => {
    const path = resolveBinary("ls");
    expect(path).not.toBeNull();
    expect(path).toContain("/ls");
  });

  it("returns null for nonexistent binary", () => {
    const path = resolveBinary("definitely_not_a_real_binary_12345");
    expect(path).toBeNull();
  });

  it("finds binary via candidate paths when which would fail", () => {
    // python3 --version works reliably on macOS
    const path = resolveBinary("nonexistent_via_which", ["/usr/bin/python3"]);
    expect(path).toBe("/usr/bin/python3");
  });

  it("finds rec (sox) if installed", () => {
    const path = resolveBinary("rec", [
      "/opt/homebrew/bin/rec",
      "/usr/local/bin/rec",
    ]);
    // May or may not be installed — just verify it doesn't crash
    if (path) {
      expect(path).toContain("rec");
    }
  });
});
