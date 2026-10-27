import { readFileSync, renameSync, rmSync } from "fs";
import { join } from "path";
import { getStateDir, safeWriteFileSync } from "./paths";

type Env = Record<string, string | undefined>;
const DEFAULT_SECONDS = 600;
const validSeconds = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value > 0 && value <= 2_147_483;
const settingsPath = (env: Env) => env.VOICELAYER_MODEL_SETTINGS_PATH?.trim() || join(getStateDir(env), "model-residency.json");

export function modelIdleSeconds(env: Env = process.env): number {
  if (env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS !== undefined) {
    const value = Number(env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS);
    return validSeconds(value) ? value : DEFAULT_SECONDS;
  }
  const path = settingsPath(env);
  try {
    const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (raw && typeof raw === "object" && "idle_unload_seconds" in raw && validSeconds(raw.idle_unload_seconds)) return raw.idle_unload_seconds;
  } catch {}
  return DEFAULT_SECONDS;
}

export function setModelIdleSeconds(seconds: number, env: Env = process.env): void {
  if (!validSeconds(seconds)) throw new Error("Model idle timeout must be positive and at most 2147483 seconds");
  const path = settingsPath(env), tmp = `${path}.${process.pid}.tmp`;
  safeWriteFileSync(tmp, JSON.stringify({ version: 1, idle_unload_seconds: seconds }) + "\n");
  try { renameSync(tmp, path); } finally { rmSync(tmp, { force: true }); }
}

export class ModelResidency {
  private users = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private unloading: Promise<void> | null = null;
  private generation = 0;

  constructor(private readonly unload: () => Promise<void | boolean>, private readonly seconds: () => number = modelIdleSeconds) {}

  reset(): void { clearTimeout(this.timer); this.generation++; }

  async use<T>(work: () => Promise<T>): Promise<T> {
    this.reset();
    this.users++;
    try {
      if (this.unloading) await this.unloading;
      return await work();
    } finally {
      if (--this.users === 0) this.arm();
    }
  }

  private arm(): void {
    const generation = this.generation;
    this.timer = setTimeout(() => {
      if (this.users || generation !== this.generation) return;
      this.unloading = Promise.resolve().then(this.unload).then((result) => {
        if (result === false && !this.users && generation === this.generation) this.arm();
      }).catch((error: unknown) => {
        console.error("[voicelayer] Model idle unload failed:", error);
        if (!this.users && generation === this.generation) this.arm();
      }).finally(() => { this.unloading = null; });
    }, this.seconds() * 1000);
    this.timer.unref();
  }
}
