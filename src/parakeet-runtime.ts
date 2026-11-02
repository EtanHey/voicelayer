/** Explicit setup only. The lock includes every distribution, with wheel hashes. */
import { mkdirSync, mkdtempSync, renameSync, rmSync, existsSync } from "fs";
import { join } from "path";
import { randomUUID } from "crypto";
import { getStateDir, safeWriteFileSync } from "./paths";
import { parakeetPython } from "./recognizer-assets";
const validate = "import sys, platform, importlib.metadata as m; assert platform.machine() == 'arm64'; assert sys.platform == 'darwin' and (3,12) <= sys.version_info[:2] < (3,15); assert m.version('mlx-audio') == '0.6.3'; from mlx_audio.stt.utils import load_model";
async function python(args: string[], signal: AbortSignal): Promise<void> {
  signal.throwIfAborted();
  const proc = Bun.spawn(args, { env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1", HF_HUB_OFFLINE: "1" }, stdout: "ignore", stderr: "ignore" });
  const cancel = () => { try { proc.kill("SIGTERM"); } catch {} };
  signal.addEventListener("abort", cancel, { once: true });
  try { if (signal.aborted) cancel(); if (await proc.exited !== 0) throw new Error("parakeet-runtime-setup-failed"); signal.throwIfAborted(); }
  finally { signal.removeEventListener("abort", cancel); }
}
export async function provisionParakeetRuntime(signal: AbortSignal): Promise<void> {
  if (process.env.VOICELAYER_TEST_ISOLATED === "1") throw new Error("runtime-network-denied-in-tests");
  const existing = parakeetPython();
  if (existing && existsSync(existing)) { await python([existing, "-B", "-c", validate], signal); return; }
  if (process.env.VOICELAYER_PARAKEET_PYTHON) throw new Error("configured-python-missing");
  const base = ["python3.14", "python3.13", "python3.12", "python3"].map(name => Bun.which(name)).find(Boolean);
  if (!base) throw new Error("python-runtime-missing");
  const root = join(getStateDir(), "runtimes"); mkdirSync(root, { recursive: true, mode: 0o700 });
  const tmp = mkdtempSync(join(root, ".parakeet-")), target = join(root, "parakeet-0.6.3-" + randomUUID());
  let published = false;
  try {
    await python([base, "-B", "-m", "venv", tmp], signal);
    const executable = join(tmp, "bin", "python");
    await python([executable, "-B", "-m", "pip", "--isolated", "install", "--index-url", "https://pypi.org/simple", "--no-cache-dir", "--require-hashes", "--only-binary=:all:", "--no-deps", "--no-compile", "-r", join(import.meta.dir, "parakeet-runtime.lock")], signal);
    await python([executable, "-B", "-m", "pip", "check"], signal);
    await python([executable, "-B", "-c", validate], signal);
    signal.throwIfAborted(); renameSync(tmp, target); published = true;
    const state = join(getStateDir(), "parakeet-runtime.json"), pending = state + "." + randomUUID();
    try { safeWriteFileSync(pending, JSON.stringify({ version: 1, python: join(target, "bin", "python"), mlx_audio: "0.6.3" }) + "\n"); renameSync(pending, state); }
    finally { rmSync(pending, { force: true }); }
  } catch (error) { if (published) rmSync(target, { recursive: true, force: true }); throw error; }
  finally { rmSync(tmp, { recursive: true, force: true }); }
}
