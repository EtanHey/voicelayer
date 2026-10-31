import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import {
  createConversationCapturePolicy as create, requestConversationCaptureStop as stop,
  runRegisteredConversationCapture as run, waitForConversationCaptureSafety as wait,
  getConversationCaptureObservation as observe,
} from "../conversation-capture-lifecycle";

type Owner = Parameters<Parameters<typeof run>[1]>[0];
type Input = Parameters<Owner["startChild"]>[0];
type Extent = Awaited<ReturnType<Input["readStdout"]>>;
type Format = Awaited<ReturnType<Input["readStderr"]>>;
const deferred = <T>() => Promise.withResolvers<T>();
const turn = async () => { for (let i = 0; i < 32; i++) await Promise.resolve(); };
const format = { sampleRate: 16000, channels: 1 };
const extent = (): Extent => ({ nativeBytes: 4, pcm: new Uint8Array(4), nativeTail: new Uint8Array(), format });
const timers = new Map<ReturnType<typeof setTimeout>, () => void>();
let serial = 0, setTimer: ReturnType<typeof spyOn>, clearTimer: ReturnType<typeof spyOn>;
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  expect(process.env.VOICELAYER_TEST_RUN_ROOT).toStartWith(`${process.cwd()}/.test-tmp/`);
  setTimer = spyOn(globalThis, "setTimeout").mockImplementation((callback, delay) => {
    expect(delay).toBe(300);
    const token = ++serial as unknown as ReturnType<typeof setTimeout>;
    timers.set(token, () => { if (typeof callback === "function") callback(); });
    return token;
  });
  clearTimer = spyOn(globalThis, "clearTimeout").mockImplementation(token => { timers.delete(token!); });
});
afterEach(() => { setTimer.mockRestore(); clearTimer.mockRestore(); expect(timers.size).toBe(0); });
function tick() {
  const [token, callback] = timers.entries().next().value!;
  timers.delete(token);
  callback();
}
async function pending(policy: ReturnType<typeof create>) {
  let safe = false;
  void wait(policy).then(() => { safe = true; });
  await turn();
  expect(safe).toBe(false);
}
function capture(nativeBytes = 4) {
  const policy = create(), exited = deferred<number>(), out = deferred<Extent>(), err = deferred<Format>();
  const setup = deferred<void>(), fence = deferred<void>(), cleanup = deferred<void>();
  void cleanup.promise.catch(() => {}); // Test injection can reject before cleanup is invoked.
  const signals: unknown[] = [];
  const stream = () => new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array(nativeBytes)); controller.close(); } });
  const child = { stdout: stream(), stderr: stream(), exited: exited.promise, kill: (signal: unknown) => { signals.push(signal); } };
  let owner: Owner, spawns = 0;
  const input: Input = {
    spawn: () => { spawns++; return child; },
    readStdout: async seen => { expect(seen).toBe(child); const result = await out.promise; await drain(seen.stdout); return result; },
    readStderr: async seen => { expect(seen).toBe(child); const result = await err.promise; await drain(seen.stderr); return result; },
    fenceProcessing: () => fence.promise,
  };
  const begin = (overrides: Partial<Input> = {}) => run(policy, async value => {
    owner = value;
    owner.ownSetupCleanup(() => cleanup.promise);
    owner.startChild({ ...input, ...overrides });
    await setup.promise;
  }).catch(error => error);
  const settle = () => {
    setup.resolve(); exited.resolve(0); out.resolve(extent());
    err.resolve({ format, stderr: "" }); fence.resolve(); cleanup.resolve();
  };
  return { policy, exited, out, err, setup, fence, cleanup, signals, child, input, begin, settle,
    owner: () => owner, spawns: () => spawns };
}

async function drain(stream: ReadableStream<Uint8Array>) {
  const reader = stream.getReader();
  try { while (!(await reader.read()).done) {} }
  finally { reader.releaseLock(); }
}

test("completed child tasks cannot release a still-pending setup", async () => {
  const c = capture(), operation = c.begin();
  c.exited.resolve(0); c.out.resolve(extent()); c.err.resolve({ format, stderr: "" }); c.fence.resolve(); c.cleanup.resolve();
  await pending(c.policy);
  c.setup.resolve();
  await operation;
  expect((await wait(c.policy)).kind).toBe("complete");
});

