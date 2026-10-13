#!/usr/bin/env bun
import { readFileSync } from "node:fs";
import { createConnection } from "node:net";
import { spawn } from "node:child_process";
import { getMcpSocketPath } from "../paths";
import { speechSecretPath } from "../speech-control";

export type SpeechRequest = { cmd: "stop" } | {
  cmd: "speak_text"; text: string; profile: "auto" | "short" | "long";
  format: "plain" | "markdown"; wait: boolean;
};
interface IO {
  readStdin(): Promise<string>; readFile(path: string): Promise<string>;
  stderr(message: string): void; stdout(message: string): void;
}
const HELP = `Usage: voicelayer speak [text | - | --file path] [options]
  --profile auto|short|long  Profile selection (default: auto)
  --markdown                Convert markdown to speech
  --wait                    Wait until playback finishes
  --stop                    Stop daemon speech, including queued chunks
  -                         Read stdin (also the default with no text)
Markdown defaults on for .md files; stdin and literal text default to plain.
Returns after first audio starts; falls back locally if the daemon is down.
`;
export async function parseSpeakArgs(args: string[], io: IO): Promise<SpeechRequest> {
  let profile: "auto" | "short" | "long" = "auto";
  let markdown = false, wait = false, stop = false;
  let file: string | undefined, input: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--profile") {
      const value = args[++i];
      if (value !== "auto" && value !== "short" && value !== "long") throw new Error("--profile requires auto, short or long");
      profile = value;
    } else if (arg === "--file") {
      if (file !== undefined || !args[i + 1] || args[i + 1].startsWith("--")) throw new Error("--file requires one path");
      file = args[++i];
    } else if (arg === "--markdown") markdown = true;
    else if (arg === "--wait") wait = true;
    else if (arg === "--stop") stop = true;
    else if (arg.startsWith("-") && arg !== "-") throw new Error(`Unknown option: ${arg}`);
    else { if (input !== undefined) throw new Error("Provide one text argument"); input = arg; }
  }
  if (stop) {
    if (args.length !== 1) throw new Error("--stop cannot be combined with speech options");
    return { cmd: "stop" };
  }
  if (file !== undefined && input !== undefined) throw new Error("Choose text, stdin or --file");
  const text = file !== undefined ? await io.readFile(file) : input === undefined || input === "-" ? await io.readStdin() : input;
  if (!text.trim()) throw new Error("No text provided");
  if (text.length > 200_000) throw new Error("Speech exceeds the 200,000-character safety limit");
  return { cmd: "speak_text", text, profile, format: markdown || (file !== undefined && /\.md$/i.test(file)) ? "markdown" : "plain", wait };
}

/** Only connect failures authorize fallback: never replay an ambiguously delivered request. */
export function requestSpeech(request: SpeechRequest, options: { socketPath?: string; token?: string } = {}): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(options.socketPath ?? getMcpSocketPath());
    socket.setEncoding("utf8");
    let connected = false, settled = false, buffer = "";
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true; clearTimeout(timer); socket.destroy();
      if (error) reject(error); else resolve();
    };
    // --wait is intentionally unbounded once connected: a long read can take hours.
    const timer = setTimeout(() => finish(new Error("Daemon speech request timed out; delivery may have occurred")), 90_000);
    socket.on("connect", () => {
      connected = true;
      if (request.cmd === "speak_text" && request.wait) clearTimeout(timer);
      try {
        const token = options.token ?? readFileSync(speechSecretPath(), "utf8").trim();
        socket.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "voicelayer/speech", params: {
          ...request, ...(request.cmd === "speak_text" ? { source: "cli" } : {}), token,
        } }) + "\n");
      } catch { finish(new Error("Cannot read daemon speech secret; update/restart VoiceLayer")); }
    });
    socket.on("data", (data) => {
      buffer += data.toString("utf8");
      if (buffer.length > 1024 * 1024) { finish(new Error("Oversized daemon response")); return; }
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        try {
          const response = JSON.parse(line);
          if (response.id !== 1) continue;
          if (response.error) finish(new Error(String(response.error.message)));
          else if (response.result?.status && ["started", "completed", "accept", "noop"].includes(response.result.status)) finish();
          else finish(new Error("Invalid daemon speech response"));
        } catch { finish(new Error("Invalid daemon JSON response")); }
      }
    });
    socket.on("error", (error) => finish(connected ? new Error(`Daemon disconnected: ${error.message}; delivery may have occurred`) : error));
    socket.on("close", () => finish(new Error("Daemon closed before acknowledging speech; delivery may have occurred")));
  });
}

async function localWorker(request: Extract<SpeechRequest, { cmd: "speak_text" }>): Promise<void> {
  const { speakText } = await import("../tts");
  const { markdownToSpeech } = await import("../tts/markdown-to-speech");
  const read = speakText(request.format === "markdown" ? markdownToSpeech(request.text) : request.text, request.profile);
  const start = await read.started;
  if (start.error) throw new Error(start.error);
  process.stdout.write(JSON.stringify({ status: "started" }) + "\n");
  const completion = await read.completion;
  if (completion.error) throw new Error(completion.error);
}

function speakLocally(request: Extract<SpeechRequest, { cmd: "speak_text" }>): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [new URL("./speak.ts", import.meta.url).pathname, "--local-worker"], {
      detached: !request.wait, stdio: ["pipe", "pipe", "inherit"], env: process.env,
    });
    let started = false, settled = false, output = "";
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(request));
    child.stdout.on("data", (data) => {
      output += data.toString();
      if (!output.includes('{"status":"started"}')) return;
      started = true;
      if (!request.wait && !settled) {
        settled = true; child.stdout.destroy(); child.unref(); resolve();
      }
    });
    child.on("error", (error) => { if (!settled) { settled = true; reject(error); } });
    child.on("exit", (code) => {
      if (settled) return;
      settled = true;
      if (code === 0 && started) resolve(); else reject(new Error(`Local speech failed (exit ${code ?? "signal"})`));
    });
  });
}
export async function runSpeakCli(args: string[], deps: IO & {
  request(request: SpeechRequest): Promise<void>;
  local(request: Extract<SpeechRequest, { cmd: "speak_text" }>): Promise<void>;
}): Promise<number> {
  try {
    if (args.length === 1 && ["--help", "-h"].includes(args[0])) { deps.stdout(HELP); return 0; }
    const request = await parseSpeakArgs(args, deps);
    try { await deps.request(request); }
    catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (request.cmd === "stop" || (code !== "ENOENT" && code !== "ECONNREFUSED")) throw error;
      deps.stderr("VoiceLayer daemon unavailable; speaking locally (no daemon stop/teleprompter).\n");
      await deps.local(request);
    }
    return 0;
  } catch (error) {
    deps.stderr(`voicelayer speak: ${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}
if (import.meta.main) {
  if (process.argv[2] === "--local-worker") {
    try { await localWorker(JSON.parse(await Bun.stdin.text())); process.exit(0); }
    catch (error) { console.error(`Local speech: ${error instanceof Error ? error.message : String(error)}`); process.exit(1); }
  }
  const code = await runSpeakCli(process.argv.slice(2), {
    readStdin: async () => { if (process.stdin.isTTY) throw new Error("Provide text, --file or piped stdin"); return await Bun.stdin.text(); },
    readFile: async (path) => await Bun.file(path).text(),
    stderr: message => { process.stderr.write(message); }, stdout: message => { process.stdout.write(message); },
    request: requestSpeech, local: speakLocally,
  });
  process.exit(code);
}
