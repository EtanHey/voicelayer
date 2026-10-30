import { afterEach, expect, test, spyOn } from "bun:test";
import * as fs from "fs";
import { basename, dirname, join } from "path";
import { createHash } from "crypto";
import { archiveVoiceAskCapture, createWavBuffer, finalizeVoiceAskArchive } from "../input";
import { verifyConversationPairedCapture, type PairedCaptureExpectation } from "../conversation-paired-verification";

const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const names = ["agent-audio.mp3", "agent-transcript.txt", "audio.wav", "metadata.json"] as const;
const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT!;
expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
expect(process.env.VOICELAYER_TEST_REAL_MIC).not.toBe("1");
expect(process.env.VOICELAYER_TEST_REAL_ARCHIVE).not.toBe("1");
expect(process.env.QA_VOICE_RECORDINGS_DIR).toBe(join(runRoot, "recordings"));
console.log(JSON.stringify({ execPath: process.execPath, revision: Bun.revision, cwd: process.cwd(),
  executableSha256: hash(fs.readFileSync(process.execPath)), runRoot, archiveRoot: process.env.QA_VOICE_RECORDINGS_DIR }));
const cleanups: string[] = [];
const provenanceProbe = { machine: () => ({ host: "synthetic", chip: null, status: "ready" as const }),
  appVersion: () => ({ version: "synthetic", source: "env" as const }), polishMode: () => "off" as const };
afterEach(() => { for (const path of cleanups.splice(0)) fs.rmSync(path, { recursive: true, force: true }); });

function fixture() {
  const prompt = { agentAudioBytes: Buffer.from("ID3-synthetic-prompt"), agentAudioFormat: "mp3",
    agentTranscript: "A raw fu… retraction? שלום", agentTtsEngine: "qwen3-tts", agentTtsVoice: "synthetic",
    createdAt: new Date("2026-07-18T11:04:10.000Z") } satisfies PairedCaptureExpectation["prompt"];
  const userWav = createWavBuffer(new Uint8Array([1, 2, 3, 4, 5, 6]));
  const archivePath = archiveVoiceAskCapture({ options: { archiveSource: "voice_ask", voiceAskArtifacts: prompt },
    audioBytes: userWav, silenceMode: "thoughtful", pushToEnd: false, durationMs: 0.1875, provenanceProbe });
  cleanups.push(archivePath);
  const input: PairedCaptureExpectation = { archivePath, archiveRoot: process.env.QA_VOICE_RECORDINGS_DIR!,
    archiveId: basename(archivePath), prompt, userWav, source: "voice_ask", mode: "vad",
    format: { sampleRate: 16000, channels: 1, bitsPerSample: 16 } };
  const file = (name: string) => join(archivePath, name);
  const snapshot = () => names.map(name => !fs.existsSync(file(name)) ? null
    : fs.lstatSync(file(name)).isSymbolicLink() ? fs.readlinkSync(file(name)) : fs.readFileSync(file(name)));
  const metadata = (patch: object) => fs.writeFileSync(file("metadata.json"), JSON.stringify({
    ...JSON.parse(fs.readFileSync(file("metadata.json"), "utf8")), ...patch }));
  return { input, file, snapshot, metadata };
}

function unavailable(result: ReturnType<typeof verifyConversationPairedCapture>, closureStatus = "closed") {
  expect(result).toEqual({ kind: "verification-unavailable", code: "paired-capture-verification-failed", closureStatus });
  expect("archiveId" in result).toBe(false);
  expect("archivePath" in result).toBe(false);
}

