import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { recordingStateFilePath } from "../paths";
import {
  createConversationCapturePolicy as create, requestConversationCaptureStop as stop,
  runRegisteredConversationCapture as run, waitForConversationCaptureSafety as wait,
  type ConversationCapturePolicy,
} from "../conversation-capture-lifecycle";

const deferred = () => Promise.withResolvers<void>();
const turn = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
let sequence = 0;
const stateModule = () => import(`../recording-state.ts?capture-test=${++sequence}`);
const fileState = () => JSON.parse(readFileSync(recordingStateFilePath(), "utf8"));
const originalPath = process.env.QA_VOICE_RECORDING_STATE_PATH;
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const root = process.env.VOICELAYER_TEST_RUN_ROOT!;
  expect(root.startsWith(join(process.cwd(), ".test-tmp/"))).toBe(true);
  process.env.QA_VOICE_RECORDING_STATE_PATH = join(root, "capture-state.json");
});
afterEach(() => {
  if (originalPath === undefined) delete process.env.QA_VOICE_RECORDING_STATE_PATH;
  else process.env.QA_VOICE_RECORDING_STATE_PATH = originalPath;
});
async function pending(policy: ConversationCapturePolicy) {
  let settled = false;
  void wait(policy).then(() => { settled = true; });
  await turn();
  expect(settled).toBe(false);
}

test("fresh frozen identity rejects structural, cloned and replaced-completion authority", async () => {
  const policy = create(), state = await stateModule();
  expect(Object.isFrozen(policy)).toBe(true);
  expect(Reflect.ownKeys(policy)).toEqual([]);
  expect(Reflect.set(policy, "safety", Promise.resolve({ kind: "not-started" }))).toBe(false);
  expect(wait(policy)).toBe(wait(policy));
  expect(Reflect.set(wait(policy), "then", () => Promise.resolve())).toBe(false);
  stop(policy);
  await pending(policy);
  const forged = { safety: Promise.resolve({ kind: "not-started", generation: 7 }) };
  for (const value of [forged, Object.freeze({ ...policy }), Object.create(policy), Promise.resolve(forged)]) {
    // Intentionally bypass static typing to exercise every runtime consumer.
    const invalid = value as ConversationCapturePolicy;
    expect(() => wait(invalid)).toThrow("Unissued");
    expect(() => stop(invalid)).toThrow("Unissued");
    expect(() => state.holdConversationCaptureUntil(invalid)).toThrow("Unissued");
    await expect(run(invalid, async () => undefined)).rejects.toThrow("Unissued");
  }
  await pending(policy);
});

test("one registration owns pending setup and cleanup; returned reports have no authority", async () => {
  const policy = create(), foreign = create(), setup = deferred(), cleanup = deferred();
  let late = () => {}, cleanupStarted = false;
  const safety = wait(policy);
  const operation = run(policy, async (owner) => {
    expect("startChild" in owner).toBe(true);
    late = () => owner.ownSetupCleanup(async () => {});
    owner.ownSetupCleanup(async () => { cleanupStarted = true; await cleanup.promise; });
    await setup.promise;
    return { kind: "not-started", generation: 7 };
  });
  await expect(run(policy, async () => "duplicate")).rejects.toThrow("already registered");
  stop(policy);
  await pending(policy);
  expect(cleanupStarted).toBe(false);
  setup.resolve();
  await turn();
  expect(cleanupStarted).toBe(true);
  expect(late).toThrow("closed");
  await pending(policy);
  cleanup.resolve();
  expect(await operation).toEqual({ kind: "not-started", generation: 7 });
  const report = await safety;
  expect(Object.isFrozen(report)).toBe(true);
  expect(Reflect.set(report, "generation", -1)).toBe(false);
  expect(await wait(policy)).toBe(report);
  await expect(run(policy, async () => "reuse")).rejects.toThrow("already registered");
  await pending(foreign);
  await run(foreign, async () => report);
  expect((await wait(foreign)).generation).not.toBe(report.generation);
});

test("setup rejection cannot release before owned cleanup completes", async () => {
  const policy = create(), setup = deferred(), cleanup = deferred();
  const operation = run(policy, async (owner) => {
    owner.ownSetupCleanup(() => cleanup.promise);
    await setup.promise;
    throw new Error("setup failure");
  });
  const rejection = operation.catch((error) => error);
  setup.resolve();
  await pending(policy);
  cleanup.resolve();
  expect(await rejection).toEqual(new Error("setup failure"));
  expect((await wait(policy)).kind).toBe("not-started");
});

