/**
 * Post-merge deploy freshness gate (Track 5 #1 — the runnable "deliver-the-
 * artifact post-merge deploy checklist").
 *
 * Build-green + PR-merged is NOT delivered. The recurring regression this guards
 * is the gap between "merged to main" and "the running Mac actually has it":
 * a merge bumps the version, but `/Applications/VoiceBar.app` is never rebuilt,
 * or the rebuilt app is never relaunched, or the daemon child died — so the
 * daily-driver keeps running stale code. (R-004 deliver-the-artifact; the
 * stale-v9 incident 2026-06-10; "the stack didn't transfer to the M1".)
 *
 * The freshness signals are all real and machine-observable:
 *  - build provenance: `voicelayer build-app` copies the repo `package.json`
 *    into `VoiceBar.app/Contents/Resources/package.json`, so the installed
 *    bundle records the exact version it was built from. A mismatch with the
 *    repo version means the merged code never rebuilt the app.
 *  - Info.plist `CFBundleShortVersionString` (the marketing version).
 *  - liveness + freshness: VoiceBar and its MCP daemon child are alive, and
 *    their process start times are not older than the installed bundle.
 *
 * This module is the deterministic core so it has a CI-safe RED→GREEN gate
 * (src/__tests__/deploy-check.test.ts): it must CATCH every flavor of "not
 * actually deployed" and PASS only a genuinely fresh + live install. The probe
 * is gathered by scripts/voicelayer-deploy-check.sh on the target Mac.
 */

export interface DeployProbe {
  /** Version from the repo's package.json (the just-merged source of truth). */
  repoVersion: string;
  /** Current checkout commit when this check runs from a git worktree. */
  repoGitCommit: string | null;
  /** Installed app path being evaluated. Defaults to `/Applications/VoiceBar.app`. */
  appPath?: string;
  /** Whether the configured VoiceBar.app bundle exists on this machine. */
  appPresent: boolean;
  /** Version recorded in the installed bundle's Contents/Resources/package.json. */
  installedAppVersion: string | null;
  /** Installed bundle's Info.plist CFBundleShortVersionString. */
  installedPlistVersion: string | null;
  /** Installed bundle's Info.plist GitCommit stamp. */
  installedGitCommit: string | null;
  /** Installed bundle's Info.plist BuildTimeUTC stamp. */
  installedBuildTimeUTC: string | null;
  /** Parsed BuildTimeUTC timestamp for freshness checks. */
  installedBuildTimeMs: number | null;
  /** VoiceBar.app process is running. */
  voiceBarRunning: boolean;
  /** Oldest matching VoiceBar.app process start time, when readable. */
  voiceBarStartedAtMs: number | null;
  /** The MCP daemon child (mcp-server-daemon) is alive. */
  daemonChildAlive: boolean;
  /** Oldest matching MCP daemon child process start time, when readable. */
  daemonChildStartedAtMs: number | null;
  /**
   * Whether VoiceBar is supposed to be deployed on this box at all. Off for
   * CI / headless / remote machines so the gate reports inconclusive instead of
   * a false failure. Defaults to true (the daily-driver assumption).
   */
  applicable?: boolean;
}

export type DeployCheckStatus = "pass" | "fail" | "skip";

export interface DeployCheckResult {
  name: string;
  status: DeployCheckStatus;
  detail: string;
}

export interface DeployAssessment {
  /** True when every applicable check passed (or the box is non-applicable). */
  ok: boolean;
  /** False on CI / non-daily-driver boxes — results are inconclusive, not failing. */
  applicable: boolean;
  /** The repo (just-merged) version the install is judged against. */
  repoVersion: string;
  checks: DeployCheckResult[];
}

/**
 * Judge whether the merged artifact has actually been delivered to (and is live
 * on) this machine. Fail-closed: any version drift, missing bundle, or dead
 * process is a FAIL — never a silent pass. Non-applicable boxes short-circuit to
 * an all-skip / ok=true inconclusive result.
 */