test("real producer's captured-only files produce truthful capture evidence; no production callers", () => {
  const f = fixture();
  expect(fs.existsSync(f.file("voicelayer-transcript.txt"))).toBe(false);
  const before = f.snapshot();
  const result = verifyConversationPairedCapture(f.input);
  expect(result.kind).toBe("verified-paired");
  if (result.kind !== "verified-paired") throw new Error("capture was not verified");
  expect(result).toMatchObject({ archiveId: f.input.archiveId, archivePath: f.input.archivePath,
    audioStatus: "captured", transcriptStatus: "unverified", closureStatus: "closed" });
  for (const name of names) {
    const bytes = fs.readFileSync(f.file(name));
    expect(result.artifacts[name]).toEqual({ bytes: bytes.length, sha256: hash(bytes) });
  }
  expect(f.snapshot()).toEqual(before);
  for (const path of fs.readdirSync("src", { recursive: true }).map(String)
    .filter(path => path.endsWith(".ts") && !path.includes("__tests__") && path !== "conversation-paired-verification.ts")) {
    expect(fs.readFileSync(join("src", path), "utf8")).not.toContain("conversation-paired-verification");
  }
  expect(fs.readFileSync("package.json", "utf8")).not.toContain("conversation-paired-verification");
});

for (const name of names) for (const change of ["missing", "corrupt", "changed", "symlink"]) {
  test(`${change} required artifact ${name} refuses and preserves bytes`, () => {
    const f = fixture();
    if (change === "missing" || change === "symlink") fs.unlinkSync(f.file(name));
    if (change === "symlink") fs.symlinkSync(f.file(names.find(other => other !== name)!), f.file(name));
    if (change === "corrupt") fs.writeFileSync(f.file(name), Buffer.from([0xff, 0xfe]));
    if (change === "changed") fs.appendFileSync(f.file(name), "changed");
    const before = f.snapshot();
    unavailable(verifyConversationPairedCapture(f.input));
    expect(f.snapshot()).toEqual(before);
  });
}

for (const patch of [{ id: "receipt-uuid" }, { source: "voicebar" }, { schema_version: 3 }, { mode: "ptt" },
  { sample_rate: 48000 }, { channels: 2 }, { audio_sha256: "wrong" }, { user_audio_sha256: "wrong" },
  { agent_audio_sha256: "wrong" }, { agent_transcript_chars: 1 }, { created_at: "2020-01-01T00:00:00.000Z" },
  { agent_tts_voice: "foreign" }, { agent_tts_engine: "edge-tts" }, { artifacts: { user_audio: "../audio.wav" } }]) {
  test(`metadata substitution ${JSON.stringify(patch)} cannot certify capture`, () => {
    const f = fixture(); f.metadata(patch);
    const before = f.snapshot(); unavailable(verifyConversationPairedCapture(f.input)); expect(f.snapshot()).toEqual(before);
  });
}

test("matching replacement metadata hashes cannot replace actual prompt or full WAV", () => {
  for (const name of ["agent-audio.mp3", "audio.wav", "agent-transcript.txt"]) {
    const f = fixture(); const replacement = Buffer.from("unrelated bytes"); fs.writeFileSync(f.file(name), replacement);
    f.metadata(name === "agent-audio.mp3" ? { agent_audio_sha256: hash(replacement) }
      : name === "audio.wav" ? { user_audio_sha256: hash(replacement), audio_sha256: hash(replacement) }
      : { agent_transcript_chars: replacement.length });
    const before = f.snapshot(); unavailable(verifyConversationPairedCapture(f.input)); expect(f.snapshot()).toEqual(before);
  }
});

test("foreign identity/path and symlinked hierarchy are refused", () => {
  const f = fixture(); const before = f.snapshot();
  for (const input of [{ ...f.input, archiveId: "receipt-uuid" }, { ...f.input, archivePath: dirname(f.input.archivePath) },
    { ...f.input, archiveRoot: join(f.input.archiveRoot, "foreign") }]) unavailable(verifyConversationPairedCapture(input));
  for (const target of [f.input.archivePath, dirname(f.input.archivePath), f.input.archiveRoot]) {
    const alias = `${target}-alias`; fs.symlinkSync(target, alias); cleanups.push(alias);
    const relative = f.input.archivePath.slice(target.length);
    unavailable(verifyConversationPairedCapture({ ...f.input, archivePath: alias + relative,
      archiveRoot: target === f.input.archiveRoot ? alias : f.input.archiveRoot }));
  }
  expect(f.snapshot()).toEqual(before);
});

