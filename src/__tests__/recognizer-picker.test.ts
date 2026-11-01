import { test, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { mkdirSync, existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { selectRecognizer, type RecognizerTransitionDeps } from "../recognizer-controller";
import { readRecognizerStatus, configureRecognizerBusyProbe, recognizerSettingsPath, onRecognizerStatusChange,
  beginRecognizerRequest, finishRecognizerRequest, noteRecognizerEngine, noteRecognizerEffective, confirmRecognizerCleanup, recognizerRecovery, setRecognizerRecoveryWhisper, beginRecognizerMaintenance, finishRecognizerTransition } from "../recognizer-state";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand } from "../socket-handlers";
const saved = { state: process.env.VOICELAYER_STATE_DIR, backend: process.env.QA_VOICE_STT_BACKEND };
beforeEach(() => {
  const root = testTmp("recognizer-picker"); mkdirSync(root, { recursive: true }); process.env.VOICELAYER_STATE_DIR = root; delete process.env.QA_VOICE_STT_BACKEND;
  try { unlinkSync(recognizerSettingsPath()); } catch {}
  configureRecognizerBusyProbe(() => null); confirmRecognizerCleanup("parakeet"); confirmRecognizerCleanup("whisper"); setRecognizerRecoveryWhisper(null); noteRecognizerEngine("parakeet", { phase: "sleeping", available: null, error: null });
  noteRecognizerEngine("whisper", { phase: "sleeping", available: null, error: null }); noteRecognizerEffective(null);
});
afterEach(() => {
  configureRecognizerBusyProbe(() => null);
  if (saved.state === undefined) delete process.env.VOICELAYER_STATE_DIR; else process.env.VOICELAYER_STATE_DIR = saved.state;
  if (saved.backend === undefined) delete process.env.QA_VOICE_STT_BACKEND; else process.env.QA_VOICE_STT_BACKEND = saved.backend;
});
function ops() { const calls: string[] = []; const deps: RecognizerTransitionDeps = { stopP: async () => { calls.push("stopP"); }, stopW: async () => { calls.push("stopW"); }, startP: async () => { calls.push("startP"); }, startW: async () => { calls.push("startW"); }, reset: () => { calls.push("reset"); } }; return { calls, deps }; }
test("published commands parse exactly, not arbitrary engine/field aliases", () => {
  expect(parseCommand('{"cmd":"set_recognizer","recognizer":"parakeet","id":"x"}')).toEqual({ cmd: "set_recognizer", recognizer: "parakeet", id: "x" });
  expect(parseCommand('{"cmd":"set_recognizer","recognizer":"whisper"}')).toEqual({ cmd: "set_recognizer", recognizer: "whisper" });
  expect(parseCommand('{"cmd":"get_recognizer_status","id":"q"}')).toEqual({ cmd: "get_recognizer_status", id: "q" });
  expect(parseCommand('{"cmd":"set_recognizer","recognizer":"auto"}')).toBeNull();
});
test("status reads never invoke a model or change readiness", async () => {
  const before = readRecognizerStatus();
  const r = await handleSocketCommand({ cmd: "get_recognizer_status", id: "status-only" });
  expect(r).toMatchObject({ type: "recognizer_status", id: "status-only", recognizer_status: { desired: "whisper", effective: null, phase: "sleeping" } });
  expect(readRecognizerStatus().revision).toBe(before.revision);
});
test("actual selection command echoes identity and refuses the active request before provider code", async () => {
  beginRecognizerRequest();
  try {
    expect(await handleSocketCommand({ cmd: "set_recognizer", recognizer: "parakeet", id: "busy-wire" })).toMatchObject({
      type: "ack", command: "set_recognizer", id: "busy-wire", outcome: "reject", reason: "request-active",
      recognizer_status: { switch_allowed: false, switch_refusal_reason: "request-active" },
    });
  } finally { finishRecognizerRequest(); }
});
test("one switch confirms old cleanup, persists desired, loads one target and acks current readiness", async () => {
  const { calls, deps } = ops(); const states: ReturnType<typeof readRecognizerStatus>[] = [];
  const off = onRecognizerStatusChange(s => states.push(s));
  try {
    const r = await selectRecognizer("parakeet", deps);
    expect(calls).toEqual(["stopP", "stopW", "startP", "reset"]); expect(r.outcome).toBe("accept");
    expect(r.recognizer_status).toMatchObject({ desired: "parakeet", effective: "parakeet", phase: "ready", switch_allowed: true });
    expect(JSON.parse(readFileSync(recognizerSettingsPath(), "utf8"))).toEqual({ version: 1, recognizer: "parakeet" });
    expect(states.some(s => s.desired === "parakeet" && s.phase === "loading")).toBe(true);
    expect(states.at(-1)?.revision).toBe(r.recognizer_status.revision);
    expect(states.every((s, i) => i === 0 || s.revision > states[i - 1]!.revision)).toBe(true);
  } finally { off(); }
});
for (const reason of ["capture-active", "voice-busy"]) test(`busy ${reason} refuses before any effects or preference write`, async () => {
  const { calls, deps } = ops(); configureRecognizerBusyProbe(() => reason);
  expect(await selectRecognizer("parakeet", deps)).toMatchObject({ outcome: "reject", reason });
  expect(calls).toEqual([]); expect(existsSync(recognizerSettingsPath())).toBe(false);
});
test("active request and transition refuse a switch without gap stealing", async () => {
  const { calls, deps } = ops(); beginRecognizerRequest();
  try { expect(await selectRecognizer("parakeet", deps)).toMatchObject({ outcome: "reject", reason: "request-active" }); }
  finally { finishRecognizerRequest(); }
  const held = Promise.withResolvers<void>(); deps.stopP = async () => { await held.promise; };
  const first = selectRecognizer("parakeet", deps);
  expect(await selectRecognizer("whisper", deps)).toMatchObject({ outcome: "reject", reason: "transition-active" });
  expect(() => beginRecognizerRequest()).toThrow("transition active"); held.resolve(); expect((await first).outcome).toBe("accept");
});
test("environment override refuses persist and model changes", async () => {
  process.env.QA_VOICE_STT_BACKEND = "parakeet"; const { calls, deps } = ops();
  expect(await selectRecognizer("whisper", deps)).toMatchObject({ outcome: "reject", reason: "environment-override" }); expect(calls).toEqual([]);
});
test("cleanup UNKNOWN neither changes preference nor starts a new model", async () => {
  const { calls, deps } = ops(); deps.stopW = async () => { throw new Error("foreign owner"); };
  expect(await selectRecognizer("parakeet", deps)).toMatchObject({ outcome: "reject", reason: "cleanup-unconfirmed" });
  expect(calls).toEqual(["stopP"]); expect(existsSync(recognizerSettingsPath())).toBe(false);
  expect(readRecognizerStatus()).toMatchObject({ switch_allowed: false, switch_refusal_reason: "cleanup-unconfirmed" });
  expect(() => beginRecognizerRequest()).toThrow("cleanup unconfirmed");
});
test("failed P loading preserves desired P while real W recovery is separately effective", async () => {
  const { calls, deps } = ops(); deps.startP = async () => { calls.push("startP"); throw new Error("fixture load failure"); };
  const r = await selectRecognizer("parakeet", deps);
  expect(calls).toEqual(["stopP", "stopW", "startP", "stopP", "startW", "reset"]);
  expect(r.recognizer_status).toMatchObject({ desired: "parakeet", effective: "whisper", phase: "ready", fallback_reason: "parakeet-startup-failed", engines: { parakeet: { phase: "error" } } });
});
test("both failed loads are error, never Ready or a changed desired choice", async () => {
  const { deps } = ops(); deps.startP = deps.startW = async () => { throw new Error("fixture unavailable"); };
  const r = await selectRecognizer("parakeet", deps);
  expect(r.recognizer_status).toMatchObject({ desired: "parakeet", effective: null, phase: "error" });
});
test("failed W selection restores previous P and the actual backend reuses it with provenance", async () => {
  await selectRecognizer("parakeet", ops().deps);
  const { calls, deps } = ops(); deps.startW = async () => { calls.push("startW"); throw new Error("fixture W load failure"); };
  const selected = await selectRecognizer("whisper", deps);
  expect(calls).toEqual(["stopP", "stopW", "startW", "stopW", "startP", "reset"]);
  expect(selected.recognizer_status).toMatchObject({ desired: "whisper", effective: "parakeet", phase: "ready", fallback_reason: "whisper-startup-failed", engines: { whisper: { phase: "error" } } });
  expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "restored-P-legacy" })).toMatchObject({ outcome: "reject", reason: "select-whisper-first" });
  const recovery = recognizerRecovery()!; expect(recovery.engine).toBe("parakeet");
  expect(JSON.parse(readFileSync(recovery.evidencePath!, "utf8"))).toMatchObject({ requested: "whisper", previousEffective: "parakeet", reason: "whisper-startup-failed" });
  const stt = await import("../stt"); const { parakeetServer } = await import("../parakeet-server");
  const p = spyOn(parakeetServer, "transcribe").mockImplementation(async path => ({ text: "Actual previous engine.", complete: true, input_frames: 16000, covered_frames: 16000, sample_rate: 16000, last_token_end_s: 1, inference_s: 0, language: null }));
  const w = spyOn(stt.WhisperServerBackend.prototype, "transcribe").mockRejectedValue(new Error("Unexpected second engine"));
  const cli = spyOn(stt.WhisperCppBackend.prototype, "transcribe").mockRejectedValue(new Error("Unexpected second engine"));
  const b = Buffer.alloc(32044); b.write("RIFF"); b.writeUInt32LE(32036,4); b.write("WAVEfmt ",8); b.writeUInt32LE(16,16); b.writeUInt16LE(1,20); b.writeUInt16LE(1,22); b.writeUInt32LE(16000,24); b.writeUInt32LE(32000,28); b.writeUInt16LE(2,32); b.writeUInt16LE(16,34); b.write("data",36); b.writeUInt32LE(32000,40); b.writeInt16LE(1,44);
  const path = testTmp("recognizer-picker", "restored.wav"); writeFileSync(path,b);
  try { stt.resetBackendCache(); const result = await (await stt.getBackend()).transcribe(path, { language: "he" });
    expect(result.backend).toBe("whisper-server+fallback-whisper-startup-failed->parakeet-resident"); expect(p).toHaveBeenCalledTimes(1); expect(w).not.toHaveBeenCalled(); expect(cli).not.toHaveBeenCalled();
  } finally { p.mockRestore(); w.mockRestore(); cli.mockRestore(); stt.resetBackendCache(); setRecognizerRecoveryWhisper(null); }
});

