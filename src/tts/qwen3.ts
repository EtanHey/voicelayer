/**
 * Qwen3-TTS HTTP bridge — connects TypeScript MCP to the Python TTS daemon.
 *
 * The daemon (src/tts_daemon.py) runs on localhost:8880, keeps the Qwen3-TTS model
 * loaded in Metal/MPS memory for fast inference (200-500ms per call).
 *
 * This module handles:
 *   - Loading voice profiles (profile.yaml)
 *   - Calling the daemon's /synthesize endpoint
 *   - Health checking and availability detection
 *   - Writing synthesized audio to temp files for playback
 */

// AIDEV-NOTE: This bridge is zero-shot — no training required.
// Voice cloning uses 3 reference clips (~18.5s total) from the profile.yaml.
// The daemon must be running for cloned voices to work (fallback: edge-tts).

import {
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
  statSync,
} from "fs";
import { join } from "path";

const DAEMON_URL = "http://127.0.0.1:8880";
const DAEMON_TIMEOUT_MS = 30_000; // 30s timeout for synthesis
const HEALTH_TIMEOUT_MS = 2_000; // 2s timeout for health check
const DEFAULT_DAEMON_AUTH_TOKEN_FILE = join(
  process.env.HOME || "~",
  ".voicelayer",
  "daemon.secret",
);

// --- Voice Profile ---

export interface ReferenceClip {
  path: string;
  text: string;
}

export interface VoiceProfile {
  name: string;
  profile_id?: string;
  directory_name?: string;
  profile_version?: string;
  speaker?: string;
  accepted?: boolean;
  aliases?: string[];
  model?: string;
  engine: string; // "qwen3-tts"
  model_path: string; // ~/.voicelayer/models/qwen3-tts-4bit
  reference_clips: ReferenceClip[]; // 3 clips, ~18.5s total
  reference_clip: string; // primary single-clip fallback
  reference_clip_sha?: string;
  reference_text?: string; // transcript of primary clip
  fallback: string; // edge-tts voice name for fallback
  created: string; // ISO date
  source?: string; // attribution URL
  superseded_by?: string;
}

const VOICES_DIR = join(process.env.HOME || "~", ".voicelayer", "voices");

/** Cache for loaded voice profiles. */
const profileCache = new Map<string, VoiceProfile>();
const profileMissCache = new Set<string>();
let voicesInventorySignature: string | null = null;
const collator = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: "base",
});

function parseBoolean(value: unknown): boolean | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase();
  if (["true", "yes", "1", "accepted"].includes(normalized)) return true;
  if (["false", "no", "0", "rejected", "superseded"].includes(normalized)) {
    return false;
  }
  return undefined;
}

function normalizeProfileToken(value: string): string {
  return value.trim().toLowerCase();
}

function profileIdentity(profile: VoiceProfile, fallback: string): string {
  return profile.profile_id || profile.name || fallback;
}

function warnOnProfileDrift(profile: VoiceProfile, requestedName: string): void {
  if (profile.accepted !== false && !profile.superseded_by) return;
  const id = profileIdentity(profile, requestedName);
  const target = profile.superseded_by
    ? ` superseded_by="${profile.superseded_by}"`
    : "";
  console.error(
    `[voicelayer] VOICE PROFILE DRIFT: requested "${requestedName}" uses non-accepted cloned voice profile "${id}"${target}. Use the latest accepted speaker alias/profile instead.`,
  );
}

/**
 * Parse a simple YAML file into a VoiceProfile.
 * Handles the specific structure of profile.yaml without requiring a full YAML parser.
 *
 * AIDEV-NOTE: We parse YAML manually to avoid adding a YAML dependency.
 * The profile.yaml structure is simple and well-defined by our own clone command.
 */
