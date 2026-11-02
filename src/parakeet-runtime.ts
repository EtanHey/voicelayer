/** Explicit setup only. The lock includes every distribution, with wheel hashes. */
import { mkdirSync, mkdtempSync, renameSync, rmSync, rmdirSync, existsSync, lstatSync } from "fs";
import { basename, dirname, join } from "path";
import { randomUUID } from "crypto";
import { getCacheDir, getStateDir, safeWriteFileSync } from "./paths";
import { parakeetPython } from "./recognizer-assets";
const validate = "import sys, platform, importlib.metadata as m; assert platform.machine() == 'arm64'; assert sys.platform == 'darwin' and (3,12) <= sys.version_info[:2] < (3,15); assert m.version('mlx-audio') == '0.6.3'; from mlx_audio.stt.utils import load_model";
async function python(args: string[], signal: AbortSignal): Promise<void> {
  if (process.env.VOICELAYER_TEST_ISOLATED === "1") throw new Error("runtime-network-denied-in-tests");
  signal.throwIfAborted();
  const proc = Bun.spawn(args, { env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1", HF_HUB_OFFLINE: "1" }, stdout: "ignore", stderr: "ignore" });
  const cancel = () => { try { proc.kill("SIGTERM"); } catch {} };
  signal.addEventListener("abort", cancel, { once: true });
  try { if (signal.aborted) cancel(); if (await proc.exited !== 0) throw new Error("parakeet-runtime-setup-failed"); signal.throwIfAborted(); }
  finally { signal.removeEventListener("abort", cancel); }
}
function publishPointer(executable: string): void {
  const state = join(getStateDir(), "parakeet-runtime.json"), pending = state + "." + randomUUID();
  mkdirSync(getStateDir(), { recursive: true, mode: 0o700 });
  try {
    safeWriteFileSync(pending, JSON.stringify({ version: 1, python: executable, mlx_audio: "0.6.3" }) + "\n");
    renameSync(pending, state);
  } finally { rmSync(pending, { force: true }); }
}

/** Filesystem-only. Caller must first ensure no process is using the old venv.
 * A deterministic destination recovers a crash between rename and pointer publication.
 * On publication failure we restore the directory and leave the original pointer intact.
 */
export function migrateLegacyParakeetRuntime(publish = publishPointer): "unchanged" | "migrated" {
  if (process.env.VOICELAYER_PARAKEET_PYTHON) return "unchanged";
  const executable = parakeetPython();
  if (!executable) return "unchanged";
  const source = dirname(dirname(executable)), name = basename(source);
  const legacyRoot = join(getStateDir(), "runtimes");
  if (dirname(source) !== legacyRoot || executable !== join(source, "bin", "python") ||
      !/^parakeet-0\.6\.3-[0-9a-f-]{36}$/.test(name)) return "unchanged";
  const root = join(getCacheDir(), "runtimes"), target = join(root, name);
  const sourceExists = existsSync(source), targetExists = existsSync(target);
  if (sourceExists && targetExists) throw new Error("parakeet-runtime-migration-conflict");
  if (!sourceExists && !targetExists) return "unchanged";
  const directory = sourceExists ? source : target;
  if (!lstatSync(directory).isDirectory() ||
      (sourceExists && !lstatSync(legacyRoot).isDirectory()) ||
      (targetExists && !lstatSync(root).isDirectory()) ||
      !existsSync(join(directory, "bin", "python"))) throw new Error("parakeet-runtime-migration-invalid");
  mkdirSync(root, { recursive: true, mode: 0o700 });
  if (sourceExists) renameSync(source, target);
  try { publish(join(target, "bin", "python")); }
  catch (error) { renameSync(target, source); throw error; }
  // Only remove the now-empty managed container; unrelated legacy contents stay put.
  try { rmdirSync(legacyRoot); } catch {}
  return "migrated";
}

export interface ParakeetRuntimeDependencies {
  run: typeof python;
  findPython: () => string | null;
}

export async function provisionParakeetRuntime(signal: AbortSignal, deps?: ParakeetRuntimeDependencies): Promise<void> {
  if (process.env.VOICELAYER_TEST_ISOLATED === "1" && !deps) throw new Error("runtime-network-denied-in-tests");
  signal.throwIfAborted();
  migrateLegacyParakeetRuntime();
  const run = deps?.run ?? python;
  const existing = parakeetPython();
  if (existing && existsSync(existing)) { await run([existing, "-B", "-c", validate], signal); return; }
  if (process.env.VOICELAYER_PARAKEET_PYTHON) throw new Error("configured-python-missing");
  const base = deps ? deps.findPython() : ["python3.14", "python3.13", "python3.12", "python3"].map(name => Bun.which(name)).find(Boolean);
  if (!base) throw new Error("python-runtime-missing");
  const root = join(getCacheDir(), "runtimes"); mkdirSync(root, { recursive: true, mode: 0o700 });
  const tmp = mkdtempSync(join(root, ".parakeet-")), target = join(root, "parakeet-0.6.3-" + randomUUID());
  let published = false;
  try {
    await run([base, "-B", "-m", "venv", tmp], signal);
    const executable = join(tmp, "bin", "python");
    await run([executable, "-B", "-m", "pip", "--isolated", "install", "--index-url", "https://pypi.org/simple", "--no-cache-dir", "--require-hashes", "--only-binary=:all:", "--no-deps", "--no-compile", "-r", join(import.meta.dir, "parakeet-runtime.lock")], signal);
    await run([executable, "-B", "-m", "pip", "check"], signal);
    await run([executable, "-B", "-c", validate], signal);
    signal.throwIfAborted(); renameSync(tmp, target); published = true;
    publishPointer(join(target, "bin", "python"));
  } catch (error) { if (published) rmSync(target, { recursive: true, force: true }); throw error; }
  finally { rmSync(tmp, { recursive: true, force: true }); }
}
