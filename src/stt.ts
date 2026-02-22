/**
 * STT backend abstraction — whisper.cpp (local) or Wispr Flow (cloud fallback).
 *
 * Auto-detects the best available backend:
 *   1. whisper.cpp binary + model file → local transcription (default on Apple Silicon)
 *   2. Wispr Flow WebSocket API → cloud fallback (requires QA_VOICE_WISPR_KEY)
 *
 * Environment variables:
 *   QA_VOICE_STT_BACKEND   — "whisper" | "wispr" | "auto" (default: "auto")
 *   QA_VOICE_WHISPER_MODEL — path to GGML model file (auto-detected if not set)
 *   QA_VOICE_WISPR_KEY     — Wispr Flow API key (required for wispr backend)
 */

import { existsSync, readdirSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { calculateRMS } from "./audio-utils";

// --- Types ---

export interface STTResult {
  text: string;
  backend: string;
  durationMs: number;
}

export interface STTBackend {
  name: string;
  isAvailable(): Promise<boolean>;
  transcribe(audioPath: string): Promise<STTResult>;
}

// --- WhisperCpp Backend ---

/** Default model search order (most preferred first) */
const MODEL_SEARCH_PATHS = [
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo-q5_0.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.en.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-small.en.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-small.bin"),
];

/** Known binary names in preference order (v1.8.3+ renamed to whisper-cli) */
const WHISPER_BINARY_NAMES = ["whisper-cli", "whisper-cpp"];

/** Find whisper-cpp binary path. Returns null if not found. */
function findWhisperBinary(): string | null {
  for (const name of WHISPER_BINARY_NAMES) {
    const result = Bun.spawnSync(["which", name]);
    if (result.exitCode === 0) {
      return result.stdout.toString().trim();
    }
  }
  return null;
}

/** Find a GGML model file. Returns null if none found. */
function findModel(): string | null {
  // 1. Explicit env var
  const envModel = process.env.QA_VOICE_WHISPER_MODEL;
  if (envModel) {
    if (existsSync(envModel)) return envModel;
    console.error(`[voicelayer] Warning: QA_VOICE_WHISPER_MODEL path does not exist: ${envModel}`);
  }

  // 2. Search standard paths
  for (const pathFn of MODEL_SEARCH_PATHS) {
    const p = pathFn();
    if (existsSync(p)) return p;
  }

  // 3. Scan ~/.cache/whisper/ for any ggml model
  const cacheDir = join(homedir(), ".cache", "whisper");
  if (existsSync(cacheDir)) {
    try {
      const files = readdirSync(cacheDir);
      const model = files.find((f: string) => f.startsWith("ggml-") && f.endsWith(".bin"));
      if (model) return join(cacheDir, model);
    } catch {
      // Ignore scan errors
    }
  }

  return null;
}

/** Get homebrew prefix for Metal shader resources (cached) */
let cachedBrewPrefix: string | null | undefined = undefined;
function getBrewPrefix(): string | null {
  if (cachedBrewPrefix !== undefined) return cachedBrewPrefix;
  const result = Bun.spawnSync(["brew", "--prefix", "whisper-cpp"]);
  cachedBrewPrefix = result.exitCode === 0 ? result.stdout.toString().trim() : null;
  return cachedBrewPrefix;
}

export class WhisperCppBackend implements STTBackend {
  name = "whisper.cpp";
  private binaryPath: string | null = null;
  private modelPath: string | null = null;

  async isAvailable(): Promise<boolean> {
    this.binaryPath = findWhisperBinary();
    this.modelPath = findModel();
    return this.binaryPath !== null && this.modelPath !== null;
  }

  async transcribe(audioPath: string): Promise<STTResult> {
    if (!this.binaryPath) this.binaryPath = findWhisperBinary();
    if (!this.modelPath) this.modelPath = findModel();

    if (!this.binaryPath) {
      throw new Error(
        "whisper-cpp binary not found (looked for: whisper-cli, whisper-cpp). Install:\n" +
        "  macOS: brew install whisper-cpp\n" +
        "  Linux: build from source — https://github.com/ggerganov/whisper.cpp"
      );
    }
    if (!this.modelPath) {
      throw new Error(
        "No whisper model found. Download one:\n" +
        "  mkdir -p ~/.cache/whisper\n" +
        "  curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \\\n" +
        "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
      );
    }

    const start = Date.now();

    // Build env with Metal shader path if available
    const env: Record<string, string> = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (typeof v === "string") env[k] = v;
    }
    const brewPrefix = getBrewPrefix();
    if (brewPrefix) {
      env.GGML_METAL_PATH_RESOURCES = join(brewPrefix, "share", "whisper-cpp");
    }

    const args = [
      this.binaryPath,
      "-m", this.modelPath,
      "-f", audioPath,
      "--no-timestamps",
      "-l", "en",
      "--no-prints",  // suppress progress output
    ];

    const proc = Bun.spawn(args, {
      stdout: "pipe",
      stderr: "pipe",
      env,
    });

    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    const exitCode = await proc.exited;

    if (exitCode !== 0) {
      throw new Error(
        `whisper-cpp failed (exit ${exitCode}): ${stderr.slice(0, 500)}`
      );
    }

    // whisper-cpp outputs transcription text, clean it up
    const text = stdout
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .join(" ")
      .trim();

    return {
      text,
      backend: this.name,
      durationMs: Date.now() - start,
    };
  }

  /** Get info about the detected model (for logging) */
  getModelInfo(): { binary: string | null; model: string | null } {
    return {
      binary: this.binaryPath ?? findWhisperBinary(),
      model: this.modelPath ?? findModel(),
    };
  }
}

