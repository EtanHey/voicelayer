import { throwIfAbortedSafe } from "../abort";
/** Each one-shot generator owns a process group; cancellation reaps it before returning. */
export async function runSpeechGeneration(argv: string[], signal?: AbortSignal, timeoutMs = 60_000,
  onSpawn?: (pid: number) => void): Promise<number> {
  throwIfAbortedSafe(signal);
  const proc = Bun.spawn(argv, { env: process.env, detached: true, stdout: "ignore", stderr: "ignore" });
  const kill = () => { try { process.kill(-proc.pid, "SIGKILL"); } catch {} };
  process.once("exit", kill);
  const timeout = setTimeout(kill, timeoutMs);
  signal?.addEventListener("abort", kill, { once: true });
  try {
    onSpawn?.(proc.pid);
    if (signal?.aborted) kill();
    const code = await proc.exited;
    throwIfAbortedSafe(signal);
    return code;
  } finally {
    process.removeListener("exit", kill);
    clearTimeout(timeout); signal?.removeEventListener("abort", kill);
  }
}
