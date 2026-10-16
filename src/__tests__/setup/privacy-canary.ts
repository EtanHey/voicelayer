import { readFileSync, readdirSync } from "fs";
import { join } from "path";

// Private archive/recovery artifacts are intentional content stores. A log
// alongside them is still a diagnostic and must be inspected before cleanup.
const privateArtifacts = new Set(["audio.wav", "fixture.wav", "last-recording.wav",
  "last-recording.wav.metadata.json", "metadata.json", "agent-audio.mp3",
  "agent-transcript.txt", "voicelayer-transcript.txt", "voicelayer-history.json"]);

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

export function diagnosticLeaks(root: string, tokens: string[], privateRoot = join(root, "private")): string[] {
  const leaks: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.name === "polish-shadow.jsonl") continue; // Explicitly deferred quality dataset.
    if (entry.isDirectory()) leaks.push(...diagnosticLeaks(path, tokens, privateRoot));
    else if (entry.isFile()) {
      if (path.startsWith(privateRoot + "/") && privateArtifacts.has(entry.name)) continue;
      const data = readFileSync(path); // Includes SQLite/WAL bytes; never follow symlinks.
      if (tokens.some(token => data.includes(token))) leaks.push(entry.name);
    }
  }
  return leaks;
}

export function streamLeaks(stdout: string, stderr: string, tokens: string[]): string[] {
  return [stdout, stderr].flatMap((output, i) => tokens.some(t => output.includes(t)) ? [i === 0 ? "stdout" : "stderr"] : []);
}

export function assertNoCanaryDiagnostics(root: string, tokens: string[], stdout = "", stderr = ""): void {
  const sinks = [...streamLeaks(stdout, stderr, tokens), ...diagnosticLeaks(root, tokens)];
  if (sinks.length) throw new Error("Privacy canary escaped: " + sinks.join(", "));
}
