const DEFAULT_MCP_SOCKET_PATH = "/tmp/voicelayer-mcp.sock";
const ALLOW_SOCKET_RECLAIM_ENV = "QA_VOICE_ALLOW_SOCKET_RECLAIM";
const VOICEBAR_ALLOW_SOCKET_RECLAIM_ENV = "VOICELAYER_ALLOW_SOCKET_RECLAIM";

export function parseLsofSocketOwnerPids(
  output: string,
  socketPath: string,
  currentPid: number = process.pid,
): number[] {
  const pids = new Set<number>();

  for (const rawLine of output.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const columns = line.split(/\s+/);
    // lsof may append NAME metadata after the path, for example
    // "/tmp/voicelayer-mcp.sock (LISTEN)". Match the path as a token so
    // suffixed paths such as "/tmp/voicelayer-mcp.sock.backup" stay excluded.
    if (!columns.includes(socketPath)) continue;

    const pid = Number(columns[1]);
    if (!Number.isInteger(pid) || pid <= 0 || pid === currentPid) continue;
    pids.add(pid);
  }

  return [...pids].sort((a, b) => a - b);
}

export function findSocketOwnerPids(socketPath: string): number[] {
  try {
    const result = Bun.spawnSync(["lsof", "-nP", "-U"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const stdout = new TextDecoder().decode(result.stdout);
    return parseLsofSocketOwnerPids(stdout, socketPath);
  } catch {
    return [];
  }
}

export function canReclaimSocketOwners(
  socketPath: string,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  if (socketPath !== DEFAULT_MCP_SOCKET_PATH) return true;
  return (
    env[ALLOW_SOCKET_RECLAIM_ENV]?.trim() === "1" ||
    env[VOICEBAR_ALLOW_SOCKET_RECLAIM_ENV]?.trim() === "1"
  );
}

/**
 * Best-effort reclamation for a live MCP socket owner.
 * Returns the PIDs that were targeted for SIGTERM, not a guarantee that every
 * process exited before the function returned.
 */
export function terminateSocketOwners(socketPath: string): number[] {
  if (!canReclaimSocketOwners(socketPath)) {
    console.error(
      `[voicelayer-daemon] Refusing to reclaim default MCP socket without ${ALLOW_SOCKET_RECLAIM_ENV}=1: ${socketPath}`,
    );
    return [];
  }

  const pids = findSocketOwnerPids(socketPath);
  for (const pid of pids) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {}
  }
  return pids;
}
