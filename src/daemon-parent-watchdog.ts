export interface ParentLossDetails {
  initialParentPid: number;
  currentParentPid: number;
}

export interface ParentProcessWatchdog {
  stop(): void;
}

export interface ParentProcessWatchdogOptions {
  initialParentPid?: number;
  getParentPid?: () => number;
  intervalMs?: number;
  onParentLost: (details: ParentLossDetails) => void;
  setIntervalFn?: (
    callback: () => void,
    intervalMs: number,
  ) => ReturnType<typeof setInterval> | unknown;
  clearIntervalFn?: (timer: ReturnType<typeof setInterval> | unknown) => void;
}

const DEFAULT_PARENT_WATCHDOG_INTERVAL_MS = 1_000;

type SpawnSyncForParentPid = (
  command: string[],
  options?: { stdout: "pipe"; stderr: "ignore" },
) => {
  exitCode: number | null;
  stdout: ArrayBuffer | ArrayBufferView | string;
};

const defaultSpawnSyncForParentPid: SpawnSyncForParentPid = (
  command,
  options,
) =>
  Bun.spawnSync({
    cmd: command,
    stdout: options?.stdout ?? "pipe",
    stderr: options?.stderr ?? "ignore",
  });

export function startParentProcessWatchdog({
  initialParentPid = resolveInitialParentPid(),
  getParentPid = () => readProcessParentPid(),
  intervalMs = DEFAULT_PARENT_WATCHDOG_INTERVAL_MS,
  onParentLost,
  setIntervalFn = setInterval,
  clearIntervalFn = (timer) => {
    clearInterval(timer as ReturnType<typeof setInterval>);
  },
}: ParentProcessWatchdogOptions): ParentProcessWatchdog {
  if (!Number.isFinite(initialParentPid) || initialParentPid <= 1) {
    return { stop() {} };
  }

  let stopped = false;
  let timer: ReturnType<typeof setInterval> | unknown;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    if (timer !== undefined) clearIntervalFn(timer);
  };

  const checkParent = () => {
    if (stopped) return;
    const currentParentPid = getParentPid();
    if (currentParentPid === initialParentPid && currentParentPid > 1) return;

    stop();
    onParentLost({ initialParentPid, currentParentPid });
  };

  timer = setIntervalFn(checkParent, intervalMs);
  if (timer && typeof timer === "object" && "unref" in timer) {
    (timer as { unref: () => void }).unref();
  }

  return { stop };
}

export function readProcessParentPid(
  pid = process.pid,
  spawnSync: SpawnSyncForParentPid = defaultSpawnSyncForParentPid,
  fallbackParentPid = process.ppid,
): number {
  try {
    const result = spawnSync(["ps", "-p", String(pid), "-o", "ppid="], {
      stdout: "pipe",
      stderr: "ignore",
    });
    if (result.exitCode !== 0) return fallbackParentPid;
    const output =
      typeof result.stdout === "string"
        ? result.stdout
        : new TextDecoder().decode(result.stdout);
    const parentPid = Number.parseInt(output.trim(), 10);
    return Number.isFinite(parentPid) ? parentPid : fallbackParentPid;
  } catch {
    return fallbackParentPid;
  }
}

export function resolveInitialParentPid(
  environment: Record<string, string | undefined> = process.env,
  fallbackParentPid = process.ppid,
): number {
  const rawParentPid = environment.VOICEBAR_PARENT_PID?.trim();
  if (!rawParentPid) return fallbackParentPid;
  const parsedParentPid = Number.parseInt(rawParentPid, 10);
  return Number.isFinite(parsedParentPid) ? parsedParentPid : fallbackParentPid;
}
