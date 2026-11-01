/** PATH Python dispatcher: inspect only the script operand, never script data. */
import { pythonScriptOperand, isRealParakeetWorker } from "./stt-parakeet-policy";
let [runtime, ...args] = process.argv.slice(2);
const { basename } = await import("node:path");
const runtimes: Record<string, string> = JSON.parse(process.env.VOICELAYER_TEST_STT_PYTHON_MAP ?? "{}");
runtime = runtimes[basename(process.argv[1]!)] ?? runtime;
const roots: string[] = JSON.parse(process.env.VOICELAYER_TEST_STT_FIXTURE_ROOTS ?? "[]");
const configured = process.env.VOICELAYER_PARAKEET_PYTHON;
const { realpathSync } = await import("node:fs");
let protectedRuntime = false;
try { protectedRuntime = !!configured && realpathSync(configured) === realpathSync(runtime!) && !roots.some(r => realpathSync(runtime!).startsWith(r + "/")); } catch {}
if (protectedRuntime || isRealParakeetWorker(pythonScriptOperand(args), roots)) {
  process.env.VOICELAYER_TEST_STT_ENGINE = "parakeet";
  await import("./stt-denied");
}
// Replace this process: fixture cleanup and signals must see the real Python
// PID, not an extra Bun supervisor. No model/worker is imported by dispatch.
if (!process.execve) throw new Error("STT Python dispatcher requires execve support");
process.execve(runtime!, [runtime!, ...args], Object.fromEntries(
  Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
));
throw new Error("STT Python execve unexpectedly returned");