export function evaluateDeployFreshness(probe: DeployProbe): DeployAssessment {
  const applicable = probe.applicable !== false;

  if (!applicable) {
    return {
      ok: true,
      applicable: false,
      repoVersion: probe.repoVersion,
      checks: [
        {
          name: "applicability",
          status: "skip",
          detail:
            "VoiceBar is not expected on this machine (CI/remote) — deploy freshness not evaluated.",
        },
      ],
    };
  }

  const checks: DeployCheckResult[] = [];
  const appPath = probe.appPath ?? "/Applications/VoiceBar.app";

  // 1. The bundle must exist before any other signal is meaningful.
  checks.push(
    probe.appPresent
      ? {
          name: "app-present",
          status: "pass",
          detail: `${appPath} present.`,
        }
      : {
          name: "app-present",
          status: "fail",
          detail: `${appPath} is missing — merged code was never deployed here. Run \`voicelayer update\` (or \`voicelayer build-app\`).`,
        },
  );

  // 2. Build provenance: installed bundle's package.json version == repo version.
  checks.push(
    versionCheck(
      "app-build-provenance",
      probe.repoVersion,
      probe.installedAppVersion,
      "installed VoiceBar.app was built from",
      "Rebuild + reinstall the app: `voicelayer build-app`.",
    ),
  );

  // 3. Info.plist marketing version == repo version.
  checks.push(
    versionCheck(
      "app-plist-version",
      probe.repoVersion,
      probe.installedPlistVersion,
      "installed Info.plist CFBundleShortVersionString is",
      "Bump flow-bar/bundle/Info.plist to match package.json, then rebuild.",
    ),
  );

  // 4. Info.plist GitCommit == current checkout SHA when the checker is run from git.
  checks.push(gitCommitCheck(probe.repoGitCommit, probe.installedGitCommit));

  // 5. Info.plist BuildTimeUTC must exist and parse; process freshness depends on it.
  checks.push(buildTimeUtcCheck(probe.installedBuildTimeUTC, probe.installedBuildTimeMs));

  // 6. The app must actually be running.
  checks.push(
    probe.voiceBarRunning
      ? {
          name: "voicebar-running",
          status: "pass",
          detail: "VoiceBar.app is running.",
        }
      : {
          name: "voicebar-running",
          status: "fail",
          detail: probe.appPresent
            ? "VoiceBar.app is installed but not running — relaunch it (`voicelayer bar`)."
            : "VoiceBar.app is missing, so it cannot be running — deploy it first (`voicelayer update` or `voicelayer build-app`).",
        },
  );

  // 7. The running app must not predate the installed bundle on disk.
  checks.push(
    processFreshnessCheck(
      "voicebar-process-fresh",
      probe.installedBuildTimeMs,
      probe.voiceBarStartedAtMs,
      "VoiceBar.app",
      "Relaunch VoiceBar so the rebuilt app is the running app (`voicelayer bar`).",
    ),
  );

  // 8. The MCP daemon child (the audio path) must be alive.
  checks.push(
    probe.daemonChildAlive
      ? {
          name: "daemon-child-alive",
          status: "pass",
          detail: "MCP daemon child (mcp-server-daemon) is alive.",
        }
      : {
          name: "daemon-child-alive",
          status: "fail",
          detail:
            "MCP daemon child is not alive — VoiceBar should respawn it; check /tmp/.voicelayer-daemon-disabled and relaunch.",
        },
  );

  // 9. The daemon child must also have restarted after the installed bundle.
  checks.push(
    processFreshnessCheck(
      "daemon-child-fresh",
      probe.installedBuildTimeMs,
      probe.daemonChildStartedAtMs,
      "MCP daemon child",
      "Relaunch VoiceBar so it respawns the daemon child from the rebuilt app.",
    ),
  );

  const ok = checks.every((c) => c.status !== "fail");
  return { ok, applicable: true, repoVersion: probe.repoVersion, checks };
}

function versionCheck(
  name: string,
  repoVersion: string,
  installed: string | null,
  observedPrefix: string,
  remedy: string,
): DeployCheckResult {
  if (installed == null) {
    return {
      name,
      status: "fail",
      detail: `Could not read installed version (expected ${repoVersion}). ${remedy}`,
    };
  }
  if (installed !== repoVersion) {
    return {
      name,
      status: "fail",
      detail: `Stale: ${observedPrefix} ${installed}, but repo is ${repoVersion}. ${remedy}`,
    };
  }
  return {
    name,
    status: "pass",
    detail: `${observedPrefix} ${installed} (matches repo).`,
  };
}

