import { existsSync, mkdirSync, writeFileSync } from "fs";
import { basename, join } from "path";
import { WhisperServerBackend } from "../src/stt";
import { transcribeViaServer } from "../src/whisper-server";
import {
  buildWhisperServerArgs,
  scoreTranscript,
} from "../src/stt-decode-benchmark";

interface CliOptions {
  audio: string;
  outputDir: string;
  expected: string[];
  port: number;
}

interface AbResult {
  id: "bare-server-full-wav" | "backend-pipeline";
  audio: string;
  latencyMs: number;
  text: string;
  backend?: string;
  score: ReturnType<typeof scoreTranscript>;
}

interface AbReport {
  createdAt: string;
  audio: string;
  results: AbResult[];
}

const DEFAULT_INCIDENT_AUDIO =
  "/Users/etanheyman/.local/share/voicelayer/recordings/2026-06-06/2026-06-06T20-05-08-789Z-009828e5/audio.wav";
const DEFAULT_PORT = 18893;

function parseArgs(argv: string[]): CliOptions {
  let expectedOverridden = false;
  const options: CliOptions = {
    audio: DEFAULT_INCIDENT_AUDIO,
    outputDir: ".verified/stt-long-dictation",
    port: DEFAULT_PORT,
    expected: [
      "I don't want to leave anything for Anthropic",
      "Codex",
      "CLAUDE.md",
    ],
  };

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--audio") {
      options.audio = requiredValue(argv, ++index, arg);
    } else if (arg === "--output-dir") {
      options.outputDir = requiredValue(argv, ++index, arg);
    } else if (arg === "--port") {
      options.port = Number(requiredValue(argv, ++index, arg));
    } else if (arg === "--expected") {
      const expected = requiredValue(argv, ++index, arg);
      if (expectedOverridden) {
        options.expected.push(expected);
      } else {
        options.expected = [expected];
        expectedOverridden = true;
      }
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

function requiredValue(argv: string[], index: number, flag: string): string {
  const value = argv[index];
  if (!value) throw new Error(`${flag} requires a value`);
  return value;
}

function printUsage(): void {
  console.log(`Usage: bun run scripts/stt-long-dictation-ab.ts [options]

Options:
  --audio PATH       Long WAV to test. Defaults to the preserved 2026-06-06 incident.
  --output-dir DIR   Local receipt directory. Default: .verified/stt-long-dictation.
  --port PORT        Temporary whisper-server port. Default: ${DEFAULT_PORT}.
  --expected TEXT    Expected phrase to score. Repeatable.

Compares bare transcribeViaServer(fullWav) with WhisperServerBackend.transcribe(),
which adds VoiceLayer's long-recording verification and cleanup pipeline.`);
}

function resolveBinary(name: string, candidates: string[]): string {
  const which = Bun.spawnSync(["which", name]);
  if (which.exitCode === 0) {
    const path = which.stdout.toString().trim();
    if (path) return path;
  }

  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }

  throw new Error(`${name} not found`);
}

function resolveModel(): string {
  const envModel = process.env.QA_VOICE_WHISPER_MODEL;
  if (envModel && existsSync(envModel)) return envModel;

  const home = process.env.HOME || "/Users/etanheyman";
  const candidates = [
    join(home, ".cache/whisper/ggml-large-v3-turbo.bin"),
    join(home, ".cache/whisper/ggml-large-v3-turbo-q5_0.bin"),
    join(home, ".cache/whisper/ggml-base.en.bin"),
    join(home, ".cache/whisper/ggml-base.bin"),
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }

  throw new Error("No whisper model found");
}

function resolveOptionalBinary(name: string, candidates: string[]): string | null {
  try {
    return resolveBinary(name, candidates);
  } catch {
    return null;
  }
}

function buildWhisperEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (typeof value === "string") env[key] = value;
  }

  const brew = resolveOptionalBinary("brew", [
    "/opt/homebrew/bin/brew",
    "/usr/local/bin/brew",
  ]);
  if (!brew) return env;

  const result = Bun.spawnSync([brew, "--prefix", "whisper-cpp"]);
  if (result.exitCode === 0) {
    env.GGML_METAL_PATH_RESOURCES = join(
      result.stdout.toString().trim(),
      "share/whisper-cpp",
    );
  }
  return env;
}

