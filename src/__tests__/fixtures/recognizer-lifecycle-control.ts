import { spyOn } from "bun:test";
import assert from "node:assert/strict";
import { mkdirSync } from "node:fs";
import { testTmp } from "../setup/test-tmp";

const scenario = process.argv[2]!;
const root = testTmp("recognizer-lifecycle", scenario);
mkdirSync(root, { recursive: true });
process.env.VOICELAYER_STATE_DIR = root;
process.env.VOICELAYER_WHISPER_OWNERSHIP_DIR = root;
process.env.QA_VOICE_WHISPER_SERVER_PORT = "19143";
process.env.QA_VOICE_WHISPER_ACCELERATION = "metal";
delete process.env.QA_VOICE_STT_BACKEND;
const state = await import("../../recognizer-state");
const stt = await import("../../stt");
const controller = await import("../../recognizer-controller");
const server = await import("../../whisper-server");
const { handleSocketCommand } = await import("../../socket-handlers");
state.configureRecognizerBusyProbe(() => null);
const model = await import("../../model-status");
spyOn(model, "readWhisperModelStatus").mockResolvedValue({ residency: "unknown" } as Awaited<ReturnType<typeof model.readWhisperModelStatus>>);
spyOn(globalThis, "fetch").mockImplementation(Object.assign(() => { throw new Error("Unexpected real network probe"); }, { preconnect: () => {} }));
const tick = async () => { for (let n = 0; n < 40; n++) await Promise.resolve(); };

