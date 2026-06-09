export type McpSocketStartupDecision =
  | { action: "continue" }
  | { action: "stand_down"; exitCode: 0 };

export interface ResolveMcpSocketStartupOptions {
  socketPath: string;
  isSocketLive: (socketPath: string) => Promise<boolean>;
  sleep?: (delayMs: number) => Promise<void>;
  log?: (message: string) => void;
}

const STARTUP_CHECK_DELAYS_MS = [0, 200, 500];
const STAND_DOWN_CONFIRMATION_DELAYS_MS = [300, 700, 1500];

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