async function readStream(stream: ReadableStream<Uint8Array> | null): Promise<string> {
  if (!stream) return "";
  const chunks: Uint8Array[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function waitForHealthy(port: number, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {}
    await Bun.sleep(500);
  }
  throw new Error(`whisper-server on port ${port} did not become healthy`);
}

async function time<T>(
  fn: () => Promise<T>,
): Promise<{ value: T; latencyMs: number }> {
  const start = performance.now();
  const value = await fn();
  return { value, latencyMs: performance.now() - start };
}

async function runBareServer(
  audio: string,
  expected: string[],
  port: number,
): Promise<AbResult> {
  const wavData = new Uint8Array(await Bun.file(audio).arrayBuffer());
  const { value: text, latencyMs } = await time(() =>
    transcribeViaServer(wavData, port),
  );
  return {
    id: "bare-server-full-wav",
    audio,
    latencyMs,
    text,
    score: scoreTranscript(text, expected),
  };
}

async function runBackendPipeline(
  audio: string,
  expected: string[],
  port: number,
): Promise<AbResult> {
  const backend = new WhisperServerBackend({
    transcribeViaServer: (wavData, options) =>
      transcribeViaServer(wavData, port, options),
  });
  const { value: result, latencyMs } = await time(() => backend.transcribe(audio));
  return {
    id: "backend-pipeline",
    audio,
    latencyMs,
    text: result.text,
    backend: result.backend,
    score: scoreTranscript(result.text, expected),
  };
}

async function withTempWhisperServer<T>(
  port: number,
  fn: () => Promise<T>,
): Promise<T> {
  const binary = resolveBinary("whisper-server", [
    "/opt/homebrew/bin/whisper-server",
    "/usr/local/bin/whisper-server",
  ]);
  const model = resolveModel();
  const proc = Bun.spawn(
    buildWhisperServerArgs({
      binary,
      model,
      port,
      decodeArgs: ["-bo", "5", "-bs", "5"],
    }),
    {
      stdout: "pipe",
      stderr: "pipe",
      env: buildWhisperEnv(),
    },
  );

  try {
    await waitForHealthy(port);
    return await fn();
  } finally {
    proc.kill();
    const exited = await Promise.race([
      proc.exited.then(() => true),
      Bun.sleep(5000).then(() => false),
    ]);
    if (!exited) {
      proc.kill("SIGKILL");
      await Promise.race([proc.exited, Bun.sleep(5000)]);
    }
    await Promise.all([
      readStream(proc.stdout).catch(() => ""),
      readStream(proc.stderr).catch(() => ""),
    ]);
  }
}

function summarizeResult(result: AbResult): string {
  const repeatedTail = result.score.repeatedTail.repeated
    ? `${result.score.repeatedTail.count}x ${result.score.repeatedTail.phrase}`
    : "none";
  const expectedHits = Object.entries(result.score.expectedPhraseHits)
    .map(([phrase, hit]) => `${hit ? "hit" : "miss"}:${phrase}`)
    .join(", ");
  return [
    result.id,
    `backend=${result.backend ?? "n/a"}`,
    `chars=${result.score.charCount}`,
    `words=${result.score.wordCount}`,
    `repeatedTail=${repeatedTail}`,
    `latencyMs=${Math.round(result.latencyMs)}`,
    `expected=${expectedHits || "n/a"}`,
  ].join(" | ");
}

async function main(): Promise<void> {
  const options = parseArgs(Bun.argv.slice(2));
  if (!existsSync(options.audio)) {
    throw new Error(`Audio not found: ${options.audio}`);
  }

  await withTempWhisperServer(options.port, async () => {
    const results = [
      await runBareServer(options.audio, options.expected, options.port),
      await runBackendPipeline(options.audio, options.expected, options.port),
    ];
    const report: AbReport = {
      createdAt: new Date().toISOString(),
      audio: options.audio,
      results,
    };

    mkdirSync(options.outputDir, { recursive: true });
    const stamp = report.createdAt.replace(/[:.]/g, "-");
    const outputPath = join(
      options.outputDir,
      `stt-long-dictation-ab-${basename(options.audio, ".wav")}-${stamp}.json`,
    );
    writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`, {
      mode: 0o600,
    });

    for (const result of results) console.log(summarizeResult(result));
    console.log(`Wrote ${outputPath}`);
  });
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? (error.stack ?? error.message) : error);
    process.exit(1);
  });
}
