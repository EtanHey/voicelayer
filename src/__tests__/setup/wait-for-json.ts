import { readFileSync } from "node:fs";

/** Fixture readiness may be published by a writer that has not finished its file yet. */
export async function waitForJsonFile(path: string, timeoutMs = 20_000): Promise<unknown> {
  const deadline = performance.now() + timeoutMs;
  while (true) {
    try {
      return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
      const missing = error instanceof Error && "code" in error && error.code === "ENOENT";
      if (!(error instanceof SyntaxError) && !missing) throw error;
      if (performance.now() >= deadline) throw error;
      await Bun.sleep(10);
    }
  }
}