if (scenario.startsWith("wispr-failure")) {
  process.env.QA_VOICE_STT_BACKEND = "wispr";
  stt.WisprFlowBackend.prototype.isAvailable = async () => true;
  let fail = true;
  stt.WisprFlowBackend.prototype.transcribe = async () => {
    if (fail) throw new Error("synthetic cloud refusal");
    return { text: "retained words", backend: "wispr-flow", durationMs: 0 };
  };
  if (scenario === "wispr-failure-resident") {
    state.noteRecognizerEngine("whisper", { phase: "ready", available: true, error: null });
    state.noteRecognizerEffective("whisper");
  }
  const backend = await stt.getBackend();
  const before = state.readRecognizerStatus();
  await assert.rejects(backend.transcribe("synthetic-no-file"), /synthetic cloud refusal/);
  assert.deepEqual(state.readRecognizerStatus().engines, before.engines, "a cloud refusal must not change local-engine lifecycle");
  fail = false;
  assert.equal((await backend.transcribe("synthetic-no-file")).backend, "wispr-flow");
  assert.deepEqual(state.readRecognizerStatus().engines, before.engines, "cloud recovery must not retain a false local error");
} else if (scenario === "whisper-failure-status") {
  process.env.QA_VOICE_STT_BACKEND = "whisper";
  stt.WhisperCppBackend.prototype.isAvailable = async () => true;
  stt.WhisperCppBackend.prototype.transcribe = async () => { throw new Error("synthetic local refusal"); };
  const backend = await stt.getBackend();
  await assert.rejects(backend.transcribe("synthetic-no-file"), /synthetic local refusal/);
  assert.equal(state.readRecognizerStatus().engines.whisper.error, "transcription-failed");
  assert.equal(state.readRecognizerStatus().engines.whisper.phase, "error");
} else if (scenario === "cli-only-sleeping") {
  process.env.QA_VOICE_STT_BACKEND = "whisper";
  stt.WhisperCppBackend.prototype.isAvailable = async () => true;
  stt.WhisperCppBackend.prototype.transcribe = async () => ({ text: "retained words", backend: "whisper.cpp", durationMs: 0 });
  const backend = await stt.getBackend();
  await backend.transcribe("synthetic-no-file");
  assert.equal(state.readRecognizerStatus().engines.whisper.phase, "sleeping");
  assert.equal(server.whisperServerLaunchRecord(), null);
} else if (scenario.startsWith("capture") || scenario === "picker-refusal") {
  let providers = 0;
  stt.WhisperServerBackend.prototype.isAvailable = async () => true;
  stt.WhisperServerBackend.prototype.transcribe = async () => { providers++; return { text: "all retained words", backend: "whisper-server", durationMs: 0 }; };
  const held = Promise.withResolvers<number>();
  // The actual handler holds maintenance, while an independently admitted
  // recording reaches the actual observed-backend wrapper (no microphone).
  spyOn(server, "ensureServer").mockImplementation(() => held.promise);
  const maintenance = handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "short-capture" });
  const backend = await stt.getBackend();
  const abort = new AbortController();
  let settled = false;
  const result = backend.transcribe("synthetic-no-file", { signal: abort.signal }).then(value => ({ value }), error => ({ error })).finally(() => { settled = true; });
  await tick();
  if (scenario === "capture-cancel") {
    abort.abort(); await tick();
    assert.equal(settled, true, "cancelled maintenance waiter must settle before maintenance");
    assert.equal(providers, 0);
  } else if (scenario === "picker-refusal") {
    // Request admission during picker changes remains strict.
    held.resolve(19143); await maintenance; await result;
    state.beginRecognizerTransition();
    await assert.rejects(backend.transcribe("synthetic"), /transition active/);
    state.finishRecognizerTransition();
    console.log(`PASS ${scenario}`); process.exit(0);
  } else {
    assert.equal(settled, false, "completed capture must wait, not fail during legacy load");
    assert.equal(providers, 0);
    assert.throws(() => state.beginRecognizerRequest(), /transition active/);
  }
  if (scenario === "capture-cleanup") state.markRecognizerCleanupUnconfirmed("whisper");
  held.resolve(19143); await maintenance;
  const terminal = await result;
  if (scenario === "capture-cancel" || scenario === "capture-cleanup") { assert.ok("error" in terminal); assert.equal(providers, 0); }
  else { assert.ok("value" in terminal); assert.equal(terminal.value.text, "all retained words"); assert.equal(providers, 1); }
  // Cancellation/accounting must not strand maintenance or picker admission.
  if (scenario === "capture-cleanup") { assert.throws(() => state.beginRecognizerRequest(), /cleanup unconfirmed/); state.confirmRecognizerCleanup("whisper"); }
  state.beginRecognizerMaintenance(); state.finishRecognizerTransition();
} else if (scenario.startsWith("shutdown-picker")) {
  const started = Promise.withResolvers<void>(), cleanup = Promise.withResolvers<void>();
  const trace: string[] = [];
  const p = await import("../../parakeet-server");
  const pickerTargets = {
    "shutdown-picker-p": "parakeet", "shutdown-picker-w": "whisper", "shutdown-picker-p-unknown": "parakeet",
  } as const;
  const desired = pickerTargets[scenario as keyof typeof pickerTargets];
  assert.ok(desired, "every picker scenario must name its target explicitly");
  // Initial previous provider gives restoration a concrete opposite engine.
  state.noteRecognizerEffective(desired === "parakeet" ? "whisper" : "parakeet");
  const deps = {
    assetsPresent: () => true, // Explicit fake prerequisite; never inspect real weights.
    stopP: async () => { trace.push("stopP"); }, stopW: async () => { trace.push("stopW"); },
    startP: async () => { trace.push("startP"); if (desired === "parakeet") { started.resolve(); await new Promise((_, reject) => p.parakeetOwnerShutdownSignal.addEventListener("abort", () => reject(new Error("owner closed")), { once: true })); } },
    startW: async () => { trace.push("startW"); if (desired === "whisper") { started.resolve(); await new Promise((_, reject) => p.parakeetOwnerShutdownSignal.addEventListener("abort", () => reject(new Error("owner closed")), { once: true })); } },
    reset: () => {},
  };
  const selected = controller.selectRecognizer(desired, deps); await started.promise;
  // Owned cleanup after target cancellation must be part of the barrier.
  if (desired === "parakeet") deps.stopP = async () => { trace.push("owned-cleanup"); await cleanup.promise; if (scenario.endsWith("-unknown")) throw new Error("owned exit UNKNOWN"); };
  else deps.stopW = async () => { trace.push("owned-cleanup"); await cleanup.promise; if (scenario.endsWith("-unknown")) throw new Error("owned exit UNKNOWN"); };
  let done = false;
  const stopped = stt.shutdownSTTBackends().then(() => { done = true; return null; }, error => { done = true; return error as Error; });
  await tick();
  assert.equal(done, false, "shutdown must join picker cleanup");
  assert.equal(state.readRecognizerStatus().switch_allowed, false);
  cleanup.resolve(); const stopError = await stopped; const result = await selected;
  if (scenario.endsWith("-unknown")) { assert.equal(stopError?.message, "cleanup-unconfirmed"); assert.equal(result.reason, "cleanup-unconfirmed"); }
  else { assert.equal(stopError, null); assert.equal(result.reason, "owner-shutdown"); }
  assert.equal(result.outcome, "reject");
  assert.equal(trace.filter(x => x === "startW").length, desired === "whisper" ? 1 : 0, "no post-close restoration");
  assert.equal(trace.filter(x => x === "startP").length, desired === "parakeet" ? 1 : 0);
  assert.deepEqual(trace.slice(0, 3), ["stopP", "stopW", desired === "parakeet" ? "startP" : "startW"]);
  console.log(JSON.stringify({ scenario, target: desired, startP: trace.filter(x => x === "startP").length,
    startW: trace.filter(x => x === "startW").length, shutdownPendingBeforeCleanup: true }));
  assert.notEqual(state.readRecognizerStatus().phase, "ready");
  assert.throws(() => state.beginRecognizerRequest(), /shut down/);
  assert.throws(() => state.beginRecognizerMaintenance(), /owner-shutdown/);
} else if (scenario === "shutdown-adopted") {
  let signals = 0;
  server.__resetWhisperServerStateForTests({ proc: null, port: 19143, pid: 41003, adopted: true });
  server.__setWhisperServerTestHooksForTests({ killExternalPid: () => { signals++; } });
  await stt.shutdownSTTBackends(); assert.equal(signals, 0);
  assert.equal(server.whisperServerLaunchRecord(), null);
} else {
  // Actual Whisper producer, fake process with a controlled terminal promise.
  // No real binary/help/model/network/probe is invoked.
  const resolver = await import("../../resolve-binary");
  spyOn(resolver, "resolveBinary").mockReturnValue(null);
  spyOn(Bun, "spawn").mockImplementation(() => { throw new Error("Unexpected real subprocess"); });
  spyOn(Bun, "spawnSync").mockImplementation(() => { throw new Error("Unexpected real subprocess"); });
  let healthy = false, currentPid = 41001;
  const exits = new Map<number, ReturnType<typeof Promise.withResolvers<number>>>();
  const spawned = Promise.withResolvers<void>(), cleanup = Promise.withResolvers<void>();
  let kills = 0;
  server.__setWhisperServerTestHooksForTests({
    findServerBinary: () => root + "/whisper-server", findModel: () => root + "/fake-model.bin",
    readHelpText: () => ({ helpText: "" }), findExternalWhisperServerPids: () => [],
    findPortListenerPids: () => healthy ? [currentPid] : [], residentLiveStack: () => false,
    isServerHealthy: async () => healthy,
    spawn: () => {
      const pid = currentPid, exit = Promise.withResolvers<number>(); exits.set(pid, exit);
      if (!scenario.startsWith("shutdown-")) healthy = true;
      spawned.resolve();
      return { pid, exitCode: null, exited: exit.promise, stderr: null, kill: () => { kills++; healthy = false; if (scenario.startsWith("shutdown-")) void cleanup.promise.then(() => exit.resolve(0)); } };
    },
  });
  if (scenario === "shutdown-legacy-w" || scenario === "shutdown-direct-w") {
    const pending = Promise.resolve(scenario === "shutdown-legacy-w"
      ? handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "held-owned-start" })
      : server.ensureServer(19143)).then(value => ({ value }), error => ({ error }));
    await spawned.promise;
    let done = false;
    const stopped = stt.shutdownSTTBackends().then(() => { done = true; }); await tick();
    assert.equal(done, false, "shutdown must join pre-health owned Whisper cleanup");
    assert.ok(kills > 0, "shutdown must cancel the pre-health child");
    cleanup.resolve(); await stopped; await pending;
    assert.equal(server.whisperServerLaunchRecord(), null);
    assert.notEqual(state.readRecognizerStatus().engines.whisper.phase, "ready");
    await assert.rejects(server.ensureServer(), /shut down/);
  } else {
    await server.ensureServer(19143);
    const before = state.readRecognizerStatus(); assert.equal(before.engines.whisper.phase, "ready");
    if (scenario === "resident-cli-fallback") {
      stt.WhisperServerBackend.prototype.isAvailable = async () => true;
      stt.WhisperServerBackend.prototype.transcribe = async () => ({ text: "retained words", backend: "whisper-server+fallback-empty-response->whisper.cpp", durationMs: 0 });
      const backend = await stt.getBackend();
      const result = await backend.transcribe("synthetic-no-file");
      assert.equal(result.text, "retained words");
      assert.equal(server.whisperServerLaunchRecord()?.pid, 41001);
      assert.equal(state.readRecognizerStatus().engines.whisper.phase, "ready", "CLI fallback must not put a still-resident server to sleep");
      assert.equal(state.readRecognizerStatus().fallback_reason, "empty-response");
      console.log(`PASS ${scenario}`); process.exit(0);
    }
    if (scenario === "intentional-exit" || scenario === "late-old-exit") {
      server.stopServer();
      if (scenario === "late-old-exit") { currentPid++; await server.ensureServer(19143); }
    }
    if (scenario === "unexpected-exit") healthy = false;
    const prior = state.readRecognizerStatus(); exits.get(41001)!.resolve(9); await tick();
    const reply = await handleSocketCommand({ cmd: "get_recognizer_status", id: "idle-exit" });
    const after = state.readRecognizerStatus(); assert.equal(state.readRecognizerStatus().revision, after.revision, "status reads remain pure");
    if (scenario === "unexpected-exit") {
      assert.equal(server.whisperServerLaunchRecord(), null);
      assert.equal(after.engines.whisper.phase, "error"); assert.equal(after.engines.whisper.error, "whisper-unexpected-exit");
      assert.ok(after.revision > before.revision); assert.equal(reply?.type, "recognizer_status");
    } else if (scenario === "late-old-exit") {
      assert.equal(server.whisperServerLaunchRecord()?.pid, 41002); assert.equal(after.engines.whisper.phase, "ready"); assert.equal(after.revision, prior.revision);
    } else assert.equal(after.engines.whisper.phase, "sleeping");
  }
}
console.log(`PASS ${scenario}`);
