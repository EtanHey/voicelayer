import { homedir } from "node:os";
import { realpathSync, readdirSync, lstatSync, readlinkSync } from "node:fs";
import { basename, resolve, sep, join, dirname } from "node:path";

/** Python's first script operand only. -c/-m/stdin and later data are not scripts. */
export function pythonScriptOperand(args: string[]): string | undefined {
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--") return args[i + 1];
    if (arg === "-" || /^-(?:[bBdEiIOPqRsSuvx]*[cm]|h|V)/.test(arg) || arg === "--help" || arg === "--version") return;
    if (["-W", "-X", "--check-hash-based-pycs"].includes(arg)) { i++; continue; }
    if (arg.startsWith("-")) continue;
    return arg;
  }
  return undefined;
}
export function isRealParakeetWorker(path: string | undefined, roots: string[]): boolean {
  if (!path) return false;
  let actual = resolve(path);
  try { actual = realpathSync(actual); } catch {}
  if (!/^parakeet[-_]worker\.py$/.test(basename(path)) && !/^parakeet[-_]worker\.py$/.test(basename(actual))) return false;
  return !roots.some(root => actual.startsWith(root + sep));
}
export function canonicalRuntime(path?: string): string | undefined {
  if (!path) return;
  try { return realpathSync(path); } catch { return resolve(path); }
}

/** Hugging Face snapshot symlinks resolve to extensionless blobs. Seatbelt sees
 * those canonical targets, so a suffix rule alone cannot protect cached weights.
 * Only directory entries/realpaths are read here; no weight bytes are opened. */
function weightTarget(path: string): string {
  // Bun realpathSync opens the final file and therefore fails once its weight
  // read is denied. Resolve directory components + links using metadata only.
  for (let depth = 0; depth < 40; depth++) {
    const actual = join(realpathSync(dirname(path)), basename(path));
    if (!lstatSync(actual).isSymbolicLink()) return actual;
    path = resolve(dirname(actual), readlinkSync(actual));
  }
  throw new Error("STT guard weight target symlink loop");
}
export function canonicalWeightTargets(env: NodeJS.ProcessEnv, roots: string[]): string[] {
  const cache = env.XDG_CACHE_HOME || join(homedir(), ".cache");
  const directories = new Set([
    env.VOICELAYER_PARAKEET_MODEL || join(cache, "voicelayer", "models", "parakeet-tdt-0.6b-v3"),
    env.HF_HUB_CACHE || env.HUGGINGFACE_HUB_CACHE || join(env.HF_HOME || join(cache, "huggingface"), "hub"),
  ]);
  const targets = new Set<string>();
  for (const directory of directories) {
    const pending = [directory];
    while (pending.length) {
      const dir = pending.pop()!;
      let entries;
      try { entries = readdirSync(dir, { withFileTypes: true }); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
        throw new Error("STT guard cannot enumerate configured/cache weight targets");
      }
      for (const entry of entries) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) pending.push(path);
        else if (entry.name.endsWith(".safetensors")) {
          const actual = weightTarget(path);
          if (!roots.some(root => actual.startsWith(root + sep))) targets.add(actual);
        }
      }
    }
  }
  return [...targets].sort();
}
