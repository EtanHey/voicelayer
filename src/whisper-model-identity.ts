/** Hash the selected weights before execution; never infer identity from a sidecar. */
import { createReadStream, statSync } from "fs";
import { createHash } from "crypto";
const identities = new Map<string, { fingerprint: string; sha256: string }>();
let cliPath: string | null = null;
function fingerprint(path: string): string {
  const s = statSync(path, { bigint: true });
  return `${s.dev}:${s.ino}:${s.size}:${s.mtimeNs}:${s.ctimeNs}`;
}
export async function hashWhisperWeights(path: string): Promise<string> {
  const before = fingerprint(path);
  const cached = identities.get(path);
  if (cached?.fingerprint === before) return cached.sha256;
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  if (fingerprint(path) !== before) throw new Error(`Whisper model changed while hashing: ${path}`);
  const sha256 = hash.digest("hex");
  identities.set(path, { fingerprint: before, sha256 });
  return sha256;
}
export function executedWhisperHash(path: string): string | null {
  return identities.get(path)?.sha256 ?? null;
}
export function recordWhisperCliPath(path: string): void { cliPath = path; }
export function executedWhisperCliPath(): string | null { return cliPath; }
