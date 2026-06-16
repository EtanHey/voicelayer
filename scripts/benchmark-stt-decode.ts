import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "fs";
import { basename, dirname, join } from "path";
import {
  DEFAULT_DECODE_BENCHMARK_PLANS,
  type DecodeBenchmarkPlan,
  type DecodeBenchmarkReport,
  type DecodeBenchmarkResult,
  buildWhisperCliArgs,
  buildWhisperServerArgs,
  compareTranscriptToReference,
  formatBenchmarkMarkdown,
  scoreTranscript,
} from "../src/stt-decode-benchmark";

interface CliOptions {
  audio: string[];
  language: string;
  plans: string[];
  portBase: number;
  outputDir: string;
  expected: string[];
}

const KNOWN_REGRESSION_AUDIO =
  "/Users/etanheyman/.local/share/voicelayer/recordings/2026-05-17/2026-05-17T06-44-55-073Z-91104263/audio.wav";

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = {
    audio: [],
    language: "auto",
    plans: DEFAULT_DECODE_BENCHMARK_PLANS.map((plan) => plan.id),
    portBase: 18892,
    outputDir: "docs.local/research",
    expected: [
      "master audio overview",
      "large plan",
      "I don't know",
      "/tmp/VoiceLayer.socket",
    ],
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--audio") {
      options.audio.push(requiredValue(argv, ++i, arg));
    } else if (arg === "--language") {
      options.language = requiredValue(argv, ++i, arg);
    } else if (arg === "--plans") {
      options.plans = requiredValue(argv, ++i, arg)
        .split(",")
        .map((plan) => plan.trim())
        .filter(Boolean);
    } else if (arg === "--port-base") {
      options.portBase = Number(requiredValue(argv, ++i, arg));
    } else if (arg === "--output-dir") {
      options.outputDir = requiredValue(argv, ++i, arg);
    } else if (arg === "--expected") {
      options.expected.push(requiredValue(argv, ++i, arg));
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (options.audio.length === 0) {
    options.audio = findDefaultAudio();
  }

  return options;
}

function requiredValue(argv: string[], index: number, flag: string): string {
  const value = argv[index];
  if (!value) throw new Error(`${flag} requires a value`);
  return value;
}

function printUsage(): void {
  console.log(`Usage: bun run scripts/benchmark-stt-decode.ts [options]

Options:
  --audio PATH       WAV file to benchmark. Repeatable. Defaults to the known
                     91s regression audio plus recent VoiceLayer archives.
  --language LANG    Whisper language argument. Default: auto.
  --plans IDS        Comma-separated plan ids. Default: all.
  --port-base PORT   First temporary whisper-server port. Default: 18892.
  --output-dir DIR   Local report output directory. Default: docs.local/research.
  --expected TEXT    Expected phrase to score. Repeatable.

This script is local-only. It does not touch production Wispr data and does not
reuse VoiceBar's resident port 8178.`);
}

