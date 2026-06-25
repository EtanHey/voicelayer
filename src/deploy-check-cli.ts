#!/usr/bin/env bun
/**
 * Runnable post-merge deploy checklist (Track 5 #1).
 *
 * Gathers the live machine probe — repo version, installed VoiceBar.app build
 * provenance + Info.plist version, and process liveness — then runs the
 * deterministic evaluator in src/deploy-check.ts and prints the checklist.
 * Exit 0 when the merged artifact is genuinely live (or the box is
 * non-applicable); exit 1 when the running stack is stale / not deployed.
 *
 * The verdict logic lives in deploy-check.ts (CI-tested RED→GREEN). This file
 * is only the I/O layer (filesystem + ps + plutil), parallel to the live
 * harness in the golden-WAV suite — skips cleanly off-target.
 *
 * Usage:
 *   bun run src/deploy-check-cli.ts            # check the daily-driver
 *   VOICEBAR_APP_PATH=/path/VoiceBar.app bun run src/deploy-check-cli.ts
 *   VOICELAYER_DEPLOY_CHECK_APPLICABLE=0 ...   # force inconclusive (off-target)
 */
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import {
  evaluateDeployFreshness,
  formatDeployReport,
  type DeployProbe,
} from "./deploy-check";

const PACKAGE_ROOT = join(import.meta.dir, "..");
const APP_PATH = process.env.VOICEBAR_APP_PATH || "/Applications/VoiceBar.app";

function readJsonVersion(path: string): string | null {
  try {
    const raw = readFileSync(path, "utf8");
    const v = (JSON.parse(raw) as { version?: unknown }).version;
    return typeof v === "string" ? v : null;
  } catch {
    return null;
  }
}

function readPlistString(appPath: string, key: string): string | null {
  const infoPlist = join(appPath, "Contents", "Info.plist");
  // Use plutil with the real file path. `defaults read` has .plist suffix
  // behavior that differs across macOS versions and can become ambiguous
  // between M4 and older M1 machines.
  const out = Bun.spawnSync([
    "plutil",
    "-extract",
    key,
    "raw",
    "-o",
    "-",
    infoPlist,
  ]);
  if (out.exitCode !== 0) return null;
  const v = out.stdout.toString().trim();
  return v.length > 0 ? v : null;
}

function parseBuildTimeMs(buildTimeUTC: string | null): number | null {
  if (buildTimeUTC == null) return null;
  const parsed = Date.parse(buildTimeUTC);
  return Number.isFinite(parsed) ? parsed : null;
}

function readRepoGitCommit(): string | null {
  const out = Bun.spawnSync(["git", "-C", PACKAGE_ROOT, "rev-parse", "HEAD"]);
  if (out.exitCode !== 0) return null;
  const commit = out.stdout.toString().trim();
  return /^[0-9a-f]{40}$/i.test(commit) ? commit : null;
}

interface ProcessRow {
  pid: number;
  ppid: number;
  command: string;
}

function processRows(): ProcessRow[] {
  const out = Bun.spawnSync(["ps", "-axo", "pid=,ppid=,command="]);
  if (out.exitCode !== 0) return [];
  return out.stdout
    .toString()
    .split("\n")
    .flatMap((line) => {
      const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
      if (!match) return [];
      const pid = Number(match[1]);
      const ppid = Number(match[2]);
      const command = match[3];
      if (Number.isInteger(pid) && pid > 0 && Number.isInteger(ppid)) {
        return [{ pid, ppid, command }];
      }
      return [];
    });
}

function appProcessPids(appPath: string, rows: ProcessRow[]): number[] {
  const binaryPath = join(appPath, "Contents", "MacOS", "VoiceBar");
  return rows
    .filter((row) => row.command.startsWith(binaryPath))
    .map((row) => row.pid);
}

function childProcessPids(
  parentPids: number[],
  commandNeedle: string,
  rows: ProcessRow[],
): number[] {
  if (parentPids.length === 0) return [];
  const parentSet = new Set(parentPids);
  return rows
    .filter(
      (row) => parentSet.has(row.ppid) && row.command.includes(commandNeedle),
    )
    .map((row) => row.pid);
}

function processStartTimeMs(pid: number): number | null {
  const out = Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(pid)]);
  if (out.exitCode !== 0) return null;
  const raw = out.stdout.toString().trim();
  if (raw.length === 0) return null;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

function oldestProcessStartTimeMs(pids: number[]): number | null {
  const starts = pids
    .map((pid) => processStartTimeMs(pid))
    .filter((startedAt): startedAt is number => startedAt != null);
  return starts.length > 0 ? Math.min(...starts) : null;
}

function applicability(): boolean {
  const raw =
    process.env.VOICELAYER_DEPLOY_CHECK_APPLICABLE?.trim().toLowerCase();
  if (raw === "0" || raw === "false" || raw === "no") return false;
  if (raw === "1" || raw === "true" || raw === "yes") return true;
  // Auto-off on CI / non-macOS, where VoiceBar is not expected.
  if (process.env.CI) return false;
  if (process.platform !== "darwin") return false;
  return true;
}

function gatherProbe(): DeployProbe {
  const repoVersion =
    readJsonVersion(join(PACKAGE_ROOT, "package.json")) ?? "unknown";
  const repoGitCommit = readRepoGitCommit();
  const applicable = applicability();
  if (!applicable) {
    return {
      repoVersion,
      repoGitCommit,
      appPath: APP_PATH,
      appPresent: false,
      installedAppVersion: null,
      installedPlistVersion: null,
      installedGitCommit: null,
      installedBuildTimeUTC: null,
      installedBuildTimeMs: null,
      voiceBarRunning: false,
      voiceBarStartedAtMs: null,
      daemonChildAlive: false,
      daemonChildStartedAtMs: null,
      applicable,
    };
  }

  const appPresent = existsSync(APP_PATH);
  const installedPackagePath = join(
    APP_PATH,
    "Contents",
    "Resources",
    "package.json",
  );
  const installedBuildTimeUTC = appPresent
    ? readPlistString(APP_PATH, "BuildTimeUTC")
    : null;
  const rows = processRows();
  const voiceBarPids = appProcessPids(APP_PATH, rows);
  const daemonChildPids = childProcessPids(
    voiceBarPids,
    "mcp-server-daemon",
    rows,
  );

  return {
    repoVersion,
    repoGitCommit,
    appPath: APP_PATH,
    appPresent,
    installedAppVersion: appPresent
      ? readJsonVersion(installedPackagePath)
      : null,
    installedPlistVersion: appPresent
      ? readPlistString(APP_PATH, "CFBundleShortVersionString")
      : null,
    installedGitCommit: appPresent ? readPlistString(APP_PATH, "GitCommit") : null,
    installedBuildTimeUTC,
    installedBuildTimeMs: parseBuildTimeMs(installedBuildTimeUTC),
    voiceBarRunning: voiceBarPids.length > 0,
    voiceBarStartedAtMs: oldestProcessStartTimeMs(voiceBarPids),
    daemonChildAlive: daemonChildPids.length > 0,
    daemonChildStartedAtMs: oldestProcessStartTimeMs(daemonChildPids),
    applicable,
  };
}

const assessment = evaluateDeployFreshness(gatherProbe());
console.log(formatDeployReport(assessment));
process.exit(assessment.ok ? 0 : 1);
