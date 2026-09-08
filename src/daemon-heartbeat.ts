import { randomUUID } from "crypto";
import {
  existsSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { mcpHeartbeatFilePath } from "./paths";

const DEFAULT_HEARTBEAT_INTERVAL_MS = 1_000;
const DEFAULT_GAP_LOG_THRESHOLD_MS = 15_000;

export interface DaemonHeartbeat {
  pid: number;
  sequence: number;
  updated_at: string;
}

export interface DaemonHeartbeatPublisher {
  stop(): void;
}

interface DaemonHeartbeatOptions {
  path?: string;
  pid?: number;
  intervalMs?: number;
  gapLogThresholdMs?: number;
  now?: () => Date;
  log?: (message: string) => void;
}

export function startDaemonHeartbeat(
  options: DaemonHeartbeatOptions = {},
): DaemonHeartbeatPublisher {
  const path = options.path ?? mcpHeartbeatFilePath();
  const pid = options.pid ?? process.pid;
  const intervalMs = options.intervalMs ?? DEFAULT_HEARTBEAT_INTERVAL_MS;
  const gapLogThresholdMs =
    options.gapLogThresholdMs ?? DEFAULT_GAP_LOG_THRESHOLD_MS;
  const now = options.now ?? (() => new Date());
  const log = options.log ?? console.error;
  let sequence = 0;
  let lastPublishedAt: Date | null = null;
  let lastPublishedSequence: number | null = null;
  let stopped = false;

  const publish = () => {
    if (stopped) return;
    const publishedAt = now();
    const temporaryPath = `${path}.${pid}.${randomUUID()}.tmp`;
    sequence += 1;
    const heartbeat: DaemonHeartbeat = {
      pid,
      sequence,
      updated_at: publishedAt.toISOString(),
    };
    try {
      writeFileSync(temporaryPath, `${JSON.stringify(heartbeat)}\n`, {
        flag: "wx",
        mode: 0o600,
      });
      renameSync(temporaryPath, path);
      if (lastPublishedAt && lastPublishedSequence !== null) {
        const elapsedMs = publishedAt.getTime() - lastPublishedAt.getTime();
        if (elapsedMs > gapLogThresholdMs) {
          log(
            `[voicelayer-daemon] Heartbeat publish gap sequence ${lastPublishedSequence} -> ${sequence}: ${(elapsedMs / 1_000).toFixed(3)}s`,
          );
        }
      }
      lastPublishedAt = publishedAt;
      lastPublishedSequence = sequence;
    } catch (error) {
      try {
        if (existsSync(temporaryPath)) unlinkSync(temporaryPath);
      } catch {}
      log(
        `[voicelayer-daemon] Heartbeat write failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  };

  publish();
  const timer = setInterval(publish, intervalMs);
  timer.unref?.();

  return {
    stop() {
      if (stopped) return;
      stopped = true;
      clearInterval(timer);
      try {
        if (!existsSync(path)) return;
        const current = JSON.parse(readFileSync(path, "utf8")) as {
          pid?: unknown;
        };
        // An old owner must never unlink a successor's heartbeat.
        if (current.pid === pid) unlinkSync(path);
      } catch {}
    },
  };
}
