import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "fs";
import { join, relative } from "path";

// Exact lines AND occurrence budgets: adding a home path even in an allowed
// file needs review. These exceptions are fixtures, isolation or path contracts.
const ALLOWED: Record<string, Array<[string, number]>> = {
  // Synthetic protocol payloads, no archive access.
  "src/__tests__/ack-protocol.test.ts": [
    ["\"/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav\";", 2],
  ],
  // CLI help output assertion; no archive access.
  "src/__tests__/benchmark-audio-input.test.ts": [
    ["expect(result.output).toContain(\"~/.local/share/voicelayer/recordings\");", 1],
  ],
  // Synthetic cask source strings only.
  "src/__tests__/brew-cask-sync.test.ts": [
    ["'cask \"voicebar\" do\\n  uninstall trash: [\"~/Library/LaunchAgents/x.plist\"]\\nend\\n',", 1],
    ["'    \"~/Library/LaunchAgents/com.voicelayer.voicebar.plist\",',", 1],
  ],
  // Synthetic process command strings only.
  "src/__tests__/daemon-startup.test.ts": [
    ["\"/Users/me/.bun/bin/bun run /Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts\",", 1],
    ["readProcessCommand: () => \"bun /Users/me/.bun/bin/voicelayer-mcp\",", 1],
  ],
  // Synthetic state-dir containment fixture.
  "src/__tests__/paths.test.ts": [
    ["const liveStateDir = \"/Users/fixture-user/.local/state/voicelayer\";", 1],
  ],
  // Negative assertion that the isolated journal is outside the real home.
  "src/__tests__/preload-control-layer.test.ts": [
    ["expect(result.base).not.toStartWith(join(homedir(), \".local\", \"share\", \"orc\"));", 1],
  ],
  // Passes HOME to an isolated child; no private path construction.
  "src/__tests__/preload-git-env.test.ts": [
    ["HOME: process.env.HOME ?? \"\",", 1],
  ],
  // Saves, redirects and restores HOME for temporary fixtures.
  "src/__tests__/pronunciation.test.ts": [
    ["const originalHome = process.env.HOME;", 1],
    ["process.env.HOME = TEST_DIR;", 1],
    ["process.env.HOME = originalHome;", 1],
  ],
  // Synthetic profile text, expanded under a temporary HOME.
  "src/__tests__/qwen3-profile-catalog.test.ts": [
    ["const profile = (clip = \"~/.voicelayer/voices/ben-c1/ref.wav\", text = \"Synthetic reference transcript.\") =>", 1],
  ],
  // Profile literals and subprocesses with temporary HOME; existing voices.json preset metadata check only, no corpus.
  "src/__tests__/qwen3.test.ts": [
    ["expect(profile.model_path).toBe(\"~/.voicelayer/models/qwen3-tts-4bit\");", 1],
    ["expect(profile.model).toBe(\"~/.voicelayer/models/qwen3-tts-4bit\");", 2],
    ["\"~/.voicelayer/voices/theo/samples/clip-003.wav\",", 2],
    ["\"~/.voicelayer/voices/theo/samples/clip-011.wav\",", 1],
    ["\"~/.voicelayer/voices/theo/samples/clip-007.wav\",", 1],
    ["expect(profile.reference_clip).toBe(\"~/test.wav\");", 1],
    ["model: \"~/.voicelayer/models/qwen3-tts-4bit\",", 1],
    ["const voicesRoot = join(process.env.HOME, \".voicelayer\", \"voices\");", 1],
    ["const profilePath = join(process.env.HOME, \".voicelayer\", \"voices\", \"theo-c4s\", \"profile.yaml\");", 1],
    ["process.env.HOME || \"~\",", 1],
  ],
  // Pure default-path resolver assertions; no private file reads.
  "src/__tests__/security-hardening.test.ts": [
    ["const home = homedir();", 1],
    ["const expected = join(homedir(), \".local\", \"state\", \"voicelayer\");", 1],
  ],
  // Redirects HOME to TEST_TMP for session fixtures.
  "src/__tests__/session.test.ts": [
    ["process.env.HOME = TEST_HOME;", 1],
  ],
  // Synthetic protocol payloads, no archive access.
  "src/__tests__/socket-protocol.test.ts": [
    ["\"/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav\",", 1],
    ["\"/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav\";", 1],
  ],
  // Synthetic path spoken-text conversion fixture.
  "src/__tests__/speakable-text.test.ts": [
    ["[\"/Users/dev/app/qwen3_tts/qwen3_tts.py\", \"slash Users slash dev slash app slash qwen three T T S slash qwen three T T S dot P Y\"],", 1],
  ],
  // Prompt string assertion only.
  "src/__tests__/stt-cleanup.test.ts": [
    ["expect(prompt).toContain(\"~/.golems-brain/zikaron\");", 1],
  ],
  // Synthetic path-preservation input; no filesystem access.
  "src/__tests__/stt-polish.test.ts": [
    ["cleanedText: \"Read /Users/fixture-user/project/src/input.ts before editing.\",", 1],
  ],
  // Literal punctuation fixture only.
  "src/__tests__/stt-punctuation.test.ts": [
    ["expect(restoreSentencePunctuation(\"~/Gits/voicelayer\")).toBe(", 1],
    ["\"~/Gits/voicelayer\",", 1],
  ],
  // Synthetic process/launchctl output parsed by the script fixture.
  "src/__tests__/voicebar-hotkey-health-script.test.ts": [
    ["\"\\tpath = /Users/test/Library/LaunchAgents/com.voicelayer.voicebar.plist\",", 1],
    ["\"  456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar\",", 1],
    ["\"456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar\",", 1],
  ],
  // Synthetic rsync arguments under mocked commands.
  "src/__tests__/voicelayer-update-script.test.ts": [
    ["\"fixture-host:/Users/fixture-user\",", 1],
    ["\"fixture-host:/Users/fixture-user/.voicelayer/voices/\",", 1],
  ],
  // Mock HTTP model-path strings only.
  "src/__tests__/whisper-server.test.ts": [
    ["model: \"/Users/me/.cache/whisper/ggml-large-v3-turbo.bin\",", 2],
    ["\"/Users/me/.cache/whisper/ggml-large-v3-turbo.bin\",", 1],
  ],
  // Synthetic profile paths expanded under temporary HOME.
  "tests/test_tts_daemon_security.py": [
    ["\"tilde\": \"~/.voicelayer/voices/fixture-speaker_2/samples/clip 01.wav\",", 1],
    ["\"tilde\": \"~/models/fixture-model\",", 1],
  ],
};