export function parseProfileYaml(content: string): VoiceProfile {
  const lines = content.split("\n");
  const result: Record<string, unknown> = {};
  const referenceClips: ReferenceClip[] = [];
  let inReferenceClips = false;
  let currentClip: Partial<ReferenceClip> | null = null;
  let arrayKey: string | null = null;

  for (const line of lines) {
    // Skip comments and empty lines
    if (line.trim().startsWith("#") || line.trim() === "") continue;

    if (!inReferenceClips && arrayKey && line.match(/^\s+-\s+/)) {
      const existing = result[arrayKey];
      const values = Array.isArray(existing) ? existing : [];
      values.push(
        line
          .replace(/^\s+-\s*/, "")
          .trim()
          .replace(/^["']|["']$/g, ""),
      );
      result[arrayKey] = values;
      continue;
    }

    // Check for reference_clips array
    if (line.match(/^reference_clips:\s*$/)) {
      inReferenceClips = true;
      arrayKey = null;
      continue;
    }

    if (inReferenceClips) {
      // Array item start
      if (line.match(/^\s+-\s+path:/)) {
        if (currentClip?.path && currentClip?.text) {
          referenceClips.push(currentClip as ReferenceClip);
        }
        currentClip = { path: line.replace(/^\s+-\s+path:\s*/, "").trim() };
        continue;
      }
      // Array item text field
      if (line.match(/^\s+text:/) && currentClip) {
        currentClip.text = line
          .replace(/^\s+text:\s*/, "")
          .trim()
          .replace(/^["']|["']$/g, "");
        continue;
      }
      // End of array — next top-level key
      if (!line.startsWith(" ") && !line.startsWith("\t")) {
        if (currentClip?.path && currentClip?.text) {
          referenceClips.push(currentClip as ReferenceClip);
        }
        currentClip = null;
        inReferenceClips = false;
        // Fall through to parse this line as a top-level key
      } else {
        continue;
      }
    }

    // Top-level key: value
    const match = line.match(/^(\w+):\s*(.+)$/);
    if (match) {
      const [, key, rawValue] = match;
      arrayKey = null;
      // Strip quotes and comments
      const value = rawValue
        .replace(/\s*#.*$/, "")
        .trim()
        .replace(/^["']|["']$/g, "");
      result[key] = value;
      continue;
    }

    const arrayMatch = line.match(/^(\w+):\s*$/);
    if (arrayMatch) {
      arrayKey = arrayMatch[1];
      result[arrayKey] = [];
    }
  }

  // Flush last reference clip
  if (currentClip?.path && currentClip?.text) {
    referenceClips.push(currentClip as ReferenceClip);
  }

  return {
    name: String(result.name || ""),
    profile_id: result.profile_id ? String(result.profile_id) : undefined,
    directory_name: undefined,
    profile_version: result.profile_version
      ? String(result.profile_version)
      : undefined,
    speaker: result.speaker ? String(result.speaker) : undefined,
    accepted: parseBoolean(result.accepted),
    aliases: Array.isArray(result.aliases)
      ? result.aliases.map(String).filter(Boolean)
      : undefined,
    model: result.model
      ? String(result.model)
      : result.model_path
        ? String(result.model_path)
        : undefined,
    engine: String(result.engine || "qwen3-tts"),
    model_path: String(result.model_path || ""),
    reference_clips: referenceClips,
    reference_clip: String(result.reference_clip || ""),
    reference_clip_sha: result.reference_clip_sha
      ? String(result.reference_clip_sha)
      : undefined,
    reference_text: result.reference_text
      ? String(result.reference_text)
      : undefined,
    fallback: String(result.fallback || "en-US-JennyNeural"),
    created: String(result.created || new Date().toISOString().split("T")[0]),
    source: result.source ? String(result.source) : undefined,
    superseded_by: result.superseded_by ? String(result.superseded_by) : undefined,
  };
}

/**
 * Load a voice profile from ~/.voicelayer/voices/{name}/profile.yaml.
 * Returns null if profile doesn't exist or is invalid.
 */
function loadProfileFromDirectory(name: string): VoiceProfile | null {
  if (!name || name.includes("/") || name.includes("\\") || name.includes(".."))
    return null;

  const cached = profileCache.get(name);
  if (cached) return cached;

  const profilePath = join(VOICES_DIR, name, "profile.yaml");
  if (!existsSync(profilePath)) return null;

  try {
    const content = readFileSync(profilePath, "utf-8");
    const profile = parseProfileYaml(content);
    if (!profile.name) profile.name = name;
    if (!profile.profile_id) profile.profile_id = profile.name || name;
    profile.directory_name = name;
    profileCache.set(name, profile);
    profileCache.set(normalizeProfileToken(profileIdentity(profile, name)), profile);
    return profile;
  } catch (err) {
    console.error(
      `[voicelayer] Failed to load voice profile "${name}": ${err}`,
    );
    return null;
  }
}

function profileMatchesAlias(profile: VoiceProfile, alias: string): boolean {
  const normalizedAlias = normalizeProfileToken(alias);
  if (profile.accepted !== true) return false;
  if (profile.speaker && normalizeProfileToken(profile.speaker) === normalizedAlias) {
    return true;
  }
  return (
    profile.aliases?.some(
      (candidate) => normalizeProfileToken(candidate) === normalizedAlias,
    ) ?? false
  );
}

function compareProfilesByFreshness(a: VoiceProfile, b: VoiceProfile): number {
  const versionCompare = collator.compare(
    a.profile_version || "",
    b.profile_version || "",
  );
  if (versionCompare !== 0) return versionCompare;
  const createdCompare = collator.compare(a.created || "", b.created || "");
  if (createdCompare !== 0) return createdCompare;
  return collator.compare(profileIdentity(a, ""), profileIdentity(b, ""));
}

function findLatestAcceptedProfileForAlias(alias: string): VoiceProfile | null {
  try {
    if (!existsSync(VOICES_DIR)) return null;
    const matches = readdirSync(VOICES_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => loadProfileFromDirectory(entry.name))
      .filter((profile): profile is VoiceProfile => profile !== null)
      .filter((profile) => profileMatchesAlias(profile, alias))
      .sort(compareProfilesByFreshness);
    return matches.at(-1) ?? null;
  } catch {
    return null;
  }
}

function findProfileByIdentity(identity: string): VoiceProfile | null {
  const normalizedIdentity = normalizeProfileToken(identity);
  try {
    if (!existsSync(VOICES_DIR)) return null;
    return (
      readdirSync(VOICES_DIR, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => loadProfileFromDirectory(entry.name))
        .filter((profile): profile is VoiceProfile => profile !== null)
        .find(
          (profile) =>
            normalizeProfileToken(
              profileIdentity(profile, profile.directory_name || ""),
            ) === normalizedIdentity,
        ) ?? null
    );
  } catch {
    return null;
  }
}

function getVoicesInventorySignature(): string {
  try {
    if (!existsSync(VOICES_DIR)) return "";
    return readdirSync(VOICES_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const profilePath = join(VOICES_DIR, entry.name, "profile.yaml");
        try {
          return `${entry.name}:${statSync(profilePath).mtimeMs}`;
        } catch {
          return `${entry.name}:missing`;
        }
      })
      .sort()
      .join("|");
  } catch {
    return "";
  }
}

function refreshProfileCachesIfInventoryChanged(): void {
  const signature = getVoicesInventorySignature();
  if (voicesInventorySignature === signature) return;
  voicesInventorySignature = signature;
  profileCache.clear();
  profileMissCache.clear();
}

export function loadProfile(voiceName: string): VoiceProfile | null {
  // Reject path traversal attempts (../, /, \)
  const name = normalizeProfileToken(voiceName);
  refreshProfileCachesIfInventoryChanged();
  const direct = loadProfileFromDirectory(name);

  const aliasProfile = profileMissCache.has(name)
    ? null
    : findLatestAcceptedProfileForAlias(name);
  if (aliasProfile) {
    profileCache.set(name, aliasProfile);
    return aliasProfile;
  }
  const identityProfile = profileMissCache.has(name)
    ? null
    : profileCache.get(name) || findProfileByIdentity(name);
  if (identityProfile) {
    profileCache.set(name, identityProfile);
    warnOnProfileDrift(identityProfile, voiceName);
    return identityProfile;
  }
  if (direct) {
    warnOnProfileDrift(direct, voiceName);
    return direct;
  }
  profileMissCache.add(name);
  return null;
}

/**
 * Check if a voice name has a cloned voice profile.
 */
export function hasClonedProfile(voiceName: string): boolean {
  return loadProfile(voiceName) !== null;
}

/**
 * List locally installed cloned voice profiles.
 */
export function listClonedVoiceProfiles(): string[] {
  try {
    if (!existsSync(VOICES_DIR)) return [];
    return readdirSync(VOICES_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .filter((name) => loadProfile(name) !== null)
      .sort((a, b) => a.localeCompare(b));
  } catch {
    return [];
  }
}

/**
 * Clear the profile cache (for testing).
 */
export function clearProfileCache(): void {
  profileCache.clear();
  profileMissCache.clear();
  voicesInventorySignature = null;
}

/**
 * Resolve the bearer token file shared with the Python Qwen3 daemon.
 * The daemon and TypeScript bridge both default to ~/.voicelayer/daemon.secret.
 */
export function getDaemonAuthTokenFilePath(): string {
  return (
    process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE ||
    process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE ||
    DEFAULT_DAEMON_AUTH_TOKEN_FILE
  );
}

/**
 * Read the daemon bearer token from a strict 0600 file.
 * Returns null when the token file is missing or insecure.
 */
export function loadDaemonAuthToken(): string | null {
  const tokenFile = getDaemonAuthTokenFilePath();

  if (!existsSync(tokenFile)) {
    console.error(`[voicelayer] TTS daemon auth token file not found: ${tokenFile}`);
    return null;
  }

  try {
    const stat = lstatSync(tokenFile);
    if (stat.isSymbolicLink()) {
      console.error(
        `[voicelayer] Refusing to read TTS daemon auth token symlink: ${tokenFile}`,
      );
      return null;
    }

    const mode = statSync(tokenFile).mode & 0o777;
    if (mode !== 0o600) {
      console.error(
        `[voicelayer] TTS daemon auth token file must be 0600: ${tokenFile}`,
      );
      return null;
    }

    const token = readFileSync(tokenFile, "utf-8").trim();
    if (!token) {
      console.error(
        `[voicelayer] TTS daemon auth token file is empty: ${tokenFile}`,
      );
      return null;
    }
    return token;
  } catch (err) {
    console.error(
      `[voicelayer] Failed to read TTS daemon auth token file "${tokenFile}": ${err}`,
    );
    return null;
  }
}

/**
 * Build headers for authenticated daemon requests.
 */
export function buildDaemonRequestHeaders(
  includeJsonContentType = false,
): Record<string, string> | null {
  const token = loadDaemonAuthToken();
  if (!token) return null;

  return {
    ...(includeJsonContentType ? { "Content-Type": "application/json" } : {}),
    Authorization: `Bearer ${token}`,
  };
}

// --- Daemon Communication ---

/**
 * Check if the TTS daemon is running and healthy.
 */
export async function isDaemonHealthy(): Promise<boolean> {
  try {
    const headers = buildDaemonRequestHeaders();
    if (!headers) return false;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);

    const res = await fetch(`${DAEMON_URL}/health`, {
      headers,
      signal: controller.signal,
    });
    clearTimeout(timeout);

    if (!res.ok) return false;
    const data = (await res.json()) as {
      status: string;
      model_loaded: boolean;
    };
    return data.status === "ok" && data.model_loaded === true;
  } catch {
    return false;
  }
}

/**
 * Synthesize speech using a cloned voice via the TTS daemon.
 *
 * Calls the daemon's /synthesize endpoint with the reference audio
 * from the voice profile. Returns the audio as a Buffer (MP3).
 *
 * @param text - Text to speak
 * @param voiceName - Voice profile name (e.g., "theo")
 * @returns MP3 audio buffer, or null if daemon unavailable
 */
export async function synthesizeCloned(
  text: string,
  voiceName: string,
): Promise<Buffer | null> {
  const profile = loadProfile(voiceName);
  if (!profile) {
    console.error(`[voicelayer] No voice profile found for "${voiceName}"`);
    return null;
  }

  // Select reference clip — use primary clip, or first from array
  const refClip = profile.reference_clip || profile.reference_clips[0]?.path;
  const refText = profile.reference_text || profile.reference_clips[0]?.text;

  if (!refClip || !refText) {
    console.error(
      `[voicelayer] Voice profile "${voiceName}" has no reference clips`,
    );
    return null;
  }

  // Expand ~ in paths
  const expandedPath = refClip.replace(/^~/, process.env.HOME || "~");

  try {
    const headers = buildDaemonRequestHeaders(true);
    if (!headers) return null;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), DAEMON_TIMEOUT_MS);

    const res = await fetch(`${DAEMON_URL}/synthesize`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        text,
        reference_wav: expandedPath,
        reference_text: refText,
        ...(profile.model ? { model: profile.model } : {}),
      }),
      signal: controller.signal,
    });
    clearTimeout(timeout);

    if (!res.ok) {
      const errText = await res.text().catch(() => "unknown error");
      console.error(
        `[voicelayer] Daemon synthesis failed (${res.status}): ${errText}`,
      );
      return null;
    }

    const data = (await res.json()) as {
      audio_b64: string;
      duration_ms: number;
    };
    console.error(
      `[voicelayer] Cloned voice synthesis: ${data.duration_ms.toFixed(0)}ms`,
    );
    return Buffer.from(data.audio_b64, "base64");
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      console.error("[voicelayer] Daemon synthesis timed out");
    } else {
      console.error(`[voicelayer] Daemon connection failed: ${err}`);
    }
    return null;
  }
}