for (const exitFirst of [true, false]) test(`independent exit/pipe/format/fence/cleanup join: exitFirst=${exitFirst}`, async () => {
  const c = capture(), operation = c.begin();
  c.setup.resolve();
  if (exitFirst) c.exited.resolve(0); else c.out.resolve(extent());
  await pending(c.policy);
  if (exitFirst) c.out.resolve(extent()); else c.exited.resolve(0);
  await pending(c.policy);
  c.err.resolve({ format, stderr: "terminal watcher output" });
  await pending(c.policy);
  c.fence.resolve();
  await pending(c.policy);
  c.cleanup.resolve();
  expect(await operation).toBeUndefined();
  const report = await wait(c.policy);
  expect(report).toMatchObject({ kind: "complete", exitCode: 0, nativeBytes: 4, normalizedBytes: 4 });
  expect(await wait(c.policy)).toBe(report);
});

test("stop-before-spawn, stale/foreign owner and second attachment refuse before spawn", async () => {
  const c = capture();
  stop(c.policy);
  const stopped = c.begin();
  await pending(c.policy);
  c.settle();
  expect(await stopped).toBeInstanceOf(Error);
  expect(c.spawns()).toBe(0);
  expect((await wait(c.policy)).kind).toBe("not-started");
  const next = capture(), operation = next.begin();
  expect(() => next.owner().startChild(next.input)).toThrow("revoked");
  const method = next.owner().startChild;
  expect(() => method.call(Object.create(next.owner()), next.input)).toThrow();
  next.setup.resolve();
  await turn();
  expect(() => next.owner().startChild(next.input)).toThrow("revoked");
  expect(next.spawns()).toBe(1);
  next.settle();
  await operation;
  expect(() => next.owner().startChild(next.input)).toThrow("revoked");
});

test("pre-attachment spawn throw stays no-child; reentrant stop during spawn binds that child", async () => {
  const c = capture();
  const failed = c.begin({ spawn: () => { throw Error("spawn failure"); } });
  await pending(c.policy);
  c.settle();
  expect(await failed).toEqual(Error("spawn failure"));
  expect((await wait(c.policy)).kind).toBe("not-started");
  const next = capture(), operation = next.begin({ spawn: () => { stop(next.policy); return next.child; } });
  expect(next.signals).toEqual(["SIGTERM"]);
  next.settle();
  await operation;
  expect(timers.size).toBe(0);
});

test("bounded stop is one cycle; late nonzero exit releases only its original generation", async () => {
  const state = await import("../recording-state.ts?child-stop-test"), c = capture(), operation = c.begin();
  state.setRecordingState("recording"); state.holdConversationCaptureUntil(c.policy); state.setRecordingState("idle");
  stop(c.policy); stop(c.policy);
  expect(c.signals).toEqual(["SIGTERM"]);
  tick(); stop(c.policy);
  expect(c.signals).toEqual(["SIGTERM", "SIGKILL"]);
  tick(); stop(c.policy);
  expect(observe(c.policy)).toMatchObject({ stop: "unconfirmed", exit: { kind: "pending" } });
  c.setup.resolve(); c.out.resolve(extent()); c.err.resolve({ format, stderr: "" }); c.fence.resolve(); c.cleanup.resolve();
  await pending(c.policy);
  expect(state.getEffectiveRecordingState()).toBe("recording");
  c.exited.resolve(7);
  expect((await operation).message).toContain("code 7");
  expect(await wait(c.policy)).toMatchObject({ kind: "complete", exitCode: 7 });
  await turn();
  expect(state.getRecordingState()).toBe("idle");
  const next = create(); state.holdConversationCaptureUntil(next); state.setRecordingState("idle");
  stop(c.policy);
  expect(() => c.owner().startChild(c.input)).toThrow("revoked");
  const snapshot = observe(c.policy);
  expect(Reflect.set(snapshot, "exit", { kind: "fulfilled", exitCode: 0 })).toBe(false);
  expect(Reflect.set(snapshot.exit, "exitCode", 0)).toBe(false);
  expect(Reflect.set(snapshot.errors, "0", Error("replacement"))).toBe(false);
  expect(() => observe(Object.create(c.policy))).toThrow("Unissued");
  expect(snapshot.generation).not.toBe(observe(next).generation);
  expect(state.getRecordingState()).toBe("transcribing");
  await run(next, async () => undefined); await turn();
  expect(state.getEffectiveRecordingState()).toBe("idle");
  expect(c.signals).toEqual(["SIGTERM", "SIGKILL"]);
});