function homeLines(source: string): string[] {
  return source.split(/\r?\n/).map(line => line.trim()).filter(line =>
    /\b(?:os\.)?homedir\s*\(|\bprocess\.env(?:\.HOME\b|\[["']HOME["']\])|["'`]~\/|\/Users\//.test(line),
  );
}

function unexpected(file: string, source: string): string[] {
  const budget = new Map(ALLOWED[file] ?? []);
  return homeLines(source).filter(line => {
    const remaining = budget.get(line) ?? 0;
    budget.set(line, remaining - 1);
    return remaining <= 0;
  });
}

function* files(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) yield* files(path);
    else if (entry.isFile()) yield path;
  }
}

test("private corpus home paths stay in the opt-in helper or reviewed exceptions", () => {
  const root = join(import.meta.dir, "../..");
  const failures: string[] = [];
  for (const dir of ["src/__tests__", "tests"]) {
    for (const path of files(join(root, dir))) {
      const file = relative(root, path);
      // The sole gated private-path resolver; this guard contains its own
      // allowlist literals and adversarial scanner fixtures (never executed).
      if (file === "src/__tests__/setup/private-specimens.ts" ||
          file === "src/__tests__/private-corpus-guard.test.ts") continue;
      for (const line of unexpected(file, readFileSync(path, "utf8"))) {
        failures.push(`${file}: ${line}`);
      }
    }
  }
  expect(failures).toEqual([]);
});

test("guard rejects each forbidden form in both new and allowlisted files", () => {
  for (const source of ["homedir()", "os.homedir()", "process.env.HOME",
    "process.env['HOME']", '"~/private"', "`~/private`", '"/Users/private/archive"']) {
    expect(unexpected("tests/new.test.ts", source)).toEqual([source]);
    expect(unexpected("src/__tests__/qwen3.test.ts", source)).toEqual([source]);
  }
  const file = "src/__tests__/preload-git-env.test.ts";
  const line = ALLOWED[file][0][0];
  expect(unexpected(file, `${line}\n${line}`)).toEqual([line]);
});
