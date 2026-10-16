import { homedir } from "os";
import { join, resolve } from "path";

/** No filesystem probes or HOME fallback until private-corpus access is opted in. */
export function privateSpecimenRoot(env: NodeJS.ProcessEnv = process.env): string | null {
  const explicit = env.VOICELAYER_TEST_SPECIMEN_DIR?.trim();
  if (explicit) return resolve(explicit);
  if (env.VOICELAYER_TEST_REAL_ARCHIVE?.trim() !== "1") return null;
  return join(env.HOME || homedir(), ".local/share/voicelayer/recordings");
}