for (const synchronous of [true, false]) test(`cleanup failure retains fence and joins all cleanup: sync=${synchronous}`, async () => {
  const policy = create(), cleanup = deferred(), state = await stateModule();
  state.setRecordingState("recording");
  state.holdConversationCaptureUntil(policy);
  state.setRecordingState("idle");
  let finished = false, late = () => {};
  const operation = run(policy, async (owner) => {
    late = () => owner.ownSetupCleanup(async () => {});
    owner.ownSetupCleanup(() => { if (synchronous) throw Error("cleanup failure"); return Promise.reject(Error("cleanup failure")); });
    owner.ownSetupCleanup(() => cleanup.promise);
  });
  const rejection = operation.catch((error) => error);
  void operation.then(() => { finished = true; }, () => { finished = true; });
  await turn();
  expect(finished).toBe(false);
  expect(late).toThrow("closed");
  cleanup.resolve();
  expect(await rejection).toEqual(new Error("cleanup failure"));
  await pending(policy);
  expect(state.getRecordingState()).toBe("recording");
  expect(state.getEffectiveRecordingState()).toBe("recording");
  expect(fileState().state).toBe("recording");
});

test("synchronous setup failure retains every cleanup failure without minting safety", async () => {
  const policy = create(), cleanup = deferred();
  const operation = run(policy, (owner) => {
    owner.ownSetupCleanup(async () => { throw Error("cleanup one"); });
    owner.ownSetupCleanup(async () => { await cleanup.promise; throw Error("cleanup two"); });
    throw Error("setup failure");
  });
  const rejection = operation.catch((error) => error);
  await pending(policy);
  cleanup.resolve();
  const error = await rejection;
  expect(error).toBeInstanceOf(AggregateError);
  expect(error.errors.map((cause: Error) => cause.message)).toEqual(["setup failure", "cleanup one", "cleanup two"]);
  await pending(policy);
});

test("issued fence defers idle once; stale holds cannot clear a newer owner", async () => {
  const state = await stateModule(), policy = create(), next = create(), setup = deferred();
  const seen: string[] = [];
  const unsubscribe = state.onRecordingStateChange((value: string) => seen.push(value));
  state.setRecordingState("recording");
  state.holdConversationCaptureUntil(policy);
  const before = readFileSync(recordingStateFilePath(), "utf8");
  state.setRecordingState("idle");
  state.setRecordingState("idle");
  expect(state.getRecordingState()).toBe("recording");
  expect(state.getEffectiveRecordingState()).toBe("recording");
  expect(readFileSync(recordingStateFilePath(), "utf8")).toBe(before);
  expect(seen).toEqual(["recording"]);
  expect(() => state.holdConversationCaptureUntil(policy)).toThrow("already held");
  expect(() => state.holdConversationCaptureUntil(next)).toThrow("already held");
  expect(() => state.holdConversationCaptureUntil({ safety: Promise.resolve() } as unknown as ConversationCapturePolicy)).toThrow("Unissued");
  const operation = run(policy, async () => setup.promise);
  await pending(policy);
  setup.resolve();
  await operation;
  await turn();
  expect(seen).toEqual(["recording", "idle"]);
  expect(fileState().state).toBe("idle");
  state.holdConversationCaptureUntil(next);
  expect(state.getRecordingState()).toBe("transcribing");
  expect(state.getEffectiveRecordingState()).toBe("transcribing");
  expect(() => state.holdConversationCaptureUntil(policy)).toThrow("already held");
  await wait(policy);
  state.setRecordingState("idle");
  state.setRecordingState("recording");
  await run(next, async () => undefined);
  await turn();
  expect(state.getRecordingState()).toBe("recording");
  expect(seen).toEqual(["recording", "idle", "transcribing", "recording"]);
  expect(() => state.holdConversationCaptureUntil(next)).toThrow("already held");
  unsubscribe();
});

test("observer handoff cannot persist an old idle over a newly acquired fence", async () => {
  const state = await stateModule(), policy = create(), next = create(), seen: string[] = [];
  let handedOff = false;
  state.onRecordingStateChange((value: string) => {
    if (value === "idle" && !handedOff) {
      handedOff = true;
      state.holdConversationCaptureUntil(next);
    }
  });
  state.onRecordingStateChange(value => seen.push(`${value}:${state.getRecordingState()}`));
  state.setRecordingState("recording");
  state.holdConversationCaptureUntil(policy);
  state.setRecordingState("idle");
  await run(policy, async () => undefined);
  await turn();
  expect(state.getRecordingState()).toBe("transcribing");
  expect(fileState().state).toBe("transcribing");
  expect(seen).toEqual(["recording:recording", "transcribing:transcribing"]);
  state.setRecordingState("idle");
  await run(next, async () => undefined);
  await turn();
  expect(state.getEffectiveRecordingState()).toBe("idle");
  expect(seen).toEqual(["recording:recording", "transcribing:transcribing", "idle:idle"]);
});

