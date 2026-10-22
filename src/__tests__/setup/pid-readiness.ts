import { watchFile, unwatchFile } from "node:fs";
import { readFile, rename, writeFile } from "node:fs/promises";

/** Watch before reading, so neither an existing marker nor its publication is lost. */
export function waitForPidFile(path: string, timeoutMs = 5_000): Promise<number> {
  return new Promise((resolve, reject) => {
    const finish = (error: Error | null, pid?: number) => {
      clearTimeout(timer);
      unwatchFile(path, observe);
      if (error) reject(error);
      else if (pid !== undefined) resolve(pid);
    };
    const observe = async () => {
      try {
        const pid = Number((await readFile(path, "utf8")).trim());
        if (Number.isSafeInteger(pid) && pid > 1) finish(null, pid);
      } catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) {
          finish(error instanceof Error ? error : new Error(String(error)));
        }
      }
    };
    // Directory events can coalesce create + write on macOS. File-stat
    // notifications also observe an in-place write to an existing empty marker.
    watchFile(path, { interval: 10, persistent: false }, observe);
    // Fixture startup is bounded by the existing 5 s subprocess-test floor.
    const timer = setTimeout(() => finish(new Error(`PID marker not ready: ${path}`)), timeoutMs);
    void observe();
  });
}

/** A numeric prefix is also a valid PID. Publish the whole receipt atomically. */
export async function publishPidFile(path: string, pid: number): Promise<void> {
  const temporary = path + ".tmp";
  await writeFile(temporary, String(pid));
  await rename(temporary, path);
}
