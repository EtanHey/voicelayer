import { readFileSync, readdirSync } from "fs";
import { join } from "path";

// Private archive/recovery artifacts are intentional content stores. A log
// alongside them is still a diagnostic and must be inspected before cleanup.
const privateArtifacts = new Set(["audio.wav", "fixture.wav", "last-recording.wav",
  "last-recording.wav.metadata.json", "metadata.json", "agent-audio.mp3",
  "agent-transcript.txt", "voicelayer-transcript.txt"]);

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