test("absence-policy legacy transitions persist and notify unchanged", async () => {
  const state = await stateModule(), seen: string[] = [];
  state.onRecordingStateChange((value: string) => seen.push(value));
  for (const value of ["idle", "recording", "transcribing", "idle"] as const) {
    state.setRecordingState(value);
    expect(state.getRecordingState()).toBe(value);
    expect(state.getEffectiveRecordingState()).toBe(value);
    expect(fileState()).toMatchObject({ state: value, pid: process.pid });
    expect(Number.isNaN(Date.parse(fileState().updated_at))).toBe(false);
  }
  expect(seen).toEqual(["idle", "recording", "transcribing", "idle"]);
});

test("actual compiler accepts issued handles and rejects the R2 release counterexample", () => {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT!;
  const imports = `import { createConversationCapturePolicy as create, runRegisteredConversationCapture as run, waitForConversationCaptureSafety as wait, type ConversationCapturePolicy } from ${JSON.stringify(resolve("src/conversation-capture-lifecycle"))};
import { holdConversationCaptureUntil as hold } from ${JSON.stringify(resolve("src/recording-state"))};\n`;
  const sources = [
    imports + `const policy = create(); hold(policy); void wait(policy);
void run(policy, async owner => { owner.ownSetupCleanup(async () => {}); });`,
    imports + `const premature: ConversationCapturePolicy = { safety: Promise.resolve({ kind: "not-started", generation: 7 }) };
hold(Promise.resolve({ kind: "not-started", generation: 7 }));
hold({ kind: "not-started", generation: 7 });
void wait(create()).then(report => { report.generation = 7; });`,
  ];
  for (const [index, source] of sources.entries()) {
    const fixture = join(root, `capture-types-${index}.ts`);
    writeFileSync(fixture, source);
    const argv = [process.execPath, resolve("node_modules/typescript/bin/tsc"), "--noEmit", "--strict", "--skipLibCheck", "--target", "esnext", "--module", "esnext", "--moduleResolution", "bundler", "--types", "bun-types", "--esModuleInterop", fixture];
    const result = Bun.spawnSync(argv, { env: process.env, stdout: "pipe", stderr: "pipe" });
    const output = result.stdout.toString() + result.stderr.toString();
    console.log("COMPILER_FIXTURE", JSON.stringify({ argv, exit: result.exitCode, output, source }));
    if (index === 0) { expect(output).toBe(""); expect(result.exitCode).toBe(0); }
    else {
      expect(result.exitCode).toBe(2);
      expect(output.match(/error TS/g)?.length).toBe(4);
      for (const code of ["TS2353", "TS2345", "TS2540"]) expect(output).toContain(code);
    }
  }
});

for (const reuse of [false, true]) test(`failed fence publish rolls back; reuse same policy=${reuse}`, async () => {
  const state = await stateModule(), policy = create(), seen: string[] = [];
  state.setRecordingState("idle");
  state.onRecordingStateChange(value => seen.push(value));
  const writable = recordingStateFilePath(), link = `${writable}.link-${reuse}`;
  symlinkSync(writable, link);
  process.env.QA_VOICE_RECORDING_STATE_PATH = link;
  try {
    expect(() => state.holdConversationCaptureUntil(policy)).toThrow("Unable to publish recording state (transcribing)");
  } finally {
    process.env.QA_VOICE_RECORDING_STATE_PATH = writable;
  }
  expect(state.getRecordingState()).toBe("idle");
  expect(state.getEffectiveRecordingState()).toBe("idle");
  state.setRecordingState("idle");
  expect(seen).toEqual(["idle"]);
  // Failed admission does not consume the policy; both it and a fresh policy may acquire.
  const next = reuse ? policy : create();
  expect(() => state.holdConversationCaptureUntil(next)).not.toThrow();
  state.setRecordingState("idle");
  await run(policy, async () => undefined);
  await turn();
  if (!reuse) {
    expect(state.getRecordingState()).toBe("transcribing");
    expect(() => state.holdConversationCaptureUntil(create())).toThrow("already held");
    await run(next, async () => undefined);
    await turn();
  }
  expect(state.getRecordingState()).toBe("idle");
});
