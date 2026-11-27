import { expect, test } from "bun:test";
import { darwinProcessStartMs } from "../../scripts/t3-optf5-proof";

test.skipIf(process.platform !== "darwin")("kernel start timestamp retains microseconds and rejects missing processes", () => {
  const started = darwinProcessStartMs(process.pid);
  expect(started).toBeGreaterThan(0);
  expect(started).toBeLessThanOrEqual(Date.now());
  expect(() => darwinProcessStartMs(2_000_000_000)).toThrow();
});

import { processStartMs } from "../../scripts/t3-optf5-proof";

test.skipIf(process.platform !== "darwin")("kernel timestamps put child starts at or after the reference and the parent before it (200 loops)", async () => {
  for (let i = 0; i < 200; i++) {
    const installed = Date.now();
    const child = Bun.spawn([process.execPath, "-e", "setInterval(()=>{},1000)"], {
      env: process.env, stdout: "ignore", stderr: "ignore",
    });
    try {
      const started = processStartMs(child.pid);
      expect(started).toBeGreaterThanOrEqual(installed);
      // The already-running parent predates this install and remains stale.
      expect(processStartMs(process.pid)).toBeLessThan(installed);
    } finally {
      child.kill();
      await child.exited;
    }
  }
}, 30_000);

// The gate's own freshness decision (installedRuntime), for VoiceBar and for its daemon child.
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { installedRuntime, type ProcessRow } from "../../scripts/t3-optf5-proof";
import { statSync } from "fs";

function fakeInstalledBundle(): { app: string; plistMs: number; daemonInstalledMs: number; binary: string; script: string } {
  const root = mkdtempSync(join(bundleFixtureRoot(), "t3fresh-"));
  const app = join(root, "VoiceBar.app");
  const binary = `${app}/Contents/MacOS/VoiceBar`;
  const script = `${app}/Contents/Resources/src/mcp-server-daemon.ts`;
  mkdirSync(`${app}/Contents/MacOS`, { recursive: true });
  mkdirSync(`${app}/Contents/Resources/src`, { recursive: true });
  writeFileSync(`${app}/Contents/Info.plist`, "<plist/>");
  writeFileSync(binary, "binary"); chmodSync(binary, 0o755);
  writeFileSync(script, "// daemon");
  const plistMs = statSync(`${app}/Contents/Info.plist`).ctimeMs;
  const daemonInstalledMs = Math.max(plistMs, statSync(script).ctimeMs);
  return { app, plistMs, daemonInstalledMs, binary, script };
}

function laterInSameSecond(installedMs: number): number {
  const nextSecond = (Math.floor(installedMs / 1000) + 1) * 1000;
  const startedMs = installedMs + Math.min(0.5, (nextSecond - installedMs) / 2);
  expect(startedMs).toBeGreaterThan(installedMs);
  expect(Math.floor(startedMs / 1000)).toBe(Math.floor(installedMs / 1000));
  return startedMs;
}

function probeFor(fixture: ReturnType<typeof fakeInstalledBundle>, starts: { voiceBar: number; daemon: number }) {
  const rows: ProcessRow[] = [
    { pid: 4001, ppid: 1, command: fixture.binary },
    { pid: 4002, ppid: 4001, command: `bun run ${fixture.script}` },
  ];
  return {
    processRows: () => rows,
    processStartMs: (pid: number) => (pid === 4001 ? starts.voiceBar : starts.daemon),
    requireRunningExecutable: () => {},
  };
}

test("the gate accepts a VoiceBar and daemon that started later in the install's own second", () => {
  const fixture = fakeInstalledBundle();
  try {
    const starts = {
      voiceBar: laterInSameSecond(fixture.plistMs),
      daemon: laterInSameSecond(fixture.daemonInstalledMs),
    };
    expect(installedRuntime(fixture.app, probeFor(fixture, starts)))
      .toEqual({ voiceBarPid: 4001, daemonPids: [4002] });
  } finally { rmSync(fixture.app, { recursive: true, force: true }); }
});

test("the gate rejects a stale VoiceBar, and a stale daemon under a fresh VoiceBar, including a same-instant start", () => {
  const fixture = fakeInstalledBundle();
  try {
    const freshVoiceBar = laterInSameSecond(fixture.plistMs);
    const freshDaemon = laterInSameSecond(fixture.daemonInstalledMs);
    expect(() => installedRuntime(fixture.app, probeFor(fixture, { voiceBar: fixture.plistMs - 1500, daemon: freshDaemon })))
      .toThrow(/VoiceBar process 4001 is older than the installed bundle/);
    expect(() => installedRuntime(fixture.app, probeFor(fixture, { voiceBar: fixture.plistMs, daemon: freshDaemon })))
      .toThrow(/VoiceBar process 4001 is older than the installed bundle/);
    expect(() => installedRuntime(fixture.app, probeFor(fixture, { voiceBar: freshVoiceBar, daemon: fixture.daemonInstalledMs - 1500 })))
      .toThrow(/mcp-server-daemon process 4002 is older than the installed daemon script/);
    expect(() => installedRuntime(fixture.app, probeFor(fixture, { voiceBar: freshVoiceBar, daemon: fixture.daemonInstalledMs })))
      .toThrow(/mcp-server-daemon process 4002 is older than the installed daemon script/);
  } finally { rmSync(fixture.app, { recursive: true, force: true }); }
});
