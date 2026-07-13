#!/usr/bin/env bun

import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "path";

const LIVE_VOICEBAR_SOCKET = "/tmp/voicelayer.sock";
const LIVE_MCP_SOCKET = "/tmp/voicelayer-mcp.sock";
const MIN_SPECIMEN_DURATION_MS = 500;
const MIN_REFERENCE_WORDS = 3;
const MIN_REFERENCE_OVERLAP = 0.45;
const MIN_VOCABULARY_JACCARD = 0.25;
const DEFAULT_INTERACTION_TIMEOUT_MS = 300_000;

export interface CorpusSpecimen {
  id: string;
  directory: string;
  audioPath: string;
  metadataPath: string;
  transcriptPath: string;
  transcript: string;
  durationMs: number;
}

export function assertIsolatedVerifyPaths(input: {
  voiceBarSocketPath: string;
  mcpSocketPath: string;
  workDir: string;
}): void {
  const canonicalize = (path: string): string => {
    const absolutePath = resolve(path);
    if (existsSync(absolutePath)) {
      const stat = lstatSync(absolutePath);
      if (stat.isDirectory() || stat.isSymbolicLink()) {
        return realpathSync(absolutePath);
      }
      return join(realpathSync(dirname(absolutePath)), basename(absolutePath));
    }
    let existingAncestor = absolutePath;
    const missingParts: string[] = [];
    while (!existsSync(existingAncestor)) {
      const parent = dirname(existingAncestor);
      if (parent === existingAncestor) break;
      missingParts.unshift(basename(existingAncestor));
      existingAncestor = parent;
    }
    return join(realpathSync(existingAncestor), ...missingParts);
  };
  const rawVoiceBarSocketPath = input.voiceBarSocketPath.trim();
  const rawMcpSocketPath = input.mcpSocketPath.trim();
  if (!rawVoiceBarSocketPath) {
    throw new Error("corpus verifier refuses the live VoiceBar socket");
  }
  if (!rawMcpSocketPath) {
    throw new Error("corpus verifier refuses the live MCP socket");
  }
  const voiceBarSocketPath = canonicalize(rawVoiceBarSocketPath);
  const mcpSocketPath = canonicalize(rawMcpSocketPath);
  const workDir = canonicalize(input.workDir.trim());
  if (voiceBarSocketPath === canonicalize(LIVE_VOICEBAR_SOCKET)) {
    throw new Error("corpus verifier refuses the live VoiceBar socket");
  }
  if (mcpSocketPath === canonicalize(LIVE_MCP_SOCKET)) {
    throw new Error("corpus verifier refuses the live MCP socket");
  }
  if (voiceBarSocketPath === mcpSocketPath) {
    throw new Error("verify VoiceBar and MCP socket paths must be distinct");
  }
  for (const socketPath of [voiceBarSocketPath, mcpSocketPath]) {
    const pathFromWorkDir = relative(workDir, socketPath);
    const parentPrefix = `..${process.platform === "win32" ? "\\" : "/"}`;
    if (
      pathFromWorkDir === "" ||
      pathFromWorkDir === ".." ||
      pathFromWorkDir.startsWith(parentPrefix) ||
      isAbsolute(pathFromWorkDir)
    ) {
      throw new Error("verify sockets must be inside the verify work directory");
    }
  }
}

function normalizedWords(text: string): string[] {
  return text
    .normalize("NFKC")
    .toLocaleLowerCase()
    .match(/[\p{L}\p{N}_./+-]+/gu) ?? [];
}

function wordSimilarity(reference: string, actual: string): {
  referenceOverlap: number;
  jaccard: number;
} {
  const expected = new Set(normalizedWords(reference));
  const observed = new Set(normalizedWords(actual));
  if (expected.size === 0) return { referenceOverlap: 0, jaccard: 0 };
  let shared = 0;
  for (const word of expected) {
    if (observed.has(word)) shared++;
  }
  const unionSize = expected.size + observed.size - shared;
  return {
    referenceOverlap: shared / expected.size,
    jaccard: unionSize > 0 ? shared / unionSize : 0,
  };
}

