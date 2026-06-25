import {
  describe,
  it,
  expect,
  beforeEach,
  afterEach,
  spyOn,
} from "bun:test";
import { chmodSync, existsSync, mkdirSync, writeFileSync, rmSync } from "fs";
import { join } from "path";

// --- Profile YAML parsing tests ---

describe("parseProfileYaml", () => {
  it("parses a complete profile.yaml", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: theo
engine: qwen3-tts
model_path: ~/.voicelayer/models/qwen3-tts-4bit
reference_clips:
  - path: ~/.voicelayer/voices/theo/samples/clip-003.wav
    text: "and that's the thing about TypeScript"
  - path: ~/.voicelayer/voices/theo/samples/clip-011.wav
    text: "so we built the whole thing in a weekend"
  - path: ~/.voicelayer/voices/theo/samples/clip-007.wav
    text: "the reason I love this stack"
reference_clip: ~/.voicelayer/voices/theo/samples/clip-003.wav
reference_text: "and that's the thing about TypeScript"
fallback: en-US-AndrewNeural
created: 2026-02-23
source: https://youtube.com/@t3dotgg
`;
    const profile = parseProfileYaml(yaml);

    expect(profile.name).toBe("theo");
    expect(profile.engine).toBe("qwen3-tts");
    expect(profile.model_path).toBe("~/.voicelayer/models/qwen3-tts-4bit");
    expect(profile.model).toBe("~/.voicelayer/models/qwen3-tts-4bit");
    expect(profile.reference_clips).toHaveLength(3);
    expect(profile.reference_clips[0].path).toBe(
      "~/.voicelayer/voices/theo/samples/clip-003.wav",
    );
    expect(profile.reference_clips[0].text).toBe(
      "and that's the thing about TypeScript",
    );
    expect(profile.reference_clips[1].path).toBe(
      "~/.voicelayer/voices/theo/samples/clip-011.wav",
    );
    expect(profile.reference_clips[2].path).toBe(
      "~/.voicelayer/voices/theo/samples/clip-007.wav",
    );
    expect(profile.reference_clip).toBe(
      "~/.voicelayer/voices/theo/samples/clip-003.wav",
    );
    expect(profile.reference_text).toBe(
      "and that's the thing about TypeScript",
    );
    expect(profile.fallback).toBe("en-US-AndrewNeural");
    expect(profile.created).toBe("2026-02-23");
    expect(profile.source).toBe("https://youtube.com/@t3dotgg");
  });

  it("parses SSOT profile metadata for aliases, acceptance, model pins, and provenance", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: theo-c4s
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: true
aliases:
  - theo
  - t3
engine: qwen3-tts
model: ~/.voicelayer/models/qwen3-tts-4bit
reference_clip: ~/.voicelayer/voices/theo-c4s/samples/bright.wav
reference_clip_sha: abc123
reference_text: bright reference text
fallback: en-US-AndrewNeural
created: 2026-06-24
`;
    const profile = parseProfileYaml(yaml);

    expect(profile.profile_id).toBe("theo-c4s");
    expect(profile.profile_version).toBe("c4s");
    expect(profile.speaker).toBe("theo");
    expect(profile.accepted).toBe(true);
    expect(profile.aliases).toEqual(["theo", "t3"]);
    expect(profile.model).toBe("~/.voicelayer/models/qwen3-tts-4bit");
    expect(profile.reference_clip_sha).toBe("abc123");
  });

  it("handles minimal profile (no reference_clips array)", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: test
engine: qwen3-tts
reference_clip: ~/test.wav
reference_text: hello world
fallback: en-US-JennyNeural
`;
    const profile = parseProfileYaml(yaml);
    expect(profile.name).toBe("test");
    expect(profile.reference_clips).toHaveLength(0);
    expect(profile.reference_clip).toBe("~/test.wav");
    expect(profile.reference_text).toBe("hello world");
  });

  it("handles empty/missing fields with defaults", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: empty`;
    const profile = parseProfileYaml(yaml);

    expect(profile.name).toBe("empty");
    expect(profile.engine).toBe("qwen3-tts");
    expect(profile.fallback).toBe("en-US-JennyNeural");
    expect(profile.reference_clips).toHaveLength(0);
  });

  it("handles comments in YAML", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `# This is a comment
name: test # inline comment
engine: qwen3-tts
fallback: en-US-AndrewNeural # fallback voice
`;
    const profile = parseProfileYaml(yaml);
    expect(profile.name).toBe("test");
    expect(profile.fallback).toBe("en-US-AndrewNeural");
  });

  it("strips quotes from values", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: "quoted"
fallback: 'single-quoted'
`;
    const profile = parseProfileYaml(yaml);
    expect(profile.name).toBe("quoted");
    expect(profile.fallback).toBe("single-quoted");
  });
});

// --- Profile loading tests ---

describe("loadProfile + hasClonedProfile", () => {
  const testVoicesDir = join("/tmp", "voicelayer-test-voices");
  const testVoiceDir = join(testVoicesDir, "testvoice");

  beforeEach(() => {
    // Clean up and create test directories
    try {
      rmSync(testVoicesDir, { recursive: true });
    } catch {}
    mkdirSync(testVoiceDir, { recursive: true });
  });

  afterEach(async () => {
    const { clearProfileCache } = await import("../tts/qwen3");
    clearProfileCache();
    try {
      rmSync(testVoicesDir, { recursive: true });
    } catch {}
  });

  it("hasClonedProfile returns false for non-existent voice", async () => {
    const { hasClonedProfile } = await import("../tts/qwen3");
    expect(hasClonedProfile("nonexistent")).toBe(false);
  });

  it("loadProfile returns null for non-existent voice", async () => {
    const { loadProfile } = await import("../tts/qwen3");
    expect(loadProfile("nonexistent")).toBeNull();
  });
});

// --- Daemon communication tests (mocked) ---

describe("isDaemonHealthy", () => {
  it("returns false when daemon is not running", async () => {
    const savedTokenFile = process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE;
    process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE = join(
      "/tmp",
      `voicelayer-missing-tts-token-${process.pid}`,
    );
    const { isDaemonHealthy } = await import("../tts/qwen3");
    try {
      const result = await isDaemonHealthy();
      expect(result).toBe(false);
    } finally {
      if (savedTokenFile === undefined) {
        delete process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE;
      } else {
        process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE = savedTokenFile;
      }
    }
  });

  it("sends bearer auth from the shared token file", async () => {
    const tokenFile = join("/tmp", `voicelayer-tts-token-${process.pid}`);
    process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE = tokenFile;
    writeFileSync(tokenFile, "test-token\n", { mode: 0o600 });

    const fetchSpy = spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          status: "ok",
          model_loaded: true,
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      ),
    );

    try {
      const { isDaemonHealthy } = await import("../tts/qwen3");
      const result = await isDaemonHealthy();

      expect(result).toBe(true);
      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(fetchSpy.mock.calls[0]?.[1]).toMatchObject({
        headers: {
          Authorization: "Bearer test-token",
        },
      });
    } finally {
      fetchSpy.mockRestore();
      delete process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE;
      delete process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE;
      rmSync(tokenFile, { force: true });
    }
  });
});

describe("synthesizeCloned", () => {
  it("returns null when no profile exists", async () => {
    const { synthesizeCloned } = await import("../tts/qwen3");
    const result = await synthesizeCloned("hello", "nonexistent");
    expect(result).toBeNull();
  });

  it("forwards the profile-pinned model to the daemon request", () => {
    const homeDir = join("/tmp", `voicelayer-model-pin-${process.pid}`);
    const voiceDir = join(homeDir, ".voicelayer", "voices", "pinned");
    mkdirSync(voiceDir, { recursive: true });
    writeFileSync(
      join(voiceDir, "profile.yaml"),
      `name: pinned
profile_id: pinned
profile_version: v1
engine: qwen3-tts
model_path: ~/.voicelayer/models/qwen3-tts-4bit
reference_clip: ~/.voicelayer/voices/pinned/ref.wav
reference_text: hello
fallback: en-US-AndrewNeural
created: 2026-06-24
`,
    );
    const tokenFile = join(homeDir, ".voicelayer", "daemon.secret");
    writeFileSync(tokenFile, "test-token\n", { mode: 0o600 });

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          `
globalThis.fetch = async (_url, init) => {
  console.log(String(init.body));
  return new Response(JSON.stringify({ audio_b64: Buffer.from("mp3").toString("base64") }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
};
const { synthesizeCloned } = await import("./src/tts/qwen3.ts");
await synthesizeCloned("hello", "pinned");
`,
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout.toString())).toMatchObject({
        text: "hello",
        model: "~/.voicelayer/models/qwen3-tts-4bit",
      });
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });
});

describe("daemon auth token helpers", () => {
  const tokenFile = join("/tmp", `voicelayer-tts-token-helper-${process.pid}`);

  afterEach(() => {
    delete process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE;
    delete process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE;
    rmSync(tokenFile, { force: true });
  });

  it("builds Authorization headers when the token file is 0600", async () => {
    process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE = tokenFile;
    writeFileSync(tokenFile, "helper-token\n", { mode: 0o600 });

    const { buildDaemonRequestHeaders } = await import("../tts/qwen3");
    expect(buildDaemonRequestHeaders(true)).toEqual({
      "Content-Type": "application/json",
      Authorization: "Bearer helper-token",
    });
  });

  it("rejects token files with broad permissions", async () => {
    process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE = tokenFile;
    writeFileSync(tokenFile, "helper-token\n", { mode: 0o600 });
    chmodSync(tokenFile, 0o644);

    const { buildDaemonRequestHeaders } = await import("../tts/qwen3");
    expect(buildDaemonRequestHeaders(true)).toBeNull();
  });

  it("prefers VOICELAYER_TTS_DAEMON_SECRET_FILE when set", async () => {
    process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE = tokenFile;
    writeFileSync(tokenFile, "preferred-token\n", { mode: 0o600 });

    const { buildDaemonRequestHeaders } = await import("../tts/qwen3");
    expect(buildDaemonRequestHeaders(true)).toEqual({
      "Content-Type": "application/json",
      Authorization: "Bearer preferred-token",
    });
  });
});

// --- Three-tier routing in resolveVoice ---

describe("resolveVoice with cloned voices", () => {
  it("returns edge-tts engine for default (no voice name)", async () => {
    const { resolveVoice } = await import("../tts");
    const result = resolveVoice();
    expect(result.engine).toBe("edge-tts");
    expect(result.voice).toContain("Jenny");
  });

  it("uses a cloned profile when QA_VOICE_TTS_VOICE names one", () => {
    const homeDir = join("/tmp", `voicelayer-default-voice-${process.pid}`);
    const voiceDir = join(homeDir, ".voicelayer", "voices", "envclone");
    mkdirSync(voiceDir, { recursive: true });
    writeFileSync(
      join(voiceDir, "profile.yaml"),
      `name: envclone
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/envclone/ref.wav
reference_text: hello
fallback: en-US-AndrewNeural
created: 2026-06-06
`,
    );

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          "import { resolveVoice } from './src/tts.ts'; console.log(JSON.stringify(resolveVoice()));",
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
          QA_VOICE_TTS_VOICE: "envclone",
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout.toString())).toEqual({
        voice: "envclone",
        engine: "cloned",
        fallbackVoice: "en-US-AndrewNeural",
      });
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("resolves a speaker alias to the latest accepted cloned profile", () => {
    const homeDir = join("/tmp", `voicelayer-alias-${process.pid}`);
    const voicesRoot = join(homeDir, ".voicelayer", "voices");
    mkdirSync(join(voicesRoot, "theo-c4"), { recursive: true });
    mkdirSync(join(voicesRoot, "theo-c4s"), { recursive: true });
    writeFileSync(
      join(voicesRoot, "theo-c4", "profile.yaml"),
      `name: theo-c4
profile_id: theo-c4
profile_version: c4
speaker: theo
accepted: false
superseded_by: theo-c4s
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4/ref.wav
reference_text: muffled
fallback: en-US-AndrewNeural
created: 2026-06-20
`,
    );
    writeFileSync(
      join(voicesRoot, "theo-c4s", "profile.yaml"),
      `name: theo-c4s
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: true
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4s/ref.wav
reference_text: bright
fallback: en-US-AndrewNeural
created: 2026-06-24
`,
    );

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          "import { resolveVoice } from './src/tts.ts'; console.log(JSON.stringify(resolveVoice('theo')));",
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout.toString())).toEqual({
        voice: "theo-c4s",
        engine: "cloned",
        fallbackVoice: "en-US-AndrewNeural",
      });
      expect(result.stderr.toString()).not.toContain("VOICE PROFILE DRIFT");
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("prefers the latest accepted alias over a legacy direct profile directory", () => {
    const homeDir = join("/tmp", `voicelayer-legacy-alias-${process.pid}`);
    const voicesRoot = join(homeDir, ".voicelayer", "voices");
    mkdirSync(join(voicesRoot, "theo"), { recursive: true });
    mkdirSync(join(voicesRoot, "theo-c4s"), { recursive: true });
    writeFileSync(
      join(voicesRoot, "theo", "profile.yaml"),
      `name: theo
profile_id: theo
profile_version: c3
speaker: theo
accepted: false
superseded_by: theo-c4s
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo/ref.wav
reference_text: legacy
fallback: en-US-AndrewNeural
created: 2026-06-01
`,
    );
    writeFileSync(
      join(voicesRoot, "theo-c4s", "profile.yaml"),
      `name: theo-c4s
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: true
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4s/ref.wav
reference_text: bright
fallback: en-US-AndrewNeural
created: 2026-06-24
`,
    );

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          "import { resolveVoice } from './src/tts.ts'; console.log(JSON.stringify(resolveVoice('theo')));",
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout.toString())).toMatchObject({
        voice: "theo-c4s",
        engine: "cloned",
      });
      expect(result.stderr.toString()).not.toContain("VOICE PROFILE DRIFT");
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("invalidates alias miss cache when accepted profiles are installed later", () => {
    const homeDir = join("/tmp", `voicelayer-late-alias-${process.pid}`);
    const voicesRoot = join(homeDir, ".voicelayer", "voices");
    mkdirSync(voicesRoot, { recursive: true });

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          `
import { mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { resolveVoice } from "./src/tts.ts";

const voicesRoot = join(process.env.HOME, ".voicelayer", "voices");
console.log(JSON.stringify(resolveVoice("theo")));
mkdirSync(join(voicesRoot, "theo-c4s"), { recursive: true });
writeFileSync(join(voicesRoot, "theo-c4s", "profile.yaml"), \`name: theo-c4s
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: true
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4s/ref.wav
reference_text: bright
fallback: en-US-AndrewNeural
created: 2026-06-24
\`);
console.log(JSON.stringify(resolveVoice("theo")));
`,
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      const lines = result.stdout.toString().trim().split("\n").map(JSON.parse);
      expect(lines[0]).toMatchObject({
        engine: "edge-tts",
      });
      expect(lines[1]).toMatchObject({
        voice: "theo-c4s",
        engine: "cloned",
      });
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("resolves canonical profile ids even when the voice folder has a different name", () => {
    const homeDir = join("/tmp", `voicelayer-profile-id-${process.pid}`);
    const voiceDir = join(homeDir, ".voicelayer", "voices", "theo-c4s-dir");
    mkdirSync(voiceDir, { recursive: true });
    writeFileSync(
      join(voiceDir, "profile.yaml"),
      `name: theo-c4s-dir
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: true
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4s-dir/ref.wav
reference_text: bright
fallback: en-US-AndrewNeural
created: 2026-06-24
`,
    );

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          "import { resolveVoice } from './src/tts.ts'; console.log(JSON.stringify(resolveVoice('theo-c4s')));",
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout.toString())).toMatchObject({
        voice: "theo-c4s",
        engine: "cloned",
        fallbackVoice: "en-US-AndrewNeural",
      });
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("preserves directory casing for direct cloned voice lookup and listing", () => {
    const homeDir = join("/tmp", `voicelayer-case-profile-${process.pid}`);
    const voiceDir = join(homeDir, ".voicelayer", "voices", "MyVoice");
    mkdirSync(voiceDir, { recursive: true });
    writeFileSync(
      join(voiceDir, "profile.yaml"),
      `name: MyVoice
profile_id: MyVoice
profile_version: v1
accepted: true
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/MyVoice/ref.wav
reference_text: mixed case
fallback: en-US-AndrewNeural
created: 2026-06-24
`,
    );

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          `
import { resolveVoice } from "./src/tts.ts";
import { listClonedVoiceProfiles } from "./src/tts/qwen3.ts";

console.log(JSON.stringify({
  resolved: resolveVoice("MyVoice"),
  profiles: listClonedVoiceProfiles(),
}));
`,
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      const output = JSON.parse(result.stdout.toString());
      expect(output.resolved).toMatchObject({
        voice: "MyVoice",
        engine: "cloned",
      });
      expect(output.profiles).toContain("MyVoice");
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("does not list invalid directories that only resolve through an alias", () => {
    const homeDir = join("/tmp", `voicelayer-list-direct-${process.pid}`);
    const voicesRoot = join(homeDir, ".voicelayer", "voices");
    mkdirSync(join(voicesRoot, "theo"), { recursive: true });
    mkdirSync(join(voicesRoot, "theo-c4s"), { recursive: true });
    writeFileSync(
      join(voicesRoot, "theo-c4s", "profile.yaml"),
      `name: theo-c4s
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: true
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4s/ref.wav
reference_text: bright
fallback: en-US-AndrewNeural
created: 2026-06-24
`,
    );

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          `
import { listClonedVoiceProfiles } from "./src/tts/qwen3.ts";

console.log(JSON.stringify(listClonedVoiceProfiles()));
`,
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      const profiles = JSON.parse(result.stdout.toString());
      expect(profiles).toContain("theo-c4s");
      expect(profiles).not.toContain("theo");
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("invalidates cached profile metadata after profile.yaml changes", () => {
    const homeDir = join("/tmp", `voicelayer-profile-refresh-${process.pid}`);
    const voiceDir = join(homeDir, ".voicelayer", "voices", "theo-c4s");
    mkdirSync(voiceDir, { recursive: true });

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          `
import { writeFileSync, utimesSync } from "fs";
import { join } from "path";
import { resolveVoice } from "./src/tts.ts";

const profilePath = join(process.env.HOME, ".voicelayer", "voices", "theo-c4s", "profile.yaml");
writeFileSync(profilePath, \`name: theo-c4s
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: true
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4s/ref.wav
reference_text: bright
fallback: en-US-AndrewNeural
created: 2026-06-24
\`);
console.log(JSON.stringify(resolveVoice("theo")));
writeFileSync(profilePath, \`name: theo-c4s
profile_id: theo-c4s
profile_version: c4s
speaker: theo
accepted: false
aliases:
  - theo
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4s/ref.wav
reference_text: bright
fallback: en-US-AndrewNeural
created: 2026-06-24
\`);
const future = new Date(Date.now() + 1000);
utimesSync(profilePath, future, future);
console.log(JSON.stringify(resolveVoice("theo")));
`,
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      const lines = result.stdout.toString().trim().split("\n").map(JSON.parse);
      expect(lines[0]).toMatchObject({
        voice: "theo-c4s",
        engine: "cloned",
      });
      expect(lines[1]).toMatchObject({
        engine: "edge-tts",
      });
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("warns loudly when a non-accepted cloned profile is used directly", () => {
    const homeDir = join("/tmp", `voicelayer-nonaccepted-${process.pid}`);
    const voiceDir = join(homeDir, ".voicelayer", "voices", "theo-c4");
    mkdirSync(voiceDir, { recursive: true });
    writeFileSync(
      join(voiceDir, "profile.yaml"),
      `name: theo-c4
profile_id: theo-c4
profile_version: c4
speaker: theo
accepted: false
superseded_by: theo-c4s
engine: qwen3-tts
reference_clip: ~/.voicelayer/voices/theo-c4/ref.wav
reference_text: muffled
fallback: en-US-AndrewNeural
created: 2026-06-20
`,
    );

    try {
      const result = Bun.spawnSync({
        cmd: [
          "bun",
          "-e",
          "import { resolveVoice } from './src/tts.ts'; console.log(JSON.stringify(resolveVoice('theo-c4')));",
        ],
        cwd: process.cwd(),
        env: {
          ...process.env,
          HOME: homeDir,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout.toString())).toMatchObject({
        voice: "theo-c4",
        engine: "cloned",
      });
      expect(result.stderr.toString()).toContain("VOICE PROFILE DRIFT");
      expect(result.stderr.toString()).toContain("theo-c4");
      expect(result.stderr.toString()).toContain("theo-c4s");
    } finally {
      rmSync(homeDir, { recursive: true, force: true });
    }
  });

  it("returns edge-tts engine for raw edge-tts voice name", async () => {
    const { resolveVoice } = await import("../tts");
    const result = resolveVoice("en-US-BrianNeural");
    expect(result.engine).toBe("edge-tts");
    expect(result.voice).toBe("en-US-BrianNeural");
  });

  it("returns edge-tts engine for preset profile names (when voices.json exists)", async () => {
    const { resolveVoice } = await import("../tts");
    const { existsSync } = await import("fs");
    const { join } = await import("path");
    const voicesFile = join(
      process.env.HOME || "~",
      ".voicelayer",
      "voices.json",
    );

    const result = resolveVoice("andrew");
    expect(result.engine).toBe("edge-tts");

    if (existsSync(voicesFile)) {
      // Local dev — voices.json has andrew preset
      expect(result.voice).toBe("en-US-AndrewNeural");
    } else {
      // CI — no voices.json, falls back to default with warning
      expect(result.warning).toBeDefined();
    }
  });

  it("returns edge-tts with warning for unknown voice", async () => {
    const { resolveVoice } = await import("../tts");
    const result = resolveVoice("unknown_voice_xyz");
    expect(result.engine).toBe("edge-tts");
    expect(result.warning).toBeDefined();
    expect(result.warning).toContain("Unknown voice");
  });
});