for (const failure of ["exit", "stdout", "stderr", "fence", "missing-format", "invalidated", "contradiction", "tail", "partial-frame", "pcm", "locked", "stderr-locked", "missing-pipe", "stderr-missing", "missing-stdout", "startup"]) {
  test(`failed owned observation never mints safety: ${failure}`, async () => {
    const c = capture();
    const operation = c.begin(failure === "startup" ? { readStdout: () => { throw Error("reader startup"); } } : {});
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    if (failure === "exit") c.exited.reject(Error("exit unknown"));
    if (failure === "stdout") c.out.reject(Error("read failure"));
    if (failure === "stderr") c.err.reject(Error("watcher failure"));
    if (failure === "fence") c.fence.reject(Error("effect failure"));
    if (failure === "missing-format") c.err.resolve({ format: null, stderr: "" });
    if (failure === "invalidated") c.err.resolve({ format: "invalidated", stderr: "FAIL" });
    if (failure === "contradiction") c.err.resolve({ format: { ...format, channels: 2 }, stderr: "using 2 channels" });
    if (failure === "tail") c.out.resolve({ ...extent(), nativeTail: new Uint8Array(1) });
    if (failure === "partial-frame") c.out.resolve({ ...extent(), nativeBytes: 3 });
    if (failure === "pcm") c.out.resolve({ ...extent(), pcm: new Uint8Array(3) });
    if (failure === "locked") reader = c.child.stdout.getReader();
    if (failure === "stderr-locked") reader = c.child.stderr.getReader();
    if (failure === "missing-pipe") Reflect.set(c.child, "stdout", null);
    if (failure === "stderr-missing") Reflect.set(c.child, "stderr", null);
    if (failure === "missing-stdout") c.out.resolve(undefined!);
    c.settle();
    expect(await operation).toBeInstanceOf(Error);
    await pending(c.policy);
    expect(observe(c.policy).errors.length).toBeGreaterThan(0);
    if (failure === "exit") {
      expect(observe(c.policy).exit.kind).toBe("rejected");
      tick(); tick();
      expect(observe(c.policy).stop).toBe("unconfirmed");
    }
    reader?.releaseLock();
  });
}

test("post-spawn setup/read/effect/cleanup failures retain every cause and pending task", async () => {
  const c = capture(), operation = c.begin({ readStdout: () => { throw Error("reader startup"); } });
  c.err.reject(Error("stderr failure")); c.fence.reject(Error("effect failure"));
  c.cleanup.reject(Error("cleanup failure"));
  let finished = false;
  void operation.then(() => { finished = true; });
  await turn();
  expect(finished).toBe(false);
  c.settle();
  const error = await operation;
  expect(error).toBeInstanceOf(AggregateError);
  expect(error.errors.map((cause: Error) => cause.message)).toContain("cleanup failure");
  // Independently owned tasks have no required error-arrival order; retain the exact set.
  expect(observe(c.policy).errors.map(String).sort()).toEqual([
    "Error: effect failure", "Error: reader startup", "Error: stderr failure",
  ]);
  await pending(c.policy);
});

test("signal failures remain observable without retry or loss of later actual exit", async () => {
  const c = capture(), operation = c.begin();
  c.child.kill = signal => { c.signals.push(signal); throw Error(String(signal)); };
  stop(c.policy); tick(); tick(); stop(c.policy);
  expect(c.signals).toEqual(["SIGTERM", "SIGKILL"]);
  expect(observe(c.policy).errors.map(String)).toEqual(["Error: SIGTERM", "Error: SIGKILL"]);
  await pending(c.policy);
  c.settle();
  expect(await operation).toBeInstanceOf(AggregateError);
  expect((await wait(c.policy)).kind).toBe("complete");
});

test("post-attachment setup rejection retains failure and completes only actual child facts", async () => {
  const c = capture(), operation = c.begin();
  c.setup.reject(Error("setup after spawn"));
  await pending(c.policy);
  c.settle();
  expect(await operation).toEqual(Error("setup after spawn"));
  expect((await wait(c.policy)).kind).toBe("complete");
});

test("terminal native stereo extent agrees with complete 16kHz mono normalization", async () => {
  const c = capture(12), operation = c.begin(), stereo = { sampleRate: 48000, channels: 2 };
  c.out.resolve({ ...extent(), nativeBytes: 12, pcm: new Uint8Array(2), format: stereo });
  c.err.resolve({ format: stereo, stderr: "using 48000, 2 channels" });
  c.settle();
  await operation;
  expect(await wait(c.policy)).toMatchObject({ kind: "complete", nativeBytes: 12, normalizedBytes: 2 });
});