// --- Wispr Flow Backend ---

export class WisprFlowBackend implements STTBackend {
  name = "wispr-flow";

  async isAvailable(): Promise<boolean> {
    return !!process.env.QA_VOICE_WISPR_KEY;
  }

  async transcribe(audioPath: string): Promise<STTResult> {
    const apiKey = process.env.QA_VOICE_WISPR_KEY;
    if (!apiKey) {
      throw new Error(
        "QA_VOICE_WISPR_KEY not set. Get your API key from Wispr Flow settings."
      );
    }

    const start = Date.now();
    const audioData = await Bun.file(audioPath).arrayBuffer();
    const audioBytes = new Uint8Array(audioData);

    // Send recorded audio to Wispr Flow WebSocket
    const wsUrl = `wss://platform-api.wisprflow.ai/api/v1/dash/ws?api_key=Bearer%20${apiKey}`;

    return new Promise<STTResult>((resolve, reject) => {
      const ws = new WebSocket(wsUrl);
      let resolved = false;

      const timer = setTimeout(() => {
        if (!resolved) {
          resolved = true;
          ws.close();
          reject(new Error("Wispr Flow transcription timeout (30s)"));
        }
      }, 30_000);

      ws.addEventListener("open", () => {
        ws.send(JSON.stringify({
          type: "auth",
          language: ["en"],
          context: { app: { name: "VoiceLayer", type: "ai" } },
        }));
      });

      ws.addEventListener("message", (event) => {
        if (resolved) return;
        try {
          const msg = JSON.parse(String(event.data));

          if (msg.status === "auth") {
            // Auth confirmed — send audio in 1-second chunks
            // Skip WAV header (44 bytes) to get raw PCM for chunking
            const CHUNK_SIZE = 32000; // 1 second of 16kHz 16-bit mono
            const pcmData = audioBytes.slice(44);
            let packetIndex = 0;
            for (let offset = 0; offset < pcmData.length; offset += CHUNK_SIZE) {
              const chunk = pcmData.slice(offset, offset + CHUNK_SIZE);
              const rms = calculateRMS(chunk);
              ws.send(JSON.stringify({
                type: "append",
                position: packetIndex++,
                audio_packets: {
                  packets: [Buffer.from(chunk).toString("base64")],
                  volumes: [rms],
                  packet_duration: 1,
                  audio_encoding: "wav",
                  byte_encoding: "base64",
                },
              }));
            }
            // Commit — signal end of audio
            ws.send(JSON.stringify({
              type: "commit",
              total_packets: packetIndex,
            }));
          }

          if (msg.status === "text" && msg.body?.text) {
            const text = msg.body.text.trim();
            if (text) {
              resolved = true;
              clearTimeout(timer);
              ws.close();
              resolve({
                text,
                backend: "wispr-flow",
                durationMs: Date.now() - start,
              });
            }
          } else if (msg.status === "error") {
            resolved = true;
            clearTimeout(timer);
            ws.close();
            reject(new Error(`Wispr API error: ${msg.error || JSON.stringify(msg)}`));
          }
        } catch {
          // Ignore non-JSON messages
        }
      });

      ws.addEventListener("error", () => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timer);
          reject(new Error("Wispr WebSocket connection failed. Check QA_VOICE_WISPR_KEY."));
        }
      });

      ws.addEventListener("close", () => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timer);
          reject(new Error("Wispr WebSocket closed before transcription completed"));
        }
      });
    });
  }
}

// --- Backend Detection ---

let cachedBackend: STTBackend | null = null;

/**
 * Detect and return the best available STT backend.
 * Result is cached for the lifetime of the process.
 */
export async function getBackend(): Promise<STTBackend> {
  if (cachedBackend) return cachedBackend;

  const preference = (process.env.QA_VOICE_STT_BACKEND || "auto").toLowerCase();

  if (preference === "whisper") {
    const backend = new WhisperCppBackend();
    if (await backend.isAvailable()) {
      cachedBackend = backend;
      return backend;
    }
    throw new Error(
      "whisper backend requested but not available. " +
      "Install whisper-cpp (macOS: brew install whisper-cpp) and download a model to ~/.cache/whisper/"
    );
  }

  if (preference === "wispr") {
    const backend = new WisprFlowBackend();
    if (await backend.isAvailable()) {
      cachedBackend = backend;
      return backend;
    }
    throw new Error(
      "wispr backend requested but QA_VOICE_WISPR_KEY not set."
    );
  }

  // Auto-detect: prefer whisper.cpp, fall back to Wispr Flow
  const whisper = new WhisperCppBackend();
  if (await whisper.isAvailable()) {
    cachedBackend = whisper;
    console.error(`[voicelayer] STT backend: whisper.cpp (${whisper.getModelInfo().model})`);
    return whisper;
  }

  const wispr = new WisprFlowBackend();
  if (await wispr.isAvailable()) {
    cachedBackend = wispr;
    console.error("[voicelayer] STT backend: Wispr Flow (cloud fallback)");
    return wispr;
  }

  throw new Error(
    "No STT backend available. Options:\n" +
    "  1. Install whisper.cpp:\n" +
    "     macOS: brew install whisper-cpp\n" +
    "     Linux: build from source — https://github.com/ggerganov/whisper.cpp\n" +
    "     Download model: curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \\\n" +
    "       https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin\n" +
    "  2. Set QA_VOICE_WISPR_KEY for cloud STT (Wispr Flow)"
  );
}

/**
 * Reset cached backend (for testing).
 */
export function resetBackendCache(): void {
  cachedBackend = null;
}
