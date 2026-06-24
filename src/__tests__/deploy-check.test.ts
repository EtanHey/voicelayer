import { describe, expect, it } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";
import {
  evaluateDeployFreshness,
  formatDeployReport,
  type DeployProbe,
} from "../deploy-check";

// Post-merge deploy freshness gate (Track 5 #1 — "deliver-the-artifact post-merge
// deploy checklist"). The recurring regression: code merges to main but the
// running machine keeps a STALE VoiceBar.app / daemon — the merged artifact was
// never actually delivered ("stack didn't transfer to the M1"; stale-v9 incident
// 2026-06-10). This gate proves the deterministic checklist CATCHES every flavor
// of "not actually deployed", and PASSES only a genuinely fresh + live install.

const FRESH: DeployProbe = {
  repoVersion: "2.1.6",
  repoGitCommit: "4494685ddb2c6c4356bda0df59e92e5c850c5241",
  installedAppVersion: "2.1.6",
  installedPlistVersion: "2.1.6",
  installedGitCommit: "4494685ddb2c6c4356bda0df59e92e5c850c5241",
  installedBuildTimeUTC: "2026-06-25T00:00:02Z",
  appPresent: true,
  voiceBarRunning: true,
  daemonChildAlive: true,
  installedBuildTimeMs: 2_000,
  voiceBarStartedAtMs: 3_000,
  daemonChildStartedAtMs: 3_000,
};

describe("evaluateDeployFreshness — GREEN (genuinely deployed)", () => {
  it("passes when versions match and the stack is live", () => {
    const r = evaluateDeployFreshness(FRESH);
    expect(r.ok).toBe(true);
    expect(r.checks.every((c) => c.status === "pass")).toBe(true);
  });
});

describe("evaluateDeployFreshness — RED (artifact not delivered)", () => {
  it("CATCHES a stale app bundle (merged version never rebuilt the app)", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedAppVersion: "2.1.5",
    });
    expect(r.ok).toBe(false);
    const c = r.checks.find((c) => c.name === "app-build-provenance");
    expect(c?.status).toBe("fail");
    expect(c?.detail).toContain("2.1.5");
  });

  it("CATCHES a missing app bundle (never deployed on this machine)", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      appPresent: false,
      installedAppVersion: null,
      installedPlistVersion: null,
      installedBuildTimeMs: null,
      voiceBarRunning: false,
      voiceBarStartedAtMs: null,
      daemonChildAlive: false,
      daemonChildStartedAtMs: null,
    });
    expect(r.ok).toBe(false);
    expect(r.checks.find((c) => c.name === "app-present")?.status).toBe("fail");
    const runningCheck = r.checks.find((c) => c.name === "voicebar-running");
    expect(runningCheck?.detail).toContain("VoiceBar.app is missing");
    expect(runningCheck?.detail).not.toContain("installed but not running");
  });

  it("reports the configured app path when the bundle is missing", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      appPath: "/tmp/VoiceBar-dev.app",
      appPresent: false,
      installedAppVersion: null,
      installedPlistVersion: null,
      installedBuildTimeMs: null,
      voiceBarRunning: false,
      voiceBarStartedAtMs: null,
      daemonChildAlive: false,
      daemonChildStartedAtMs: null,
    });

    const c = r.checks.find((c) => c.name === "app-present");
    expect(c?.detail).toContain("/tmp/VoiceBar-dev.app is missing");
    expect(c?.detail).not.toContain("/Applications/VoiceBar.app");
  });

  it("CATCHES a stale Info.plist marketing version", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedPlistVersion: "2.1.4",
    });
    expect(r.ok).toBe(false);
    expect(r.checks.find((c) => c.name === "app-plist-version")?.status).toBe(
      "fail",
    );
  });

  it("CATCHES a stale VoiceBar binary GitCommit stamp", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedGitCommit: "1111111111111111111111111111111111111111",
    });
    expect(r.ok).toBe(false);
    const c = r.checks.find((c) => c.name === "app-git-commit");
    expect(c?.status).toBe("fail");
    expect(c?.detail).toContain("1111111");
    expect(c?.detail).toContain("4494685");
  });

  it("CATCHES a missing VoiceBar BuildTimeUTC stamp", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedBuildTimeUTC: null,
      installedBuildTimeMs: null,
    });
    expect(r.ok).toBe(false);
    const c = r.checks.find((c) => c.name === "app-build-time-utc");
    expect(c?.status).toBe("fail");
    expect(c?.detail).toContain("BuildTimeUTC");
  });

  it("CATCHES a deployed-but-not-running VoiceBar", () => {
    const r = evaluateDeployFreshness({ ...FRESH, voiceBarRunning: false });
    expect(r.ok).toBe(false);
    expect(r.checks.find((c) => c.name === "voicebar-running")?.status).toBe(
      "fail",
    );
  });

  it("CATCHES a rebuilt bundle with a stale still-running VoiceBar process", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedBuildTimeMs: 10_000,
      voiceBarStartedAtMs: 1_000,
    });
    expect(r.ok).toBe(false);
    const c = r.checks.find((c) => c.name === "voicebar-process-fresh");
    expect(c?.status).toBe("fail");
    expect(c?.detail).toContain("Stale");
  });

  it("CATCHES a VoiceBar process that started just before the rebuilt bundle timestamp", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedBuildTimeMs: 10_000,
      voiceBarStartedAtMs: 9_999,
    });
    expect(r.ok).toBe(false);
    expect(
      r.checks.find((c) => c.name === "voicebar-process-fresh")?.status,
    ).toBe("fail");
  });

  it("CATCHES a same-second VoiceBar start because ps cannot prove sub-second freshness", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedBuildTimeMs: 10_252,
      voiceBarStartedAtMs: 10_000,
    });
    expect(r.ok).toBe(false);
    expect(
      r.checks.find((c) => c.name === "voicebar-process-fresh")?.status,
    ).toBe("fail");
  });

  it("CATCHES a dead daemon child (no audio path) even when the app is up", () => {
    const r = evaluateDeployFreshness({ ...FRESH, daemonChildAlive: false });
    expect(r.ok).toBe(false);
    expect(r.checks.find((c) => c.name === "daemon-child-alive")?.status).toBe(
      "fail",
    );
  });

  it("CATCHES a rebuilt bundle with a stale daemon child", () => {
    const r = evaluateDeployFreshness({
      ...FRESH,
      installedBuildTimeMs: 10_000,
      daemonChildStartedAtMs: 1_000,
    });
    expect(r.ok).toBe(false);
    const c = r.checks.find((c) => c.name === "daemon-child-fresh");
    expect(c?.status).toBe("fail");
    expect(c?.detail).toContain("Stale");
  });
});

