import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";

// Etan ruling 2 (2026-09-24): the QA probes must not ship to users. They compile only
// under VOICEBAR_QA, which debug/test builds define and a release build gets only by an
// explicit VOICEBAR_QA_BUILD=1 opt-in; the release path refuses it and checks its binary.

const repoRoot = new URL("../..", import.meta.url).pathname;
const read = (...parts: string[]) => readFileSync(join(repoRoot, ...parts), "utf8");
const checker = join(repoRoot, "scripts", "check-voicebar-qa-free.sh");

function runChecker(contents: string) {
  const dir = mkdtempSync(join(process.env.TMPDIR ?? "/tmp", "qa-free-"));
  try {
    const binary = join(dir, "VoiceBar");
    writeFileSync(binary, contents);
    return Bun.spawnSync(["bash", checker, binary], { stdout: "pipe", stderr: "pipe" });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("VoiceBar QA probes are dev/CI-only", () => {
  test("the checker fails a binary that still carries a probe", () => {
    for (const marker of [
      "qa_context_menu_probe",
      "qa_vertical_hit_probe",
      "QA_VOICEBAR_CONTEXT_MENU_RECEIPT_PATH",
      "QA_VOICEBAR_VERTICAL_HIT_RECEIPT_PATH",
    ]) {
      const result = runChecker(`\u0000\u0001binary${marker}\u0000tail`);
      expect(result.exitCode).toBe(1);
      expect(result.stderr.toString()).toContain(marker);
    }
  });

  test("the checker passes a binary without probes", () => {
    const result = runChecker("\u0000\u0001VoiceBar qa_ prefix only\u0000");
    expect(result.exitCode).toBe(0);
  });

  test("the checker refuses a missing binary instead of passing it", () => {
    const result = Bun.spawnSync(["bash", checker, "/nonexistent/VoiceBar"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(result.exitCode).toBe(2);
  });

  test("only debug builds define VOICEBAR_QA in the package", () => {
    const manifest = read("flow-bar", "Package.swift");
    expect(manifest).toContain('.define("VOICEBAR_QA", .when(configuration: .debug))');
    expect(manifest).not.toMatch(/\.define\("VOICEBAR_QA"\)(?!,)/);
  });

  test("build-app.sh opts in explicitly, refuses a QA release, and checks every non-QA binary", () => {
    const source = read("flow-bar", "build-app.sh");
    expect(source).toContain('VOICEBAR_QA_BUILD:-0}" == "1"');
    expect(source).toContain("-Xswiftc -DVOICEBAR_QA");
    expect(source).toContain("VOICEBAR_REQUIRE_NOTARIZATION");
    expect(source).toContain("refusing a QA build for a notarized release");
    expect(source).toContain('check-voicebar-qa-free.sh" "$BINARY"');
  });

  test("the release script clears the opt-in and checks the notarized binary", () => {
    const source = read("scripts", "release-voicebar.sh");
    expect(source).toContain("VOICEBAR_QA_BUILD=0");
    expect(source).toContain('check-voicebar-qa-free.sh" "$APP_PATH/Contents/MacOS/VoiceBar"');
  });

  test("CI builds the release configuration and checks it", () => {
    const workflow = read(".github", "workflows", "ci.yml");
    expect(workflow).toContain("swift build -c release --package-path flow-bar --product VoiceBar");
    expect(workflow).toContain("scripts/check-voicebar-qa-free.sh");
  });

  test("the probe code sits behind the flag, and qa_* is dropped when it is compiled out", () => {
    const app = read("flow-bar", "Sources", "VoiceBar", "VoiceBarApp.swift");
    const server = read("flow-bar", "Sources", "VoiceBar", "SocketServer.swift");
    for (const [source, symbol] of [
      [app, "private func runIsolatedContextMenuProbe"],
      [app, "private func runIsolatedVerticalHitProbe"],
      [app, "server.onQAContextMenuProbe ="],
      [server, "var onQAContextMenuProbe"],
      [server, '"qa_vertical_hit_probe"'],
    ] as const) {
      const index = source.indexOf(symbol);
      expect(index).toBeGreaterThan(-1);
      const before = source.slice(0, index);
      const opened = before.lastIndexOf("#if VOICEBAR_QA");
      const closed = before.lastIndexOf("#endif");
      expect(opened).toBeGreaterThan(closed);
    }
    expect(server).toContain('type.hasPrefix("qa_")');
  });

  test("the event-handling verifier refuses an app built without the probes", () => {
    const source = read("scripts", "verify-notch-event-handling.sh");
    expect(source).toContain("VOICEBAR_QA_BUILD=1");
    expect(source).toContain("qa_context_menu_probe");
  });
});