function findDefaultAudio(): string[] {
  const audio = new Set<string>();
  if (existsSync(KNOWN_REGRESSION_AUDIO)) audio.add(KNOWN_REGRESSION_AUDIO);

  const root = "/Users/etanheyman/.local/share/voicelayer/recordings";
  if (!existsSync(root)) return [...audio];

  const candidates: Array<{ path: string; mtimeMs: number }> = [];
  for (const dateDir of readdirSync(root)) {
    const fullDateDir = join(root, dateDir);
    if (!statSync(fullDateDir).isDirectory()) continue;
    for (const recordingDir of readdirSync(fullDateDir)) {
      const wav = join(fullDateDir, recordingDir, "audio.wav");
      if (!existsSync(wav)) continue;
      const stat = statSync(wav);
      candidates.push({ path: wav, mtimeMs: stat.mtimeMs });
    }
  }

  candidates
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .slice(0, 3)
    .forEach((candidate) => audio.add(candidate.path));

  return [...audio];
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

function resolveOptionalBinary(name: string, candidates: string[]): string | null {
  try {
    return resolveBinary(name, candidates);
  } catch {
    return null;
  }
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

async function transcribeViaTempServer(
  options: {
    plan: DecodeBenchmarkPlan;
    audio: string;
    model: string;
    binary: string;
    port: number;
    language: string;
    env: Record<string, string>;
  },
): Promise<string> {
  const args = buildWhisperServerArgs({
    binary: options.binary,
    model: options.model,
    port: options.port,
    decodeArgs: options.plan.decodeArgs,
  });

  const proc = Bun.spawn(args, {
    stdout: "pipe",
    stderr: "pipe",
    env: options.env,
  });

  try {
    await waitForHealthy(options.port);
    const form = new FormData();
    form.append("file", Bun.file(options.audio), basename(options.audio));
    form.append("response_format", "json");
    form.append("temperature", "0.0");
    form.append("language", options.language);

    const response = await fetch(`http://127.0.0.1:${options.port}/inference`, {
      method: "POST",
      body: form,
    });
    if (!response.ok) {
      throw new Error(
        `inference failed: ${response.status} ${response.statusText}`,
      );
    }
    const payload = (await response.json()) as { text?: string; error?: string };
    if (payload.error) throw new Error(payload.error);
    return (payload.text || "").trim();
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
    const stdout = readStream(proc.stdout).catch(() => "");
    const stderr = readStream(proc.stderr).catch(() => "");
    await Promise.all([stdout, stderr]);
  }
}

async function transcribeViaCli(options: {
  audio: string;
  model: string;
  binary: string;
  language: string;
  env: Record<string, string>;
}): Promise<string> {
  const args = buildWhisperCliArgs({
    binary: options.binary,
    model: options.model,
    audio: options.audio,
    language: options.language,
  });
  const proc = Bun.spawn(args, {
    stdout: "pipe",
    stderr: "pipe",
    env: options.env,
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    readStream(proc.stdout),
    readStream(proc.stderr),
    proc.exited,
  ]);
  if (exitCode !== 0) {
    throw new Error(`whisper-cli failed (${exitCode}): ${stderr.slice(0, 500)}`);
  }
  return stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ")
    .trim();
}

async function runPlan(
  plan: DecodeBenchmarkPlan,
  audio: string,
  context: {
    model: string;
    cliBinary: string;
    serverBinary: string;
    port: number;
    language: string;
    env: Record<string, string>;
    expected: string[];
    referenceText?: string;
  },
): Promise<DecodeBenchmarkResult> {
  const start = performance.now();
  try {
    const text =
      plan.kind === "cli"
        ? await transcribeViaCli({
            audio,
            model: context.model,
            binary: context.cliBinary,
            language: context.language,
            env: context.env,
          })
        : await transcribeViaTempServer({
            plan,
            audio,
            model: context.model,
            binary: context.serverBinary,
            port: context.port,
            language: context.language,
            env: context.env,
          });
    const latencyMs = performance.now() - start;
    return {
      planId: plan.id,
      audio,
      latencyMs,
      text,
      score: scoreTranscript(text, context.expected),
      reference: context.referenceText
        ? compareTranscriptToReference(text, context.referenceText)
        : undefined,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      planId: plan.id,
      audio,
      latencyMs: performance.now() - start,
      text: "",
      score: scoreTranscript("", context.expected),
      reference: context.referenceText
        ? compareTranscriptToReference("", context.referenceText)
        : undefined,
      error: message,
    };
  }
}

function readArchiveBaseline(audio: string): string | undefined {
  const transcriptPath = join(dirname(audio), "voicelayer-transcript.txt");
  if (!existsSync(transcriptPath)) return undefined;
  const transcript = readFileSync(transcriptPath, "utf8").trim();
  return transcript || undefined;
}

async function main(): Promise<void> {
  const options = parseArgs(Bun.argv.slice(2));
  if (options.audio.length === 0) {
    throw new Error("No audio files found. Pass --audio /path/to/audio.wav.");
  }

  for (const audio of options.audio) {
    if (!existsSync(audio)) throw new Error(`Audio not found: ${audio}`);
  }

  const plans = DEFAULT_DECODE_BENCHMARK_PLANS.filter((plan) =>
    options.plans.includes(plan.id),
  );
  if (plans.length === 0) {
    throw new Error(`No matching plans for: ${options.plans.join(", ")}`);
  }

  const model = resolveModel();
  const cliBinary = resolveBinary("whisper-cli", [
    "/opt/homebrew/bin/whisper-cli",
    "/usr/local/bin/whisper-cli",
  ]);
  const serverBinary = resolveBinary("whisper-server", [
    "/opt/homebrew/bin/whisper-server",
    "/usr/local/bin/whisper-server",
  ]);
  const env = buildWhisperEnv();
  const results: DecodeBenchmarkResult[] = [];

  for (const [audioIndex, audio] of options.audio.entries()) {
    for (const [planIndex, plan] of plans.entries()) {
      const port = options.portBase + audioIndex * plans.length + planIndex;
      const referenceText = readArchiveBaseline(audio);
      console.error(`[bench] ${plan.id} ${audio}`);
      results.push(
        await runPlan(plan, audio, {
          model,
          cliBinary,
          serverBinary,
          port,
          language: options.language,
          env,
          expected: options.expected,
          referenceText,
        }),
      );
    }
  }

  const report: DecodeBenchmarkReport = {
    createdAt: new Date().toISOString(),
    audio: options.audio,
    results,
  };

  mkdirSync(options.outputDir, { recursive: true });
  const stamp = report.createdAt.replace(/[:.]/g, "-");
  const jsonPath = join(options.outputDir, `stt-decode-benchmark-${stamp}.json`);
  const markdownPath = join(
    options.outputDir,
    `stt-decode-benchmark-${stamp}.md`,
  );
  writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`, {
    mode: 0o600,
  });
  writeFileSync(markdownPath, formatBenchmarkMarkdown(report), { mode: 0o600 });

  console.log(`Wrote ${jsonPath}`);
  console.log(`Wrote ${markdownPath}`);
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
