/**
 * whisper-server lifecycle manager.
 *
 * Manages a whisper-server sidecar process for streaming STT.
 * The server is started lazily on first use and kept alive for the session.
 *
 * AIDEV-NOTE: whisper-server is the HTTP server from whisper.cpp.
 * It's installed via `brew install whisper-cpp` (includes whisper-server binary).
 * We POST WAV audio chunks to /inference and get back JSON transcriptions.
 */

import { homedir } from "os";
import { join } from "path";
import { existsSync } from "fs";

/** Default port for the whisper-server sidecar. */
const DEFAULT_PORT = 8178;

/** Health check timeout in ms. */
const HEALTH_TIMEOUT = 2000;

/** Max time to wait for server startup in ms. */
const STARTUP_TIMEOUT = 30000;

/** Known whisper-server binary names. */
const SERVER_BINARY_NAMES = ["whisper-server"];

/** Model search (same order as stt.ts). */
const MODEL_SEARCH_PATHS = [
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo-q5_0.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.en.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.bin"),
];

interface WhisperServerState {
  proc: ReturnType<typeof Bun.spawn>;
  port: number;
  pid: number;
}

let serverState: WhisperServerState | null = null;

/** Find whisper-server binary. */
function findServerBinary(): string | null {
  for (const name of SERVER_BINARY_NAMES) {
    const result = Bun.spawnSync(["which", name]);
    if (result.exitCode === 0) {
      return result.stdout.toString().trim();
    }
  }
  return null;
}

/** Find a whisper model file. */
function findModel(): string | null {
  const envModel = process.env.QA_VOICE_WHISPER_MODEL;
  if (envModel && existsSync(envModel)) return envModel;

  for (const pathFn of MODEL_SEARCH_PATHS) {
    const p = pathFn();
    if (existsSync(p)) return p;
  }
  return null;
}

/** Check if the server is healthy. */
export async function isServerHealthy(
  port: number = DEFAULT_PORT,
): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HEALTH_TIMEOUT);
  try {
    const resp = await fetch(`http://127.0.0.1:${port}/health`, {
      signal: controller.signal,
    });
    if (!resp.ok) return false;
    const body = await resp.json();
    return body?.status === "ok";
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Ensure whisper-server is running. Starts it if needed.
 * Returns the port number.
 */
export async function ensureServer(): Promise<number> {
  const port =
    parseInt(process.env.QA_VOICE_WHISPER_SERVER_PORT || "", 10) ||
    DEFAULT_PORT;

  // Already running?
  if (serverState && serverState.port === port) {
    if (await isServerHealthy(port)) return port;
    // Server died — clean up and restart
    console.error("[voicelayer] whisper-server died, restarting...");
    serverState = null;
  }

  // Check if an external server is already running on the port
  if (await isServerHealthy(port)) {
    console.error(
      `[voicelayer] whisper-server already running on port ${port}`,
    );
    return port;
  }

  // Find binary and model
  const binary = findServerBinary();
  if (!binary) {
    throw new Error(
      "whisper-server not found. Install: brew install whisper-cpp",
    );
  }

  const model = findModel();
  if (!model) {
    throw new Error(
      "No whisper model found. Download:\n" +
        "  curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \\\n" +
        "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
    );
  }

  // Get brew prefix for Metal shaders
  let metalPath: string | undefined;
  const brewResult = Bun.spawnSync(["brew", "--prefix", "whisper-cpp"]);
  if (brewResult.exitCode === 0) {
    metalPath = join(
      brewResult.stdout.toString().trim(),
      "share",
      "whisper-cpp",
    );
  }

  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (typeof v === "string") env[k] = v;
  }
  if (metalPath) {
    env.GGML_METAL_PATH_RESOURCES = metalPath;
  }

  console.error(
    `[voicelayer] Starting whisper-server on port ${port} with model ${model}`,
  );

  const proc = Bun.spawn(
    [
      binary,
      "-m",
      model,
      "--port",
      String(port),
      "--host",
      "127.0.0.1",
      "-t",
      "4",
      "-nt", // no timestamps
      "--convert", // auto-convert audio formats
    ],
    {
      stdout: "pipe",
      stderr: "pipe",
      env,
    },
  );

  // Drain stderr in background (server logs)
  if (proc.stderr) {
    const reader = (proc.stderr as ReadableStream<Uint8Array>).getReader();
    (async () => {
      try {
        while (true) {
          const { done } = await reader.read();
          if (done) break;
        }
      } catch {}
    })();
  }

  // Wait for server to become healthy
  const deadline = Date.now() + STARTUP_TIMEOUT;
  while (Date.now() < deadline) {
    if (await isServerHealthy(port)) {
      serverState = { proc, port, pid: proc.pid };
      console.error(
        `[voicelayer] whisper-server ready (PID ${proc.pid}, port ${port})`,
      );
      return port;
    }
    await Bun.sleep(500);
  }

  // Timeout — kill and throw
  proc.kill();
  throw new Error(
    `whisper-server failed to start within ${STARTUP_TIMEOUT / 1000}s`,
  );
}

/** Stop the whisper-server sidecar. */
export function stopServer(): void {
  if (serverState) {
    console.error(
      `[voicelayer] Stopping whisper-server (PID ${serverState.pid})`,
    );
    try {
      serverState.proc.kill();
    } catch {}
    serverState = null;
  }
}

/**
 * Transcribe a WAV audio buffer via whisper-server HTTP API.
 *
 * @param wavData - Complete WAV file as Uint8Array (with header)
 * @returns Transcription text (may be empty for silence)
 */
/** Inference timeout: 8s per request (generous for 3s audio windows). */
const INFERENCE_TIMEOUT = 8000;

export async function transcribeViaServer(
  wavData: Uint8Array,
  port?: number,
): Promise<string> {
  const serverPort = port ?? (await ensureServer());

  const formData = new FormData();
  formData.append(
    "file",
    new Blob([wavData], { type: "audio/wav" }),
    "audio.wav",
  );
  formData.append("response_format", "json");
  formData.append("temperature", "0.0");

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), INFERENCE_TIMEOUT);
  try {
    const resp = await fetch(`http://127.0.0.1:${serverPort}/inference`, {
      method: "POST",
      body: formData,
      signal: controller.signal,
    });

    if (!resp.ok) {
      throw new Error(
        `whisper-server inference failed: ${resp.status} ${resp.statusText}`,
      );
    }

    const result = (await resp.json()) as { text?: string };
    return (result.text || "").trim();
  } finally {
    clearTimeout(timer);
  }
}

/** Check if whisper-server binary is available (for feature detection). */
export function isServerAvailable(): boolean {
  return findServerBinary() !== null && findModel() !== null;
}

// Clean up on process exit
process.on("exit", stopServer);
process.on("SIGTERM", () => {
  stopServer();
  process.exit(0);
});
process.on("SIGINT", () => {
  stopServer();
  process.exit(0);
});
