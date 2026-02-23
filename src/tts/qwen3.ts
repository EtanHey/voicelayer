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

import { existsSync, readFileSync } from "fs";
import { join } from "path";

const DAEMON_URL = "http://127.0.0.1:8880";
const DAEMON_TIMEOUT_MS = 30_000; // 30s timeout for synthesis
const HEALTH_TIMEOUT_MS = 2_000; // 2s timeout for health check

// --- Voice Profile ---

export interface ReferenceClip {
  path: string;
  text: string;
}

export interface VoiceProfile {
  name: string;
  engine: string; // "qwen3-tts"
  model_path: string; // ~/.voicelayer/models/qwen3-tts-4bit
  reference_clips: ReferenceClip[]; // 3 clips, ~18.5s total
  reference_clip: string; // primary single-clip fallback
  reference_text?: string; // transcript of primary clip
  fallback: string; // edge-tts voice name for fallback
  created: string; // ISO date
  source?: string; // attribution URL
}

const VOICES_DIR = join(process.env.HOME || "~", ".voicelayer", "voices");

/** Cache for loaded voice profiles. */
const profileCache = new Map<string, VoiceProfile>();

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

  for (const line of lines) {
    // Skip comments and empty lines
    if (line.trim().startsWith("#") || line.trim() === "") continue;

    // Check for reference_clips array
    if (line.match(/^reference_clips:\s*$/)) {
      inReferenceClips = true;
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
      // Strip quotes and comments
      const value = rawValue
        .replace(/\s*#.*$/, "")
        .trim()
        .replace(/^["']|["']$/g, "");
      result[key] = value;
    }
  }

  // Flush last reference clip
  if (currentClip?.path && currentClip?.text) {
    referenceClips.push(currentClip as ReferenceClip);
  }

  return {
    name: String(result.name || ""),
    engine: String(result.engine || "qwen3-tts"),
    model_path: String(result.model_path || ""),
    reference_clips: referenceClips,
    reference_clip: String(result.reference_clip || ""),
    reference_text: result.reference_text
      ? String(result.reference_text)
      : undefined,
    fallback: String(result.fallback || "en-US-JennyNeural"),
    created: String(result.created || new Date().toISOString().split("T")[0]),
    source: result.source ? String(result.source) : undefined,
  };
}

/**
 * Load a voice profile from ~/.voicelayer/voices/{name}/profile.yaml.
 * Returns null if profile doesn't exist or is invalid.
 */
export function loadProfile(voiceName: string): VoiceProfile | null {
  const cached = profileCache.get(voiceName.toLowerCase());
  if (cached) return cached;

  const profilePath = join(VOICES_DIR, voiceName.toLowerCase(), "profile.yaml");
  if (!existsSync(profilePath)) return null;

  try {
    const content = readFileSync(profilePath, "utf-8");
    const profile = parseProfileYaml(content);
    profileCache.set(voiceName.toLowerCase(), profile);
    return profile;
  } catch (err) {
    console.error(
      `[voicelayer] Failed to load voice profile "${voiceName}": ${err}`,
    );
    return null;
  }
}

/**
 * Check if a voice name has a cloned voice profile.
 */
export function hasClonedProfile(voiceName: string): boolean {
  return loadProfile(voiceName) !== null;
}

/**
 * Clear the profile cache (for testing).
 */
export function clearProfileCache(): void {
  profileCache.clear();
}

// --- Daemon Communication ---

/**
 * Check if the TTS daemon is running and healthy.
 */
export async function isDaemonHealthy(): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);

    const res = await fetch(`${DAEMON_URL}/health`, {
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
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), DAEMON_TIMEOUT_MS);

    const res = await fetch(`${DAEMON_URL}/synthesize`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text,
        reference_wav: expandedPath,
        reference_text: refText,
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
