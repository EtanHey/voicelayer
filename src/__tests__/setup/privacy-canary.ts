import { createHash } from "crypto";
import { closeSync, constants, fstatSync, lstatSync, openSync, readFileSync, readdirSync } from "fs";
import { dirname, isAbsolute, join, normalize, parse, relative } from "path";
import { z } from "zod";

// Private archive/recovery artifacts are intentional content stores. A log
// alongside them is still a diagnostic and must be inspected before cleanup.
const privateArtifacts = new Set(["audio.wav", "fixture.wav", "last-recording.wav",
  "last-recording.wav.metadata.json", "metadata.json", "agent-audio.mp3",
  "agent-transcript.txt", "voicelayer-transcript.txt", "voicelayer-history.json"]);

const speakInputMetadata = z.object({
  schema_version: z.literal(1), source: z.literal("speak"), id: z.string(),
  created_at: z.string().datetime(),
  request_source: z.enum(["voice_speak", "selection", "clipboard", "cli", "preview", "ask_prompt", "direct"]),
  input: z.object({ bytes: z.number().int().nonnegative(), sha256: z.string().regex(/^[a-f0-9]{64}$/) }),
});
function statOrMissing(path: string) {
  try { return lstatSync(path); }
  catch (error) {
    if (typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT") return null;
    throw error;
  }
}
function readPrivateFile(path: string): Buffer | null {
  const before = statOrMissing(path);
  const privateFile = (s: NonNullable<typeof before>) => s.isFile() && !s.isSymbolicLink() &&
    s.uid === process.getuid?.() && (s.mode & 0o7777) === 0o600 && s.nlink === 1;
  if (!before || !privateFile(before)) return null;
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = fstatSync(fd);
    if (!privateFile(opened) || opened.ino !== before.ino || opened.dev !== before.dev) return null;
    return readFileSync(fd);
  } finally { closeSync(fd); }
}
function intentionalSpeakInput(path: string, privateRoot: string, recordingsRoot?: string): boolean {
  if (!recordingsRoot || ![privateRoot, recordingsRoot].every(p =>
    isAbsolute(p) && normalize(p) === p && !p.endsWith("/")) ||
    !recordingsRoot.startsWith(privateRoot + "/")) return false;
  const parts = relative(recordingsRoot, path).split("/");
  if (parts.length !== 3 || parts[2] !== "input.txt" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/.test(parts[1]) ||
    parts[0] !== parts[1].slice(0, 10)) return false;
  // Inspect every ancestor before opening either file; aliases never confer permission.
  let current = parse(path).root;
  for (const part of dirname(path).slice(current.length).split("/")) {
    current = join(current, part);
    const s = statOrMissing(current);
    if (!s || !s.isDirectory() || s.isSymbolicLink()) return false;
    if ((current === privateRoot || current.startsWith(privateRoot + "/")) &&
      (s.uid !== process.getuid?.() || (s.mode & 0o7777) !== 0o700)) return false;
  }
  const input = readPrivateFile(path), metadata = readPrivateFile(join(dirname(path), "metadata.json"));
  if (!input || !metadata) return false;
  let decoded: unknown;
  try { decoded = JSON.parse(metadata.toString("utf8")); }
  catch (error) { if (error instanceof SyntaxError) return false; throw error; }
  const result = speakInputMetadata.safeParse(decoded);
  if (!result.success) return false;
  const m = result.data;
  return m.id === parts[1] && m.created_at.replace(/[:.]/g, "-") === m.id.slice(0, 24) &&
    m.input.bytes === input.length && m.input.sha256 === createHash("sha256").update(input).digest("hex");
}

export function canaryChildEnv(root: string, nonce: string): NodeJS.ProcessEnv {
  return { ...process.env, HOME: join(root, `CANARY-HOME-${nonce}`),
    PRIV11_CHILD: "1", PRIV11_NONCE: nonce, PRIV11_TEXT: `CANARY-TXT-${nonce}`,
    PRIV11_PRIVATE_ROOT: join(root, "private"),
    VOICELAYER_CONTROL_LAYER_BASE: join(root, "journal"),
    VOICELAYER_TMP_ROOT: join(root, "private", "tmp"),
    VOICELAYER_STATE_DIR: join(root, "state"),
    QA_VOICE_THINK_FILE: join(root, "thinking.md"),
    QA_VOICE_RETAINED_RECORDING_PATH: join(root, "private", "last-recording.wav"),
    QA_VOICE_RECORDING_STATE_PATH: join(root, "state", "recording-state.json"),
    QA_VOICE_RECORDING_HOLD_PATH: join(root, "state", "recording-hold"),
    VOICELAYER_TTS_SETTINGS_PATH: join(root, "state", "tts-settings.json"),
    QA_VOICE_TTS_VOICE: "en-US-JennyNeural",
    QA_VOICE_STT_POLISH: "off",
    QA_VOICE_STT_POLISH_LOG_PATH: join(root, "polish-shadow.jsonl"),
    QA_VOICE_RECORDINGS_DIR: join(root, "private", `CANARY-HOME-${nonce}`, "recordings"),
  };
}

export function diagnosticLeaks(root: string, tokens: string[], privateRoot = join(root, "private"), recordingsRoot?: string): string[] {
  const leaks: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.name === "polish-shadow.jsonl") continue; // Explicitly deferred quality dataset.
    if (entry.isDirectory()) leaks.push(...diagnosticLeaks(path, tokens, privateRoot, recordingsRoot));
    else if (entry.isFile()) {
      if (path.startsWith(privateRoot + "/") && privateArtifacts.has(entry.name)) continue;
      if (entry.name === "input.txt" && intentionalSpeakInput(path, privateRoot, recordingsRoot)) continue;
      const data = readFileSync(path); // Includes SQLite/WAL bytes; never follow symlinks.
      if (tokens.some(token => data.includes(token))) leaks.push(entry.name);
    } else if (entry.isSymbolicLink() && recordingsRoot &&
      (path === recordingsRoot || path.startsWith(recordingsRoot + "/"))) {
      leaks.push(entry.name); // Unproven archive alias: report without reading its target.
    }
  }
  return leaks;
}

export function streamLeaks(stdout: string, stderr: string, tokens: string[]): string[] {
  return [stdout, stderr].flatMap((output, i) => tokens.some(t => output.includes(t)) ? [i === 0 ? "stdout" : "stderr"] : []);
}

export function assertNoCanaryDiagnostics(root: string, tokens: string[], stdout = "", stderr = "", recordingsRoot?: string): void {
  const sinks = [...streamLeaks(stdout, stderr, tokens), ...diagnosticLeaks(root, tokens, join(root, "private"), recordingsRoot)];
  if (sinks.length) throw new Error("Privacy canary escaped: " + sinks.join(", "));
}
