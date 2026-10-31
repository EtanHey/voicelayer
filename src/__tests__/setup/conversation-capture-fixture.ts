type Event = string;
type Signal = "SIGTERM" | "SIGKILL";

function deferred<T>(name: string, events: Event[]) {
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (reason: unknown) => void;
  let settled = false;
  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  // Attach a rejection observer immediately; consumers still see the original rejection.
  void promise.catch(() => {});
  return {
    promise,
    resolve(value: T) {
      if (settled) throw new Error(`${name} already settled`);
      settled = true;
      events.push(`${name}:resolve`);
      resolvePromise(value);
    },
    reject(reason: unknown) {
      if (settled) throw new Error(`${name} already settled`);
      settled = true;
      events.push(`${name}:reject`);
      rejectPromise(reason);
    },
    dispose(value: T) {
      if (!settled) {
        settled = true;
        events.push(`${name}:dispose`);
        resolvePromise(value);
      }
    },
  };
}

function controlledStream(name: string, events: Event[]) {
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  let terminal = false;
  const stream = new ReadableStream<Uint8Array>({
    start(value) { controller = value; },
    cancel() { terminal = true; events.push(`${name}:cancel`); },
  });
  return {
    stream,
    enqueue(bytes: Uint8Array) {
      if (terminal) throw new Error(`${name} already terminal`);
      events.push(`${name}:enqueue`);
      controller.enqueue(bytes.slice());
    },
    eof() {
      if (terminal) throw new Error(`${name} already terminal`);
      terminal = true;
      events.push(`${name}:eof`);
      controller.close();
    },
    error(reason: unknown) {
      if (terminal) throw new Error(`${name} already terminal`);
      terminal = true;
      events.push(`${name}:error`);
      controller.error(reason);
    },
    dispose() {
      if (!stream.locked) {
        events.push(`${name}:dispose`);
        void stream.cancel().catch(() => {});
      } else if (!terminal) {
        terminal = true;
        events.push(`${name}:dispose`);
        controller.close();
      }
    },
  };
}

export function createConversationRecorderFixture() {
  const events: Event[] = [];
  const signals: Signal[] = [];
  const stdout = controlledStream("stdout", events);
  const stderr = controlledStream("stderr", events);
  const exit = deferred<number>("exit", events);
  const processor = deferred<void>("processor", events);
  const effect = deferred<void>("effect", events);
  let disposed = false;
  return {
    child: {
      stdout: stdout.stream,
      stderr: stderr.stream,
      exited: exit.promise,
      kill(signal: Signal) { signals.push(signal); events.push(`signal:${signal}`); },
    },
    stdout, stderr, exit, processor, effect, events, signals,
    stop() { events.push("stop"); },
    abort() { events.push("abort"); },
    locks() { return { stdout: stdout.stream.locked, stderr: stderr.stream.locked }; },
    dispose() {
      if (disposed) return;
      disposed = true;
      stdout.dispose();
      stderr.dispose();
      exit.dispose(0);
      processor.dispose(undefined);
      effect.dispose(undefined);
      events.push("dispose");
    },
  };
}