function hasPunctuationFloor(text: string): boolean {
  return /[.!?…:;](?:["')\]]*)\s*$/u.test(text) || /^\s*\d+\.\s+\S+/mu.test(text);
}

export function assertCorpusReplayResult(input: {
  specimenId: string;
  reference: string;
  actual: string;
  polished: boolean;
  polishStatus: string;
  polishReason?: string;
}): void {
  if (input.polished !== true) {
    throw new Error(
      `${input.specimenId}: transcription did not report polished=true ` +
        `(status ${JSON.stringify(input.polishStatus || "missing")}, ` +
        `reason ${JSON.stringify(input.polishReason || "missing")})`,
    );
  }
  if (input.polishStatus !== "applied") {
    throw new Error(
      `${input.specimenId}: polish path did not complete ` +
        `(status ${JSON.stringify(input.polishStatus || "missing")})`,
    );
  }
  const actual = input.actual.trim();
  if (!actual) {
    throw new Error(`${input.specimenId}: empty polished output`);
  }
  if (/^1[.)]?$/u.test(actual) || /^1\.\s*$/u.test(actual)) {
    throw new Error(`${input.specimenId}: degenerate polished output ${JSON.stringify(actual)}`);
  }
  if (!hasPunctuationFloor(actual)) {
    throw new Error(`${input.specimenId}: punctuation floor was not applied`);
  }
  const similarity = wordSimilarity(input.reference, actual);
  if (similarity.referenceOverlap < MIN_REFERENCE_OVERLAP) {
    throw new Error(
      `${input.specimenId}: reference overlap ${similarity.referenceOverlap.toFixed(2)} is below ` +
        MIN_REFERENCE_OVERLAP.toFixed(2),
    );
  }
  if (similarity.jaccard < MIN_VOCABULARY_JACCARD) {
    throw new Error(
      `${input.specimenId}: vocabulary similarity ${similarity.jaccard.toFixed(2)} is below ` +
        MIN_VOCABULARY_JACCARD.toFixed(2),
    );
  }
}

function readSpecimen(directory: string): CorpusSpecimen | null {
  const audioPath = join(directory, "audio.wav");
  const metadataPath = join(directory, "metadata.json");
  const transcriptPath = join(directory, "voicelayer-transcript.txt");
  if (
    !existsSync(audioPath) ||
    !existsSync(metadataPath) ||
    !existsSync(transcriptPath)
  ) {
    return null;
  }
  try {
    const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
    const transcript = readFileSync(transcriptPath, "utf8").trim();
    const durationMs = Number(metadata.duration_ms);
    if (
      !transcript ||
      normalizedWords(transcript).length < MIN_REFERENCE_WORDS ||
      !Number.isFinite(durationMs) ||
      durationMs < MIN_SPECIMEN_DURATION_MS
    ) {
      return null;
    }
    return {
      id:
        typeof metadata.id === "string" && metadata.id.trim()
          ? metadata.id.trim()
          : basename(directory),
      directory,
      audioPath,
      metadataPath,
      transcriptPath,
      transcript,
      durationMs,
    };
  } catch {
    return null;
  }
}

export function selectCorpusSpecimens(
  root: string,
  count: number,
): CorpusSpecimen[] {
  if (!Number.isInteger(count) || count <= 0) {
    throw new Error(`corpus count must be a positive integer, got ${count}`);
  }
  if (!existsSync(root)) {
    throw new Error(`corpus root does not exist: ${root}`);
  }

  const specimens: CorpusSpecimen[] = [];
  for (const day of readdirSync(root, { withFileTypes: true })) {
    if (!day.isDirectory() || day.name.startsWith(".")) continue;
    const dayDirectory = join(root, day.name);
    for (const recording of readdirSync(dayDirectory, { withFileTypes: true })) {
      if (!recording.isDirectory() || recording.name.startsWith(".")) continue;
      const specimen = readSpecimen(join(dayDirectory, recording.name));
      if (specimen) specimens.push(specimen);
    }
  }

  specimens.sort((left, right) => right.directory.localeCompare(left.directory));
  const selected = specimens.slice(0, count);
  if (selected.length !== count) {
    throw new Error(
      `requested ${count} corpus specimens but found ${selected.length} usable recordings`,
    );
  }
  return selected;
}

interface VerifyBarServer {
  events: Record<string, unknown>[];
  send: (message: Record<string, unknown>) => void;
  stop: () => void;
}

interface VerifyDaemonProcess {
  exited: Promise<number>;
  kill: (signal: "SIGTERM" | "SIGKILL") => unknown;
}

interface DetachedProcessHandle {
  pid: number;
  kill: (signal: "SIGTERM" | "SIGKILL") => unknown;
}

export function signalDetachedProcessGroup(
  processHandle: DetachedProcessHandle,
  signal: "SIGTERM" | "SIGKILL",
  signalProcess: (pid: number, signal: "SIGTERM" | "SIGKILL") => unknown =
    process.kill,
): void {
  if (!Number.isInteger(processHandle.pid) || processHandle.pid <= 1) {
    processHandle.kill(signal);
    return;
  }
  try {
    signalProcess(-processHandle.pid, signal);
  } catch {
    processHandle.kill(signal);
  }
}

export async function terminateVerifyDaemon(
  daemon: VerifyDaemonProcess,
  waitForGracePeriod?: () => Promise<unknown>,
): Promise<void> {
  try {
    daemon.kill("SIGTERM");
  } catch {}
  let graceTimer: ReturnType<typeof setTimeout> | undefined;
  const gracePeriod = waitForGracePeriod
    ? waitForGracePeriod()
    : new Promise<void>((resolveGracePeriod) => {
        graceTimer = setTimeout(resolveGracePeriod, 10_000);
      });
  const exitedGracefully = await Promise.race([
    daemon.exited.then(() => true),
    gracePeriod.then(() => false),
  ]);
  if (graceTimer) clearTimeout(graceTimer);
  if (!exitedGracefully) {
    try {
      daemon.kill("SIGKILL");
    } catch {}
  }
  await daemon.exited;
}

function createVerifyBarServer(socketPath: string): VerifyBarServer {
  const events: Record<string, unknown>[] = [];
  const clients = new Set<{ write: (payload: string) => number }>();
  let stopped = false;
  try {
    unlinkSync(socketPath);
  } catch {}

  const server = Bun.listen<{ buffer: string }>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
        clients.add(socket);
      },
      data(socket, raw) {
        socket.data.buffer += raw.toString("utf8");
        const lines = socket.data.buffer.split("\n");
        socket.data.buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            events.push(JSON.parse(line));
          } catch {}
        }
      },
      close(socket) {
        clients.delete(socket);
      },
      error(socket) {
        clients.delete(socket);
      },
      drain() {},
    },
  });

  return {
    events,
    send(message) {
      if (clients.size === 0) {
        throw new Error(
          "verify daemon is not connected to the isolated VoiceBar socket",
        );
      }
      const payload = `${JSON.stringify(message)}\n`;
      for (const client of clients) client.write(payload);
    },
    stop() {
      if (stopped) return;
      stopped = true;
      server.stop(true);
      try {
        unlinkSync(socketPath);
      } catch {}
    },
  };
}

