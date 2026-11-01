/** Optional request-scoped language warning. Never selects an STT engine. */
import { existsSync, mkdirSync, writeFileSync, unlinkSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { createHash, randomUUID } from "crypto";
import { getStateDir } from "./paths";
import { parakeetOwnerShutdownSignal } from "./parakeet-server";

export const PARAKEET_LID_MIN_CONFIDENCE = 0.8;
export const PARAKEET_LID_MAX_FRAMES = 30 * 16000;
const ownedExitStops = new Set<() => void>();
process.once("exit", () => { for (const stop of ownedExitStops) stop(); });
export interface ParakeetLanguageEvidence {
  status: "COMPLETE" | "UNKNOWN";
  language?: string;
  probability?: number;
  inputSha256?: string;
  analyzedFrames?: number;
  prefixSha256?: string;
  wallMs?: number;
  evidencePath?: string;
  errorType?: string;
}
export interface ParakeetLanguageInput {
  bytes: Uint8Array;
  dataOffset: number;
  frames: number;
  inputSha256: string;
}

/** Only called after the backend's strict PCM16/mono/16k WAV validation. */
export function languagePrefix(input: ParakeetLanguageInput): Buffer {
  const frames = Math.min(input.frames, PARAKEET_LID_MAX_FRAMES);
  if (!Number.isSafeInteger(input.frames) || !Number.isSafeInteger(frames) || frames <= 0 || !Number.isSafeInteger(input.dataOffset) || input.dataOffset < 0 ||
      input.dataOffset + input.frames * 2 > input.bytes.length) throw new Error("Invalid language prefix geometry");
  const b = Buffer.alloc(44 + frames * 2);
  b.write("RIFF"); b.writeUInt32LE(b.length - 8, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(frames * 2, 40);
  b.set(input.bytes.subarray(input.dataOffset, input.dataOffset + frames * 2), 44);
  return b;
}

export function parseLanguageDetection(raw: string): Pick<ParakeetLanguageEvidence, "status" | "language" | "probability"> {
  const matches = [...raw.matchAll(/auto-detected language:\s*([a-z][a-z0-9-]*)\s*\(p\s*=\s*([0-9.eE+-]+)\)/g)];
  const p = matches.length === 1 ? Number(matches[0]![2]) : NaN;
  return Number.isFinite(p) && p >= 0 && p <= 1
    ? { status: "COMPLETE", language: matches[0]![1], probability: p }
    : { status: "UNKNOWN", language: undefined, probability: undefined };
}

/** Off by default. Model and executable must already be present; no downloads.
 * The caller waits for exit AND both EOFs before any Whisper fallback. Timeout
 * requests TERM then KILL; unresolved OS cleanup remains an admission barrier.
 */
export async function probeParakeetLanguage(input: ParakeetLanguageInput, env: NodeJS.ProcessEnv = process.env): Promise<ParakeetLanguageEvidence> {
  const at = performance.now();
  const evidence: ParakeetLanguageEvidence = { status: "UNKNOWN", inputSha256: input.inputSha256 };
  let prefixPath: string | undefined;
  try {
    if (env.VOICELAYER_TEST_ISOLATED === "1") throw new Error("Inject LID under the test preload");
    const binary = env.VOICELAYER_LID_WHISPER_CLI || "/opt/homebrew/bin/whisper-cli";
    const model = env.VOICELAYER_LID_MODEL || join(homedir(), ".cache", "whisper", "ggml-small.bin");
    if (!existsSync(binary) || !existsSync(model) || parakeetOwnerShutdownSignal.aborted) throw new Error("Language detector unavailable");
    const root = join(getStateDir(), "parakeet-language");
    mkdirSync(root, { recursive: true, mode: 0o700 });
    const id = randomUUID(), prefix = languagePrefix(input);
    prefixPath = join(root, id + ".wav");
    writeFileSync(prefixPath, prefix, { flag: "wx", mode: 0o400 });
    evidence.analyzedFrames = (prefix.length - 44) / 2;
    evidence.prefixSha256 = createHash("sha256").update(prefix).digest("hex");
    const proc = Bun.spawn([binary, "-m", model, "-f", prefixPath, "-dl", "-l", "auto", "-d", "30000", "-t", "4"],
      { env: process.env, stdout: "pipe", stderr: "pipe" });
    let exited = false;
    void proc.exited.then(() => { exited = true; }, () => {});
    const stopOnExit = () => { if (!exited) { try { proc.kill("SIGKILL"); } catch {} } };
    ownedExitStops.add(stopOnExit);
    let interrupted = false, kill: ReturnType<typeof setTimeout> | undefined;
    const stop = () => {
      if (interrupted) return;
      interrupted = true;
      try { proc.kill("SIGTERM"); } catch {}
      kill = setTimeout(() => { try { proc.kill("SIGKILL"); } catch {} }, 500); kill.unref();
    };
    const timer = setTimeout(stop, 2000); timer.unref();
    parakeetOwnerShutdownSignal.addEventListener("abort", stop, { once: true });
    if (parakeetOwnerShutdownSignal.aborted) stop();
    let overflow = false;
    const collect = async (stream: ReadableStream<Uint8Array>) => {
      const chunks: Buffer[] = []; let size = 0;
      for await (const chunk of stream) {
        const available = Math.max(0, 65536 - size);
        if (available) chunks.push(Buffer.from(chunk.subarray(0, available)));
        size = Math.min(65537, size + chunk.length);
        if (size > 65536) { overflow = true; stop(); }
      }
      return Buffer.concat(chunks).toString("utf8");
    };
    // allSettled retains the cleanup barrier even if reading one stream fails.
    const results = await Promise.allSettled([proc.exited, collect(proc.stdout), collect(proc.stderr)]);
    clearTimeout(timer); if (kill) clearTimeout(kill);
    parakeetOwnerShutdownSignal.removeEventListener("abort", stop);
    if (results.some(x => x.status === "rejected")) {
      // Do not turn an unconfirmed child/stream terminal into permission to
      // start fallback. Keep this request's ownership barrier pending.
      try { proc.kill("SIGKILL"); } catch {}
      try { writeFileSync(join(root, id + ".cleanup-unknown.json"), JSON.stringify({ ...evidence, status: "UNKNOWN", cleanup: "UNCONFIRMED" }) + "\n", { flag: "wx", mode: 0o600 }); } catch { /* Saving cannot release an unresolved cleanup barrier. */ }
      console.error("[voicelayer] Optional language detector cleanup unconfirmed; request remains held");
      await new Promise<never>(() => {});
    }
    ownedExitStops.delete(stopOnExit);
    const exit = results[0].status === "fulfilled" ? results[0].value : null;
    const stdout = results[1].status === "fulfilled" ? results[1].value : "";
    const stderr = results[2].status === "fulfilled" ? results[2].value : "";
    if (!interrupted && !overflow && exit === 0 && results.every(x => x.status === "fulfilled")) Object.assign(evidence, parseLanguageDetection(stdout + "\n" + stderr));
    evidence.wallMs = performance.now() - at;
    const path = join(root, id + ".json");
    writeFileSync(path, JSON.stringify({ ...evidence, exit, interrupted, overflow, stdout, stderr, route: "WARNING_ONLY" }) + "\n", { flag: "wx", mode: 0o600 });
    evidence.evidencePath = path;
  } catch (error) {
    evidence.errorType = error instanceof Error ? error.name : "unknown";
  } finally {
    evidence.wallMs ??= performance.now() - at;
    if (prefixPath) { try { unlinkSync(prefixPath); } catch { console.error("[voicelayer] Could not remove private language prefix"); } }
  }
  return evidence;
}
