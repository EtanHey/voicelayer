/** File metadata only: status never imports a runtime, opens weights or uses the network. */
import { statSync, readFileSync } from "fs";
import { isAbsolute, join } from "path";
import { homedir } from "os";
import { getStateDir } from "./paths";
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
  if (env.QA_VOICE_WHISPER_MODEL) return env.QA_VOICE_WHISPER_MODEL;
  const root = join(homedir(), ".cache", "whisper");
  return ["ggml-large-v3-turbo.bin", "ggml-large-v3-turbo-q5_0.bin", "ggml-base.en.bin", "ggml-base.bin"]
    .map(name => join(root, name)).find(path => fileBytes(path) > 0) ?? join(root, "ggml-large-v3-turbo.bin");
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