for (const operation of ["open", "sync", "close", "close-before", "close-persistent"]) for (let targetIndex = 0; targetIndex < 8; targetIndex++) {
  test(`strict ${operation} failure at hierarchy target ${targetIndex} refuses and reports closure evidence`, () => {
    const f = fixture(); const before = f.snapshot();
    const targets = [...names.map(f.file), f.input.archivePath, dirname(f.input.archivePath),
      f.input.archiveRoot, dirname(f.input.archiveRoot)];
    const opened = new Map<number, string>(); const closed: number[] = []; const attempts: number[] = []; const synced: string[] = [];
    const open = fs.openSync, sync = fs.fsyncSync, close = fs.closeSync;
    let faulted = false;
    const fail = () => { faulted = true; throw new Error("synthetic private detail must not escape"); };
    const spies = [spyOn(fs, "openSync").mockImplementation((path, flags, mode) => {
      if (operation === "open" && path === targets[targetIndex]) return fail();
      const fd = open(path, flags, mode); opened.set(fd, String(path)); return fd;
    }), spyOn(fs, "fsyncSync").mockImplementation(fd => {
      synced.push(opened.get(fd)!); if (operation === "sync" && opened.get(fd) === targets[targetIndex]) fail(); sync(fd);
    }), spyOn(fs, "closeSync").mockImplementation(fd => {
      attempts.push(fd);
      if ((operation === "close-persistent" || operation === "close-before" && !faulted) &&
        opened.get(fd) === targets[targetIndex]) fail();
      close(fd); closed.push(fd); if (operation === "close" && opened.get(fd) === targets[targetIndex]) fail();
    })];
    try { unavailable(verifyConversationPairedCapture(f.input), operation.startsWith("close") ? "unconfirmed" : "closed"); }
    finally { for (const spy of spies) spy.mockRestore(); }
    try {
      expect(faulted).toBe(true);
      const leftOpen = [...opened.keys()].filter(fd => operation.startsWith("close-") && opened.get(fd) === targets[targetIndex]);
      expect(attempts.sort()).toEqual([...opened.keys()].sort());
      expect(closed.sort()).toEqual([...opened.keys()].filter(fd => !leftOpen.includes(fd)).sort());
      for (const fd of opened.keys()) {
        if (leftOpen.includes(fd)) expect(fs.fstatSync(fd).ino).toBe(fs.statSync(opened.get(fd)!).ino);
        else expect(() => fs.fstatSync(fd)).toThrow();
      }
      if (operation.startsWith("close")) expect(synced).toEqual(targets);
      expect(f.snapshot()).toEqual(before);
    } finally { // Synthetic before-close RED must not leave its fixture fd open.
      for (const fd of opened.keys()) { try { close(fd); } catch {} }
    }
  });
}

for (const target of ["foreign.txt", "metadata.json"]) test(`close failure after fd reuse preserves replacement ${target}`, () => {
  const f = fixture(); const before = f.snapshot(); const foreign = f.file(target);
  if (target === "foreign.txt") fs.writeFileSync(foreign, "foreign descriptor");
  const replacementBytes = fs.readFileSync(foreign, "utf8");
  const close = fs.closeSync, open = fs.openSync; let replacement: number | undefined;
  const spy = spyOn(fs, "closeSync").mockImplementation(fd => {
    close(fd);
    if (replacement === undefined) {
      replacement = open(foreign, "r"); expect(replacement).toBe(fd);
      throw new Error("synthetic after-close reuse");
    }
  });
  try {
    unavailable(verifyConversationPairedCapture(f.input), "unconfirmed"); expect(replacement).toBeDefined();
    expect(fs.readFileSync(replacement!, "utf8")).toBe(replacementBytes);
    expect(f.snapshot()).toEqual(before);
  } finally { spy.mockRestore(); if (replacement !== undefined) close(replacement); }
});

