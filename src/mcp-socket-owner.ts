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

/**
 * Best-effort reclamation for a live MCP socket owner.
 * Returns the PIDs that were targeted for SIGTERM, not a guarantee that every
 * process exited before the function returned.
 */
export function terminateSocketOwners(socketPath: string): number[] {
  const pids = findSocketOwnerPids(socketPath);
  for (const pid of pids) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {}
  }
  return pids;
}