describe("evaluateDeployFreshness — off-target (not the daily-driver)", () => {
  it("does NOT fail closed when the probe is non-applicable (CI / remote box)", () => {
    // On a box that is not meant to run VoiceBar (no app, applicability off),
    // the checklist reports inconclusive rather than a false failure.
    const r = evaluateDeployFreshness({
      ...FRESH,
      appPresent: false,
      installedAppVersion: null,
      installedPlistVersion: null,
      installedBuildTimeMs: null,
      voiceBarRunning: false,
      voiceBarStartedAtMs: null,
      daemonChildAlive: false,
      daemonChildStartedAtMs: null,
      applicable: false,
    });
    expect(r.ok).toBe(true);
    expect(r.applicable).toBe(false);
    expect(r.checks.every((c) => c.status === "skip")).toBe(true);
  });
});

describe("formatDeployReport", () => {
  it("renders a human checklist with a pass/fail marker per check", () => {
    const report = formatDeployReport(evaluateDeployFreshness(FRESH));
    expect(report).toContain("repo version 2.1.6");
    expect(report).toMatch(/✓|PASS/);
  });

  it("surfaces the failing reason for a stale deploy", () => {
    const report = formatDeployReport(
      evaluateDeployFreshness({ ...FRESH, installedAppVersion: "2.1.5" }),
    );
    expect(report).toMatch(/✗|FAIL/);
    expect(report).toContain("app-build-provenance");
  });
});

describe("deploy-check CLI source contract", () => {
  it("uses plutil with an explicit Info.plist path to avoid defaults suffix ambiguity", () => {
    const cliSource = readFileSync(
      join(import.meta.dir, "..", "deploy-check-cli.ts"),
      "utf8",
    );

    expect(cliSource).toContain("Bun.spawnSync([");
    expect(cliSource).toContain('"plutil"');
    expect(cliSource).toContain("CFBundleShortVersionString");
    expect(cliSource).toContain("GitCommit");
    expect(cliSource).toContain("BuildTimeUTC");
    expect(cliSource).toContain('"raw"');
    expect(cliSource).toContain('"-o"');
    expect(cliSource).toContain('"-"');
    expect(cliSource).toContain('join(appPath, "Contents", "Info.plist")');
    expect(cliSource).not.toContain('Bun.spawnSync(["defaults",');
  });

  it("ties daemon liveness to a child process of the running VoiceBar", () => {
    const cliSource = readFileSync(
      join(import.meta.dir, "..", "deploy-check-cli.ts"),
      "utf8",
    );

    expect(cliSource).toContain("childProcessPids");
    expect(cliSource).toContain("parentSet.has(row.ppid)");
    expect(cliSource).toContain(
      'childProcessPids(\n    voiceBarPids,\n    "mcp-server-daemon",\n    rows,\n  )',
    );
    expect(cliSource).not.toContain('"pgrep"');
    expect(cliSource).not.toContain('["-f", "mcp-server-daemon"]');
  });

  it("ties VoiceBar liveness to the configured app bundle path", () => {
    const cliSource = readFileSync(
      join(import.meta.dir, "..", "deploy-check-cli.ts"),
      "utf8",
    );

    expect(cliSource).toContain("function appProcessPids");
    expect(cliSource).toContain('join(appPath, "Contents", "MacOS", "VoiceBar")');
    expect(cliSource).toContain("row.command.startsWith(binaryPath)");
    expect(cliSource).not.toContain('processPids(["-x", "VoiceBar"])');
  });

  it("short-circuits off-target machines before live process or plist probes", () => {
    const cliSource = readFileSync(
      join(import.meta.dir, "..", "deploy-check-cli.ts"),
      "utf8",
    );

    expect(cliSource).toContain("const applicable = applicability();");
    expect(cliSource).toContain("if (!applicable)");
    expect(cliSource.indexOf("if (!applicable)")).toBeLessThan(
      cliSource.indexOf('readPlistString(APP_PATH, "CFBundleShortVersionString")'),
    );
    expect(cliSource.indexOf("if (!applicable)")).toBeLessThan(
      cliSource.indexOf("const rows = processRows();"),
    );
  });

  it("reads the current repo commit so the installed VoiceBar binary can be SHA-checked", () => {
    const cliSource = readFileSync(
      join(import.meta.dir, "..", "deploy-check-cli.ts"),
      "utf8",
    );

    expect(cliSource).toContain("function readRepoGitCommit");
    expect(cliSource).toContain('"git"');
    expect(cliSource).toContain('"rev-parse"');
    expect(cliSource).toContain('"HEAD"');
    expect(cliSource).toContain("installedGitCommit");
    expect(cliSource).toContain("installedBuildTimeUTC");
  });
});