test("all strict sync targets are actual required files and selected parent links", () => {
  const f = fixture(); const opened = new Map<number, string>(); const synced: string[] = [];
  const open = fs.openSync, sync = fs.fsyncSync;
  const a = spyOn(fs, "openSync").mockImplementation((path, flags, mode) => {
    const fd = open(path, flags, mode); opened.set(fd, String(path)); return fd;
  });
  const b = spyOn(fs, "fsyncSync").mockImplementation(fd => { synced.push(opened.get(fd)!); sync(fd); });
  try { expect(verifyConversationPairedCapture(f.input).kind).toBe("verified-paired"); }
  finally { a.mockRestore(); b.mockRestore(); }
  expect(synced).toEqual([...names.map(f.file), f.input.archivePath, dirname(f.input.archivePath),
    f.input.archiveRoot, dirname(f.input.archiveRoot)]);
});

test("symlinks substituted at the actual expected directory paths are refused", () => {
  const f = fixture(); const before = f.snapshot();
  for (const path of [f.input.archivePath, dirname(f.input.archivePath), f.input.archiveRoot]) {
    const saved = `${path}-saved`; fs.renameSync(path, saved); fs.symlinkSync(saved, path);
    try { unavailable(verifyConversationPairedCapture(f.input)); }
    finally { fs.unlinkSync(path); fs.renameSync(saved, path); }
  }
  expect(f.snapshot()).toEqual(before);
});

test("identity changes during sync refuse success, close fds and preserve both byte sets", () => {
  const f = fixture(); const original = fs.readFileSync(f.file("audio.wav"));
  const descriptors: number[] = []; const open = fs.openSync, sync = fs.fsyncSync;
  let mutated: ReturnType<typeof f.snapshot> | undefined;
  const a = spyOn(fs, "openSync").mockImplementation((path, flags, mode) => {
    const fd = open(path, flags, mode); descriptors.push(fd); return fd;
  });
  const b = spyOn(fs, "fsyncSync").mockImplementation(fd => {
    if (!mutated) { fs.renameSync(f.file("audio.wav"), f.file("original.wav"));
      fs.writeFileSync(f.file("audio.wav"), "substitution"); mutated = f.snapshot(); }
    sync(fd);
  });
  try { unavailable(verifyConversationPairedCapture(f.input)); }
  finally { a.mockRestore(); b.mockRestore(); }
  expect(f.snapshot()).toEqual(mutated); expect(fs.readFileSync(f.file("original.wav"))).toEqual(original);
  for (const fd of descriptors) expect(() => fs.fstatSync(fd)).toThrow();
});

for (const [offset, value] of [[4, 0], [16, 0], [20, 3], [22, 2], [24, 48000], [28, 0], [32, 4], [34, 8], [40, 0]]) {
  test(`even matching bytes/hashes cannot certify malformed normalized WAV field ${offset}`, () => {
    const f = fixture(); const malformed = Buffer.from(f.input.userWav); malformed.writeUInt32LE(value, offset);
    fs.writeFileSync(f.file("audio.wav"), malformed); f.metadata({ audio_sha256: hash(malformed), user_audio_sha256: hash(malformed) });
    const before = f.snapshot(); unavailable(verifyConversationPairedCapture({ ...f.input, userWav: malformed }));
    expect(f.snapshot()).toEqual(before);
  });
}

test("failed or later finalization stays separate; fresh verification rereads current files", () => {
  const f = fixture(); const result = verifyConversationPairedCapture(f.input);
  expect(result.kind).toBe("verified-paired"); const capture = f.snapshot();
  fs.mkdirSync(f.file("voicelayer-transcript.txt"));
  expect(() => finalizeVoiceAskArchive(f.input.archivePath, { transcript: "synthetic", backend: "synthetic", provenanceProbe })).toThrow();
  expect(f.snapshot()).toEqual(capture); expect(verifyConversationPairedCapture(f.input).kind).toBe("verified-paired");
  fs.rmdirSync(f.file("voicelayer-transcript.txt"));
  finalizeVoiceAskArchive(f.input.archivePath, { transcript: "synthetic", backend: "synthetic", provenanceProbe });
  expect(verifyConversationPairedCapture(f.input)).toMatchObject({ kind: "verified-paired", transcriptStatus: "unverified" });
  fs.appendFileSync(f.file("audio.wav"), "later damage");
  unavailable(verifyConversationPairedCapture(f.input)); expect(result).toMatchObject({ transcriptStatus: "unverified" });
});