test("post-startup cleanup failure retains a dedicated barrier and stable reason", async () => {
  const { deps } = ops(); let stops = 0;
  deps.stopP = async () => { if (++stops === 2) throw new Error("Owned child did not stop raw detail"); };
  deps.startP = async () => { throw new Error("failed load"); };
  const r = await selectRecognizer("parakeet", deps);
  expect(r).toMatchObject({ outcome: "reject", reason: "cleanup-unconfirmed", recognizer_status: { switch_allowed: false } });
  noteRecognizerEngine("parakeet", { phase: "error", error: "some later display error" });
  expect(() => beginRecognizerRequest()).toThrow("cleanup unconfirmed");
});
test("legacy maintenance admitted first excludes picker before any cleanup/load", async () => {
  const { calls, deps } = ops(); beginRecognizerMaintenance();
  try { expect(await selectRecognizer("parakeet", deps)).toMatchObject({ outcome: "reject", reason: "transition-active" }); expect(calls).toEqual([]); }
  finally { finishRecognizerTransition(); }
});
test("actual pending legacy load excludes the picker before a launch record exists", async () => {
  const server = await import("../whisper-server"); const model = await import("../model-status");
  const held = Promise.withResolvers<number>();
  const start = spyOn(server, "ensureServer").mockReturnValue(held.promise);
  const status = spyOn(model, "readWhisperModelStatus").mockResolvedValue({ residency: "unknown" } as any);
  const record = spyOn(server, "verifiedWhisperServerLaunchRecord").mockReturnValue(null);
  const pending = handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "held-legacy" });
  try {
    expect(start).toHaveBeenCalledTimes(1);
    const { calls, deps } = ops();
    expect(await selectRecognizer("parakeet", deps)).toMatchObject({ outcome: "reject", reason: "transition-active" });
    expect(calls).toEqual([]); expect(() => beginRecognizerRequest()).toThrow("transition active");
  } finally { held.resolve(8178); await pending; start.mockRestore(); status.mockRestore(); record.mockRestore(); }
});
test("capture arriving during old cleanup wins before persistence or successor load", async () => {
  const { calls, deps } = ops(); const held = Promise.withResolvers<void>();
  deps.stopP = async () => { calls.push("stopP"); await held.promise; };
  const pending = selectRecognizer("whisper", deps); configureRecognizerBusyProbe(() => "capture-active"); held.resolve();
  expect(await pending).toMatchObject({ outcome: "reject", reason: "capture-active" });
  expect(calls).toEqual(["stopP"]); expect(existsSync(recognizerSettingsPath())).toBe(false);
});
test("getBackend reuses the resident recovery provider instead of allocating P or a W CLI", async () => {
  const stt = await import("../stt"); const { parakeetServer } = await import("../parakeet-server");
  process.env.QA_VOICE_STT_BACKEND = "parakeet"; setRecognizerRecoveryWhisper({ attempt: { code: "startup-failed" } }); stt.resetBackendCache();
  const w = spyOn(stt.WhisperServerBackend.prototype, "transcribe").mockResolvedValue({ text: "Resident recovery response.", backend: "whisper-server", durationMs: 1 });
  const cli = spyOn(stt.WhisperCppBackend.prototype, "transcribe").mockRejectedValue(new Error("Unexpected second W"));
  const p = spyOn(parakeetServer, "transcribe").mockRejectedValue(new Error("Unexpected P allocation"));
  const stop = spyOn(parakeetServer, "unload").mockResolvedValue(undefined);
  const b = Buffer.alloc(32044);b.write("RIFF");b.writeUInt32LE(32036,4);b.write("WAVEfmt ",8);b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(1,22);b.writeUInt32LE(16000,24);b.writeUInt32LE(32000,28);b.writeUInt16LE(2,32);b.writeUInt16LE(16,34);b.write("data",36);b.writeUInt32LE(32000,40);b.writeInt16LE(1,44);
  const path=testTmp("recognizer-picker","recovery.wav");writeFileSync(path,b);
  try { const result=await (await stt.getBackend()).transcribe(path,{language:"en"});expect(result.backend).toContain("fallback-parakeet-startup-failed->whisper-server");expect(w).toHaveBeenCalledTimes(1);expect(cli).not.toHaveBeenCalled();expect(p).not.toHaveBeenCalled(); }
  finally { w.mockRestore();cli.mockRestore();p.mockRestore();stop.mockRestore();stt.resetBackendCache();setRecognizerRecoveryWhisper(null); }
});
