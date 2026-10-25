import { expect, test, spyOn, setSystemTime } from "bun:test";
import * as fs from "fs";
import { readFileSync } from "fs";
import { join } from "path";
import { createSpeakReceipt } from "../speak-archive";
import { transitionSpeakArchive, recoverSpeakArchive, updateSpeakLifecycle, saveSpeakArtifact, saveSpeakGenerated, readSpeakArchive, startSpeakPlayer, endSpeakPlayer, type SpeakLifecycle } from "../speak-archive-store";
function receipt() {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const result = createSpeakReceipt({ input: "  exact original\n", request_id: crypto.randomUUID(), request_source: "selection",
    connection: "daemon", format: "plain", blocking: false,
    requested: { mode: null, profile: null, engine: null, voice: "requested-voice", rate: null },
    build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
  if (result.kind !== "created") throw new Error(result.code);
  return result.context;
}
for (const terminal of ["completed", "stopped", "cancelled", "failed"] as const) {
  test(`state store durably writes ${terminal} without changing original input`, () => {
    const c = receipt();
    expect(transitionSpeakArchive(c, "preparing").kind).toBe("stored");
    expect(transitionSpeakArchive(c, "playing").kind).toBe("stored");
    expect(transitionSpeakArchive(c, terminal, "USER_STOP").kind).toBe("stored");
    const m = JSON.parse(readFileSync(join(c.path, "metadata.json"), "utf8"));
    expect(m.speech).toMatchObject({ state: terminal, reason: "USER_STOP" });
    expect(m.speech.transitions.map((t: { to: string }) => t.to)).toEqual(["preparing", "playing", terminal]);
    expect(readFileSync(join(c.path, "input.txt"), "utf8")).toBe("  exact original\n");
    expect(transitionSpeakArchive(c, "playing")).toEqual({ kind: "failed", code: "CONFLICT" });
    expect(recoverSpeakArchive(c.id)).toMatchObject({ kind: "stored", metadata: { speech: { state: terminal } } });
  });
}
for (const state of ["requested", "preparing", "playing", "paused"] as const) {
  test(`restart recovers ${state} to interrupted and preserves terminal recovery`, () => {
    const c = receipt(); if (state === "requested") saveSpeakGenerated(c, generated(c)); if (state !== "requested") transitionSpeakArchive(c, "preparing");
    if (state === "playing" || state === "paused") transitionSpeakArchive(c, state);
    expect(recoverSpeakArchive(c.id)).toMatchObject({ kind: "stored", metadata: { speech: { state: "interrupted", reason: "PROCESS_RESTART" } } });
    const before = readFileSync(join(c.path, "metadata.json")); recoverSpeakArchive(c.id);
    expect(readFileSync(join(c.path, "metadata.json"))).toEqual(before);
  });
}

const disk = (c: ReturnType<typeof receipt>) => JSON.parse(readFileSync(join(c.path, "metadata.json"), "utf8"));
function legacy(status: SpeakLifecycle["status"]): SpeakLifecycle {
  return { status, generation_id: null, timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null }, summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: status === "rejected" ? "REJECTED" : null }, played_spans: [] };
}
function generated(c: ReturnType<typeof receipt>, index = 0) {
  const result = saveSpeakArtifact(c, { bytes: Buffer.from(`synthetic audio ${index}`), role: "playback_ready", mime: "audio/mpeg", duration_ms: 1000, sample_rate: null, channels: null });
  if (result.kind !== "stored") throw new Error(result.code);
  return { index, text: `exact transformed input ${index}`, audio_path: result.metadata.artifacts.at(-1)!.relative_path!, voice: "effective-voice", profile: "long", engine: "edge", generated_at: "2026-10-26T00:00:00.000Z" };
}
test("mixed writers validate and log illegal edges without mutation", () => {
  const c = receipt(); transitionSpeakArchive(c, "preparing");
  const before = readFileSync(join(c.path, "metadata.json")), log = spyOn(console, "error").mockImplementation(() => {});
  try {
    expect(updateSpeakLifecycle(c, legacy("completed"))).toEqual({ kind: "failed", code: "CONFLICT" });
    expect(log).toHaveBeenCalledWith("[speech] illegal transition preparing -> completed");
    expect(readFileSync(join(c.path, "metadata.json"))).toEqual(before);
    expect(updateSpeakLifecycle(c, legacy("playing")).kind).toBe("stored");
    expect(updateSpeakLifecycle(c, legacy("preparing")).kind).toBe("failed");
    expect(updateSpeakLifecycle(c, legacy("completed")).kind).toBe("stored");
    expect(recoverSpeakArchive(c.id)).toMatchObject({ metadata: { status: "completed", speech: { state: "completed" } } });
  } finally { log.mockRestore(); }
});
for (const status of ["completed", "stopped", "replaced", "rejected", "failed", "interrupted_unknown"] as const) {
  test(`late generation cannot reopen legacy ${status}`, () => {
    const c = receipt();
    if (status === "interrupted_unknown") recoverSpeakArchive(c.id); else updateSpeakLifecycle(c, legacy(status));
    const item = generated(c); expect(saveSpeakGenerated(c, item).kind).toBe("stored");
    const state = status === "replaced" ? "stopped" : status === "rejected" ? "failed" : status === "interrupted_unknown" ? "interrupted" : status;
    expect(disk(c)).toMatchObject({ status, speech: { state, generated: [item] } });
    expect(transitionSpeakArchive(c, "preparing").kind).toBe("failed");
    expect(recoverSpeakArchive(c.id)).toMatchObject({ metadata: { status, speech: { state, generated: [item] } } });
    expect(readFileSync(join(c.path, item.audio_path), "utf8")).toBe("synthetic audio 0");
  });
}
test("private diagnostic reason is rejected without mutation", () => {
  const c = receipt(), before = readFileSync(join(c.path, "metadata.json"));
  expect(transitionSpeakArchive(c, "failed", "private selected text / exception" as never)).toEqual({ kind: "failed", code: "INVALID_INPUT" });
  expect(readFileSync(join(c.path, "metadata.json"))).toEqual(before);
});
for (const terminal of ["completed", "stopped", "cancelled", "failed", "interrupted"] as const) {
  test(`durable ${terminal} retains partial out-of-order generation and excludes player gaps`, () => {
    const c = receipt(), items = [generated(c, 2), generated(c, 0)];
    for (const item of items) saveSpeakGenerated(c, item);
    const now = Date.now();
    try {
      setSystemTime(now); transitionSpeakArchive(c, "preparing"); transitionSpeakArchive(c, "playing");
      setSystemTime(now + 1000); endSpeakPlayer(c); endSpeakPlayer(c);
      setSystemTime(now + 10000); startSpeakPlayer(c); startSpeakPlayer(c);
      setSystemTime(now + 10500); endSpeakPlayer(c);
      expect(transitionSpeakArchive(c, terminal).kind).toBe("stored");
    } finally { setSystemTime(); }
    const expected = disk(c);
    expect(expected).toMatchObject({ requested: { voice: "requested-voice" }, speech: { state: terminal, played_ms: 1500, playing_since: null, generated: [items[1], items[0]] } });
    expect(readSpeakArchive(c)).toMatchObject({ metadata: expected });
    expect(recoverSpeakArchive(c.id)).toMatchObject({ metadata: { ...expected, updated_at: expect.any(String), recovery: expect.any(Object) } });
    for (const item of items) expect(readFileSync(join(c.path, item.audio_path), "utf8")).toBe(`synthetic audio ${item.index}`);
  });
}
for (const operation of ["transition", "generated", "start", "end"] as const) for (const fault of ["rename", "file-sync", "directory-sync"] as const) {
  test(`${operation} ${fault}: atomic complete prior/new publication`, () => {
    const c = receipt(), item = generated(c); saveSpeakGenerated(c, item);
    transitionSpeakArchive(c, "preparing"); transitionSpeakArchive(c, "playing"); endSpeakPlayer(c);
    if (operation === "end") startSpeakPlayer(c);
    const prior = disk(c), rename = fs.renameSync, sync = fs.fsyncSync;
    const spy = fault === "rename" ? spyOn(fs, "renameSync").mockImplementation((a, b) => { if (String(b) === join(c.path, "metadata.json")) throw Error("synthetic"); rename(a, b); }) : spyOn(fs, "fsyncSync").mockImplementation(fd => { if (fault === "file-sync" ? fs.fstatSync(fd).isFile() : fs.fstatSync(fd).isDirectory()) throw Error("synthetic"); sync(fd); });
    try {
      const result = operation === "transition" ? transitionSpeakArchive(c, "stopped", "USER_STOP") : operation === "generated" ? saveSpeakGenerated(c, { ...item, index: 1 }) : operation === "start" ? startSpeakPlayer(c) : endSpeakPlayer(c);
      expect(result).toEqual({ kind: "failed", code: fault === "rename" ? "WRITE_UNCERTAIN" : "SYNC_UNCERTAIN" });
    } finally { spy.mockRestore(); }
    const actual = disk(c);
    if (fault !== "directory-sync") expect(actual).toEqual(prior);
    else {
      const expected = structuredClone(prior); expected.updated_at = actual.updated_at;
      if (operation === "transition") {
        expected.status = expected.lifecycle.status = expected.speech.state = "stopped"; expected.speech.reason = "USER_STOP";
        expected.speech.transitions.push({ from: "playing", to: "stopped", reason: "USER_STOP", at: actual.speech.transitions.at(-1).at });
        expected.lifecycle.timing.ended_ms = actual.lifecycle.timing.ended_ms; expected.lifecycle.summary.player_reported_played_ms = actual.speech.played_ms;
      }
      if (operation === "generated") { expected.speech.generated.push({ ...item, index: 1 }); expected.lifecycle.summary.generated_audio_ms = 2000; }
      expected.speech.played_ms = actual.speech.played_ms;
      expected.speech.playing_since = operation === "start" ? actual.speech.playing_since : null;
      expect(actual).toEqual(expected);
    }
  });
}