async function waitForEvent(
  events: Record<string, unknown>[],
  predicate: (event: Record<string, unknown>) => boolean,
  startIndex: number,
  timeoutMs: number,
  label: string,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let index = startIndex; index < events.length; index++) {
      if (predicate(events[index])) return events[index];
      if (events[index].type === "error") {
        throw new Error(
          `${label}: daemon error: ${String(events[index].message ?? "unknown")}`,
        );
      }
    }
    await Bun.sleep(50);
  }
  throw new Error(`${label}: timed out after ${timeoutMs}ms`);
}

export async function runDaemonInteractionLeg(
  bar: Pick<VerifyBarServer, "events" | "send">,
): Promise<void> {
  for (const terminalCommand of ["cancel", "stop"] as const) {
    const eventStart = bar.events.length;
    const recordId = `interaction-record-${terminalCommand}`;
    bar.send({
      cmd: "record",
      id: recordId,
      press_to_talk: true,
      timeout_seconds: 10,
    });
    await waitForEvent(
      bar.events,
      (event) =>
        event.type === "ack" &&
        event.id === recordId &&
        event.outcome === "accept",
      eventStart,
      10_000,
      `${terminalCommand} interaction record acceptance`,
    );
    await waitForEvent(
      bar.events,
      (event) => event.type === "state" && event.state === "recording",
      eventStart,
      10_000,
      `${terminalCommand} interaction recording state`,
    );

    const terminalStart = bar.events.length;
    const terminalId = `interaction-${terminalCommand}`;
    bar.send({ cmd: terminalCommand, id: terminalId });
    await waitForEvent(
      bar.events,
      (event) =>
        event.type === "ack" &&
        event.id === terminalId &&
        event.outcome === "accept",
      terminalStart,
      10_000,
      `${terminalCommand} interaction acceptance`,
    );
    await waitForEvent(
      bar.events,
      (event) =>
        event.type === "state" &&
        event.state === "idle" &&
        event.source === "recording",
      terminalStart,
      10_000,
      `${terminalCommand} interaction idle transition`,
    );
  }
  console.log(
    "[corpus-replay] verified real-daemon record/cancel and record/stop transitions",
  );
}

