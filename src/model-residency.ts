import { readFileSync, renameSync, rmSync } from "fs";
import { join } from "path";
import { getStateDir, safeWriteFileSync } from "./paths";

type Env = Record<string, string | undefined>;
const DEFAULT_SECONDS = 600;
const validSeconds = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value > 0 && value <= 2_147_483;
const settingsPath = (env: Env) => env.VOICELAYER_MODEL_SETTINGS_PATH?.trim() || join(getStateDir(env), "model-residency.json");

function savedResidency(env: Env): { idle_unload_seconds: number; unload_when_idle: boolean } {
  const path = settingsPath(env);
  try {
    const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (raw && typeof raw === "object") return {
      idle_unload_seconds: "idle_unload_seconds" in raw && validSeconds(raw.idle_unload_seconds) ? raw.idle_unload_seconds : DEFAULT_SECONDS,
      unload_when_idle: "unload_when_idle" in raw && raw.unload_when_idle === true,
    };
  } catch {}
  return { idle_unload_seconds: DEFAULT_SECONDS, unload_when_idle: false };
}

/** Defined overrides lock the row, including empty/invalid values. The existing
 * timeout override retains its opt-in idle eviction behavior. */
export function modelIdlePolicy(env: Env = process.env) {
  const envVar = env.VOICELAYER_MODEL_UNLOAD_WHEN_IDLE !== undefined ? "VOICELAYER_MODEL_UNLOAD_WHEN_IDLE"
    : env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS !== undefined ? "VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS" : null;
  return {
    unload_when_idle: envVar === "VOICELAYER_MODEL_UNLOAD_WHEN_IDLE"
      ? /^(1|true|on|yes)$/i.test(env[envVar]?.trim() ?? "")
      : envVar !== null || savedResidency(env).unload_when_idle,
    unload_when_idle_locked: envVar !== null,
    unload_when_idle_env_var: envVar,
  };
}

function saveResidency(value: ReturnType<typeof savedResidency>, env: Env): void {
  const path = settingsPath(env), tmp = `${path}.${process.pid}.tmp`;
  safeWriteFileSync(tmp, JSON.stringify({ version: 1, ...value }) + "\n");
  try { renameSync(tmp, path); } finally { rmSync(tmp, { force: true }); }
}

export function setModelUnloadWhenIdle(value: boolean, env: Env = process.env): void {
  const policy = modelIdlePolicy(env);
  if (policy.unload_when_idle_locked) throw new Error(`set by ${policy.unload_when_idle_env_var}`);
  saveResidency({ ...savedResidency(env), unload_when_idle: value }, env);
}

export function modelIdleSeconds(env: Env = process.env): number {
  if (env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS !== undefined) {
    const raw = env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
    const value = /^\s*[0-9]+(\.[0-9]+)?\s*$/.test(raw) ? Number(raw) : NaN;
    return validSeconds(value) ? value : DEFAULT_SECONDS;
  }
  return savedResidency(env).idle_unload_seconds;
}

export function setModelIdleSeconds(seconds: number, env: Env = process.env): void {
  if (!validSeconds(seconds)) throw new Error("Model idle timeout must be positive and at most 2147483 seconds");
  saveResidency({ ...savedResidency(env), idle_unload_seconds: seconds }, env);
}

export class ModelResidency {
  private users = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private unloading: Promise<void> | null = null;
  private generation = 0;

  constructor(private readonly unload: () => Promise<void | boolean>, private readonly seconds: () => number = modelIdleSeconds, private readonly isBusy: () => boolean = () => false, private readonly idleEnabled: () => boolean = () => true) {}

  get inUse(): boolean { return this.users > 0; }
  refresh(): void { this.reset(); if (!this.users) this.arm(); }

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

  private waitUntilIdle(generation: number): void {
    this.timer = setTimeout(() => {
      if (this.users || generation !== this.generation || !this.idleEnabled()) return;
      if (this.isBusy()) this.waitUntilIdle(generation);
      else this.arm();
    }, Math.min(1000, this.seconds() * 1000));
    this.timer.unref();
  }

  private arm(): void {
    if (!this.idleEnabled()) return;
    const generation = this.generation;
    this.timer = setTimeout(() => {
      if (this.users || generation !== this.generation || !this.idleEnabled()) return;
      if (this.isBusy()) { this.waitUntilIdle(generation); return; }
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