test("new writer validates an active legacy snapshot instead of restarting requested", () => {
  const c = receipt(); updateSpeakLifecycle(c, legacy("playing"));
  const before = readFileSync(join(c.path, "metadata.json"));
  expect(transitionSpeakArchive(c, "preparing")).toEqual({ kind: "failed", code: "CONFLICT" });
  expect(readFileSync(join(c.path, "metadata.json"))).toEqual(before);
});
test("a terminal compatibility outcome cannot be reopened even by stale speech state", () => {
  const c = receipt(); transitionSpeakArchive(c, "preparing");
  const m = disk(c); m.status = m.lifecycle.status = "completed";
  fs.writeFileSync(join(c.path, "metadata.json"), JSON.stringify(m));
  const before = readFileSync(join(c.path, "metadata.json"));
  expect(transitionSpeakArchive(c, "playing")).toEqual({ kind: "failed", code: "FINALIZED" });
  expect(readFileSync(join(c.path, "metadata.json"))).toEqual(before);
});

for (const reason of ["PLAYER_FAILED", "OUTPUT_UNAVAILABLE", "ARCHIVE_INCOMPLETE"] as const) {
  test(`failed speech retains legacy ${reason}`, () => {
    const c = receipt(); transitionSpeakArchive(c, "preparing");
    expect(transitionSpeakArchive(c, "failed", reason)).toMatchObject({ metadata: { lifecycle: { summary: { error_code: reason } } } });
  });
}
test("receipt indexes open intent and terminal transition removes it", () => {
  const c = receipt();
  const marker = join(process.env.QA_VOICE_RECORDINGS_DIR!, ".speech-open", c.id);
  expect(fs.existsSync(marker)).toBe(true);
  transitionSpeakArchive(c, "preparing"); transitionSpeakArchive(c, "failed", "SYNTH_FAILED");
  expect(fs.existsSync(marker)).toBe(false);
});