function gitCommitCheck(
  repoGitCommit: string | null,
  installedGitCommit: string | null,
): DeployCheckResult {
  if (repoGitCommit == null) {
    return {
      name: "app-git-commit",
      status: "skip",
      detail:
        "Current checkout commit is unavailable; package version and plist build time are still checked.",
    };
  }
  if (installedGitCommit == null) {
    return {
      name: "app-git-commit",
      status: "fail",
      detail: `Could not read installed Info.plist GitCommit (expected ${repoGitCommit.slice(0, 7)}). Rebuild + reinstall VoiceBar.`,
    };
  }
  if (installedGitCommit !== repoGitCommit) {
    return {
      name: "app-git-commit",
      status: "fail",
      detail: `Stale: installed Info.plist GitCommit is ${installedGitCommit.slice(0, 7)}, but repo HEAD is ${repoGitCommit.slice(0, 7)}. Rebuild + reinstall VoiceBar.`,
    };
  }
  return {
    name: "app-git-commit",
    status: "pass",
    detail: `installed Info.plist GitCommit ${installedGitCommit.slice(0, 7)} matches repo HEAD.`,
  };
}

function buildTimeUtcCheck(
  installedBuildTimeUTC: string | null,
  installedBuildTimeMs: number | null,
): DeployCheckResult {
  if (installedBuildTimeUTC == null) {
    return {
      name: "app-build-time-utc",
      status: "fail",
      detail:
        "Could not read installed Info.plist BuildTimeUTC. Rebuild with the provenance-stamping build script.",
    };
  }
  if (installedBuildTimeMs == null) {
    return {
      name: "app-build-time-utc",
      status: "fail",
      detail: `Installed Info.plist BuildTimeUTC is not parseable: ${installedBuildTimeUTC}. Rebuild with an ISO UTC timestamp.`,
    };
  }
  return {
    name: "app-build-time-utc",
    status: "pass",
    detail: `installed Info.plist BuildTimeUTC ${installedBuildTimeUTC} is parseable.`,
  };
}

function processFreshnessCheck(
  name: string,
  installedBuildTimeMs: number | null,
  processStartedAtMs: number | null,
  processName: string,
  remedy: string,
): DeployCheckResult {
  if (installedBuildTimeMs == null) {
    return {
      name,
      status: "fail",
      detail: `Could not read installed bundle build timestamp. ${remedy}`,
    };
  }
  if (processStartedAtMs == null) {
    return {
      name,
      status: "fail",
      detail: `Could not read ${processName} process start time. ${remedy}`,
    };
  }
  // macOS `ps -o lstart` exposes process start time only to whole seconds,
  // while filesystem mtimes include milliseconds. A same-second start cannot be
  // proven to have happened after the rebuild, so fail closed unless the
  // process start second is strictly after the bundle timestamp second.
  if (toEpochSecond(processStartedAtMs) <= toEpochSecond(installedBuildTimeMs)) {
    return {
      name,
      status: "fail",
      detail: `Stale: ${processName} started at ${new Date(
        processStartedAtMs,
      ).toISOString()}, before the installed bundle timestamp ${new Date(
        installedBuildTimeMs,
      ).toISOString()}. ${remedy}`,
    };
  }
  return {
    name,
    status: "pass",
    detail: `${processName} start time is fresh relative to the installed bundle.`,
  };
}

function toEpochSecond(timeMs: number): number {
  return Math.floor(timeMs / 1_000);
}

/** Render the assessment as a human-readable post-merge deploy checklist. */
export function formatDeployReport(assessment: DeployAssessment): string {
  const lines: string[] = [];
  lines.push("VoiceLayer post-merge deploy checklist");
  lines.push(`repo version ${assessment.repoVersion}`);
  lines.push("");

  for (const c of assessment.checks) {
    const mark =
      c.status === "pass"
        ? "✓ PASS"
        : c.status === "fail"
          ? "✗ FAIL"
          : "– SKIP";
    lines.push(`${mark}  ${c.name}: ${c.detail}`);
  }

  lines.push("");
  if (!assessment.applicable) {
    lines.push("RESULT: INCONCLUSIVE (VoiceBar not expected on this machine).");
  } else if (assessment.ok) {
    lines.push("RESULT: DEPLOYED — merged artifact is live on this machine.");
  } else {
    lines.push(
      "RESULT: NOT DEPLOYED — merged code has not reached the running stack. See failing checks above.",
    );
  }
  return lines.join("\n");
}