function stageSpecimen(
  specimen: CorpusSpecimen,
  sourceRoot: string,
  stagedRoot: string,
): CorpusSpecimen {
  const relativeDirectory = relative(sourceRoot, specimen.directory);
  const directory = join(stagedRoot, relativeDirectory);
  mkdirSync(directory, { recursive: true });
  for (const name of ["audio.wav", "metadata.json", "voicelayer-transcript.txt"]) {
    copyFileSync(join(specimen.directory, name), join(directory, name));
  }
  return { ...specimen, directory, audioPath: join(directory, "audio.wav") };
}

function createVerifyRecorderShim(workDir: string): string {
  const binDirectory = join(workDir, "bin");
  const recorderPath = join(binDirectory, "rec");
  mkdirSync(binDirectory, { recursive: true });
  writeFileSync(
    recorderPath,
    [
      "#!/bin/sh",
      'if [ "${1:-}" = "-n" ]; then exit 0; fi',
      ': "${VOICELAYER_VERIFY_AUDIO_FIXTURE:?missing corpus audio fixture}"',
      '/usr/bin/tail -c +45 "$VOICELAYER_VERIFY_AUDIO_FIXTURE"',
      "exec /bin/sleep 300",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  chmodSync(recorderPath, 0o755);
  return binDirectory;
}

export async function waitForInteractionRunner(
  runner: VerifyDaemonProcess,
  timeoutMs = DEFAULT_INTERACTION_TIMEOUT_MS,
): Promise<void> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const outcome = await Promise.race([
    runner.exited.then((exitCode) => ({ kind: "exit" as const, exitCode })),
    new Promise<{ kind: "timeout" }>((resolveTimeout) => {
      timeout = setTimeout(() => resolveTimeout({ kind: "timeout" }), timeoutMs);
    }),
  ]);
  if (timeout) clearTimeout(timeout);
  if (outcome.kind === "timeout") {
    await terminateVerifyDaemon(runner);
    throw new Error(`runtime interaction leg timed out after ${timeoutMs}ms`);
  }
  if (outcome.exitCode !== 0) {
    throw new Error(`runtime interaction leg exited with status ${outcome.exitCode}`);
  }
}

export async function runSwiftRuntimeInteractionLeg(options: {
  repoRoot: string;
  workDir: string;
  voiceBarSocketPath: string;
  audioFixture: string;
}): Promise<void> {
  const customRunner = process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER?.trim();
  const command = customRunner
    ? [customRunner]
    : [
        "swift",
        "test",
        "--package-path",
        join(options.repoRoot, "flow-bar"),
        "--filter",
        "CorpusReplayRuntimeInteractionTests/testF18EscapeAndStopButtonDriveSpawnedDaemonNDJSON",
      ];
  console.log(
    "[corpus-replay] running isolated F18/Escape/stop-button interaction leg",
  );
  const processHandle = Bun.spawn(command, {
    cwd: options.repoRoot,
    stdin: "ignore",
    stdout: "inherit",
    stderr: "inherit",
    env: {
      ...process.env,
      CORPUS_RUNNER_ACTIVE: "1",
      VOICELAYER_VERIFY_WORK_DIR: options.workDir,
      VOICELAYER_VERIFY_VOICEBAR_SOCKET_PATH: options.voiceBarSocketPath,
      VOICELAYER_VERIFY_AUDIO_FIXTURE: options.audioFixture,
    },
  });
  const configuredTimeout = Number(
    process.env.VOICELAYER_VERIFY_INTERACTION_TIMEOUT_MS ??
      DEFAULT_INTERACTION_TIMEOUT_MS,
  );
  const timeoutMs =
    Number.isFinite(configuredTimeout) && configuredTimeout > 0
      ? configuredTimeout
      : DEFAULT_INTERACTION_TIMEOUT_MS;
  await waitForInteractionRunner(processHandle, timeoutMs);
}

async function runCorpusReplay(options: {
  count: number;
  corpusRoot: string;
  workDir: string;
  repoRoot: string;
}): Promise<void> {
  const voiceBarSocketPath = process.env.VOICELAYER_SOCKET_PATH?.trim() ?? "";
  const mcpSocketPath = process.env.VOICELAYER_MCP_SOCKET_PATH?.trim() ?? "";
  assertIsolatedVerifyPaths({
    voiceBarSocketPath,
    mcpSocketPath,
    workDir: options.workDir,
  });

  mkdirSync(options.workDir, { recursive: true });
  const stagedRoot = join(options.workDir, "recordings");
  const selected = selectCorpusSpecimens(options.corpusRoot, options.count);
  const staged = selected.map((item) =>
    stageSpecimen(item, options.corpusRoot, stagedRoot),
  );
  const recorderBinDirectory = createVerifyRecorderShim(options.workDir);
  const bar = createVerifyBarServer(voiceBarSocketPath);
  const daemonLogPath = join(options.workDir, "daemon.log");
  const daemonProcess = Bun.spawn(
    ["bun", "run", join(options.repoRoot, "src", "mcp-server-daemon.ts")],
    {
      cwd: options.repoRoot,
      detached: true,
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        VOICELAYER_ALLOW_ORPHAN_DAEMON: "1",
        VOICELAYER_SOCKET_PATH: voiceBarSocketPath,
        VOICELAYER_MCP_SOCKET_PATH: mcpSocketPath,
        QA_VOICE_SOCKET_PATH: voiceBarSocketPath,
        QA_VOICE_MCP_SOCKET_PATH: mcpSocketPath,
        QA_VOICE_MCP_PID_PATH: join(options.workDir, "mcp.pid"),
        QA_VOICE_RECORDING_STATE_PATH: join(options.workDir, "recording-state.json"),
        QA_VOICE_RETAINED_RECORDING_PATH: join(options.workDir, "retained.wav"),
        QA_VOICE_RECORDINGS_DIR: stagedRoot,
        VOICELAYER_VERIFY_AUDIO_FIXTURE: staged[0].audioPath,
        PATH: `${recorderBinDirectory}:${process.env.PATH ?? "/usr/bin:/bin"}`,
      },
    },
  );
  const daemon: VerifyDaemonProcess = {
    exited: daemonProcess.exited,
    kill(signal) {
      signalDetachedProcessGroup(daemonProcess, signal);
    },
  };
  const daemonOutput = Promise.all([
    new Response(daemonProcess.stdout).text(),
    new Response(daemonProcess.stderr).text(),
  ]).then(([stdout, stderr]) => Bun.write(daemonLogPath, `${stdout}${stderr}`));

  try {
    await waitForEvent(
      bar.events,
      (event) => event.type === "client_hello" && event.accepts_commands === true,
      0,
      120_000,
      "isolated daemon startup",
    );

    for (let index = 0; index < staged.length; index++) {
      const specimen = staged[index];
      const eventStart = bar.events.length;
      const commandId = `corpus-${index + 1}`;
      bar.send({
        cmd: "retranscribe_recording",
        id: commandId,
        audio_path: specimen.audioPath,
      });
      await waitForEvent(
        bar.events,
        (event) =>
          event.type === "ack" &&
          event.id === commandId &&
          event.outcome === "accept",
        eventStart,
        10_000,
        `${specimen.id} command acceptance`,
      );
      const transcription = await waitForEvent(
        bar.events,
        (event) =>
          event.type === "transcription" &&
          event.recording_path === specimen.audioPath,
        eventStart,
        180_000,
        `${specimen.id} transcription`,
      );
      await waitForEvent(
        bar.events,
        (event) =>
          event.type === "state" &&
          event.state === "idle" &&
          event.source === "recording",
        eventStart,
        10_000,
        `${specimen.id} idle transition`,
      );
      assertCorpusReplayResult({
        specimenId: specimen.id,
        reference: selected[index].transcript,
        actual: typeof transcription.text === "string" ? transcription.text : "",
        polished: transcription.polished === true,
        polishStatus:
          typeof transcription.polish_status === "string"
            ? transcription.polish_status
            : "",
        polishReason:
          typeof transcription.polish_reason === "string"
            ? transcription.polish_reason
            : undefined,
      });
      console.log(
        `[corpus-replay] ${index + 1}/${staged.length} ` +
          `${specimen.id}: ${String(transcription.polish_status)}`,
      );
    }
    bar.stop();
    await runSwiftRuntimeInteractionLeg({
      repoRoot: options.repoRoot,
      workDir: options.workDir,
      voiceBarSocketPath,
      audioFixture: staged[0].audioPath,
    });
    console.log(
      `[corpus-replay] verified ${staged.length} corpus specimens and runtime interactions on isolated sockets`,
    );
  } finally {
    await terminateVerifyDaemon(daemon);
    bar.stop();
    try {
      unlinkSync(mcpSocketPath);
    } catch {}
    await daemonOutput;
  }
}

function parseCli(argv: string[]) {
  let count = 10;
  let corpusRoot = join(
    process.env.HOME ?? "",
    ".local",
    "share",
    "voicelayer",
    "recordings",
  );
  let workDir = "";
  let repoRoot = dirname(dirname(new URL(import.meta.url).pathname));
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    if (value === "--count") count = Number(argv[++index]);
    else if (value === "--corpus-root") corpusRoot = argv[++index] ?? "";
    else if (value === "--work-dir") workDir = argv[++index] ?? "";
    else if (value === "--repo-root") repoRoot = argv[++index] ?? "";
    else throw new Error(`unknown corpus replay argument: ${value}`);
  }
  if (!workDir) throw new Error("--work-dir is required");
  return { count, corpusRoot, workDir, repoRoot };
}

if (import.meta.main) {
  const options = parseCli(process.argv.slice(2));
  runCorpusReplay(options).catch((error) => {
    console.error(
      `[corpus-replay] ERROR: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exit(1);
  });
}
