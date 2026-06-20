export type McpSocketStartupDecision =
  | { action: "continue" }
  | { action: "stand_down"; exitCode: 0 };

export type McpPidOwnerStartupDecision =
  | {
      action: "stand_down";
      reason: "socket_live" | "daemon_starting";
      ownerCommandKind: PidOwnerCommandKind;
    }
  | {
      action: "reclaim";
      reason: "no_socket_live";
      ownerCommandKind: PidOwnerCommandKind;
    };

export type OrphanStartupDecision =
  | { action: "run"; reason: "parent_alive" | "orphan_override" }
  | { action: "stand_down"; reason: "missing_parent" | "parent_not_alive" };

export type PidOwnerCommandKind =
  | "mcp-daemon"
  | "legacy-or-unrelated"
  | "unknown";

export interface ResolveMcpSocketStartupOptions {
  socketPath: string;
  isSocketLive: (socketPath: string) => Promise<boolean>;
  sleep?: (delayMs: number) => Promise<void>;
  log?: (message: string) => void;
}

const STARTUP_CHECK_DELAYS_MS = [0, 200, 500];
const STAND_DOWN_CONFIRMATION_DELAYS_MS = [300, 700, 1500];
const PID_OWNER_SOCKET_GRACE_DELAYS_MS = [0, 250, 750, 1500];

export function resolveOrphanStartupDecision({
  initialParentPid,
  isParentAlive,
  allowOrphan,
}: {
  initialParentPid: number;
  isParentAlive: boolean;
  allowOrphan: boolean;
}): OrphanStartupDecision {
  if (allowOrphan) {
    return { action: "run", reason: "orphan_override" };
  }
  if (!Number.isFinite(initialParentPid) || initialParentPid <= 1) {
    return { action: "stand_down", reason: "missing_parent" };
  }
  if (!isParentAlive) {
    return { action: "stand_down", reason: "parent_not_alive" };
  }
  return { action: "run", reason: "parent_alive" };
}

/**
 * Liveness probe for the VoiceBar parent at daemon startup. Signal 0 sends
 * nothing — it only checks existence/permission. EPERM means the process is
 * alive but not signalable by us, so it counts as alive. PIDs <= 1 (no real
 * parent / reparented to launchd) are never alive.
 */
export function isProcessAlive(
  pid: number,
  kill: (pid: number, signal: number) => void = (p, s) => process.kill(p, s),
): boolean {
  if (!Number.isFinite(pid) || pid <= 1) return false;
  try {
    kill(pid, 0);
    return true;
  } catch (err: unknown) {
    return (
      typeof err === "object" &&
      err !== null &&
      "code" in err &&
      err.code === "EPERM"
    );
  }
}

/**
 * Decide whether this daemon instance may claim the MCP socket.
 *
 * A live socket is a healthy owner, not an orphan. Redundant instances must
 * stand down cleanly so launchd/VoiceBar do not enter a crash-respawn loop.
 */
export async function resolveMcpSocketStartup({
  socketPath,
  isSocketLive,
  sleep = Bun.sleep,
  log = console.error,
}: ResolveMcpSocketStartupOptions): Promise<McpSocketStartupDecision> {
  for (const delayMs of STARTUP_CHECK_DELAYS_MS) {
    if (delayMs > 0) await sleep(delayMs);
    if (!(await isSocketLive(socketPath))) {
      return { action: "continue" };
    }
  }

  log(
    `[voicelayer-daemon] Another daemon is already listening on ${socketPath}; confirming before standing down`,
  );

  for (const delayMs of STAND_DOWN_CONFIRMATION_DELAYS_MS) {
    await sleep(delayMs);
    if (!(await isSocketLive(socketPath))) {
      return { action: "continue" };
    }
  }

  log(
    `[voicelayer-daemon] Healthy MCP socket owner still live on ${socketPath}; standing down`,
  );
  return { action: "stand_down", exitCode: 0 };
}

export interface ResolveMcpPidOwnerStartupOptions {
  ownerPid: number;
  socketPath: string;
  isSocketLive: (socketPath: string) => Promise<boolean>;
  readProcessCommand?: (pid: number) => string | null;
  sleep?: (delayMs: number) => Promise<void>;
  log?: (message: string) => void;
}

export async function resolveMcpPidOwnerStartup({
  ownerPid,
  socketPath,
  isSocketLive,
  readProcessCommand = readProcessCommandLine,
  sleep = Bun.sleep,
  log = console.error,
}: ResolveMcpPidOwnerStartupOptions): Promise<McpPidOwnerStartupDecision> {
  for (const delayMs of PID_OWNER_SOCKET_GRACE_DELAYS_MS) {
    if (delayMs > 0) await sleep(delayMs);
    if (await isSocketLive(socketPath)) {
      log(
        `[voicelayer-daemon] MCP PID owner still alive with live socket (PID ${ownerPid}); standing down`,
      );
      return {
        action: "stand_down",
        reason: "socket_live",
        ownerCommandKind: "mcp-daemon",
      };
    }
  }

  const ownerCommandKind = classifyPidOwnerCommand(
    readProcessCommand(ownerPid),
  );
  if (ownerCommandKind === "mcp-daemon") {
    log(
      `[voicelayer-daemon] MCP PID owner appears to be a starting daemon without a live socket yet (PID ${ownerPid}); standing down`,
    );
    return {
      action: "stand_down",
      reason: "daemon_starting",
      ownerCommandKind,
    };
  }

  log(
    `[voicelayer-daemon] MCP PID owner is alive but has no live socket (PID ${ownerPid}, kind ${ownerCommandKind}); reclaiming lock`,
  );
  return {
    action: "reclaim",
    reason: "no_socket_live",
    ownerCommandKind,
  };
}

export function classifyPidOwnerCommand(
  command: string | null | undefined,
): PidOwnerCommandKind {
  if (!command) return "unknown";
  return command.includes("mcp-server-daemon.ts") ||
    command.includes("mcp-server-daemon.js")
    ? "mcp-daemon"
    : "legacy-or-unrelated";
}

export function readProcessCommandLine(pid: number): string | null {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    const result = Bun.spawnSync(["ps", "-p", String(pid), "-o", "command="], {
      stdout: "pipe",
      stderr: "ignore",
    });
    if (result.exitCode !== 0) return null;
    const command = new TextDecoder().decode(result.stdout).trim();
    return command || null;
  } catch {
    return null;
  }
}
