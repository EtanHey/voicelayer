/** Status accessors use metadata only; launch identity explicitly hashes weights. */
import { statSync, readFileSync, mkdirSync } from "fs";
import { isAbsolute, join, resolve } from "path";
import { homedir } from "os";
import { getStateDir, safeWriteFileSync } from "./paths";
import type { Recognizer } from "./recognizer-state";
export const PARAKEET_FILES = ["config.json", "model.safetensors", "tokenizer.model"] as const;
export function defaultParakeetModelPath(env: NodeJS.ProcessEnv = process.env): string {
  return join(env.XDG_CACHE_HOME || join(homedir(), ".cache"), "voicelayer", "models", "parakeet-tdt-0.6b-v3");
}
export function parakeetPython(env: NodeJS.ProcessEnv = process.env): string | null {
  if (env.VOICELAYER_PARAKEET_PYTHON) return env.VOICELAYER_PARAKEET_PYTHON;
  try {
    const state = JSON.parse(readFileSync(join(getStateDir(), "parakeet-runtime.json"), "utf8"));
    return state.version === 1 && typeof state.python === "string" ? state.python : null;
  } catch { return null; }
}
export function whisperAssetPath(env: NodeJS.ProcessEnv = process.env): string {
  if (env.QA_VOICE_WHISPER_MODEL) return resolve(env.QA_VOICE_WHISPER_MODEL);
  return join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo.bin");
}
/** Resolve only the configured asset, never a substitute model. */
export function availableWhisperModelPath(): string | null {
  const path = whisperAssetPath();
  return fileBytes(path) > 0 ? path : null;
}
export function requireWhisperModelPath(): string {
  const path = availableWhisperModelPath();
  if (!path) throw new Error(`Whisper model is missing: ${whisperAssetPath()}. Download it in Settings.`);
  return path;
}
export function recognizerAssetPaths(engine: Recognizer, env: NodeJS.ProcessEnv = process.env): string[] {
  return engine === "whisper" ? [whisperAssetPath(env)] : PARAKEET_FILES.map(name =>
    join(env.VOICELAYER_PARAKEET_MODEL || defaultParakeetModelPath(env), name));
}
function fileBytes(path: string): number {
  try { const info = statSync(path); return info.isFile() ? info.size : 0; } catch { return 0; }
}
export function readRecognizerAssets(engine: Recognizer, env: NodeJS.ProcessEnv = process.env): { assets_present: boolean; disk_bytes: number } {
  const paths = recognizerAssetPaths(engine, env), sizes = paths.map(fileBytes);
  const python = engine === "parakeet" ? parakeetPython(env) : null;
  return { assets_present: paths.every(isAbsolute) && sizes.every(size => size > 0) &&
    (engine !== "parakeet" || !!python && isAbsolute(python) && fileBytes(python) > 0),
    disk_bytes: sizes.reduce((sum, size) => sum + size, 0) };
}

/** Reuse only a hash computed for this exact file generation, across daemon boots. */
export async function whisperLaunchIdentity(path: string): Promise<string> {
  const fingerprint = () => {
    const s = statSync(path, { bigint: true });
    return `${s.dev}:${s.ino}:${s.size}:${s.mtimeNs}:${s.ctimeNs}`;
  };
  const before = fingerprint();
  const { createHash } = await import("crypto");
  const directory = join(getStateDir(), "whisper-identities");
  const cache = join(directory, createHash("sha256").update(resolve(path)).digest("hex") + ".json");
  try {
    const record = JSON.parse(readFileSync(cache, "utf8"));
    if (record.version === 1 && record.path === resolve(path) && record.fingerprint === before &&
        typeof record.sha256 === "string" && /^[a-f0-9]{64}$/.test(record.sha256) && fingerprint() === before) return record.sha256;
  } catch { /* Missing, malformed or stale cache requires a full identity read. */ }
  const { hashWhisperWeights } = await import("./whisper-model-identity");
  const sha256 = await hashWhisperWeights(path);
  if (fingerprint() !== before) throw new Error("Whisper model changed while hashing");
  try {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    safeWriteFileSync(cache, JSON.stringify({ version: 1, path: resolve(path), fingerprint: before, sha256 }) + "\n");
  } catch { console.error("[voicelayer] Could not cache Whisper model identity; next boot will hash again"); }
  return sha256;
}
