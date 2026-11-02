import { describe, expect, it } from "bun:test";
import { RecordingTakeQueue } from "../recording-take-queue";

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((accept, fail) => { resolve = accept; reject = fail; });
  return { promise, resolve, reject };
}
const tick = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };

describe("independent recording take ownership", () => {
  it("accepts another mic owner during STT; old completion cannot release the new owner", async () => {
    const queue = new RecordingTakeQueue<string>();
    const decode = deferred<string>();
    const entered = deferred<void>();
    const a = queue.beginCapture("a", "editor A");
    const delivered: string[] = [];
    const first = queue.finishCapture(a, {
      recorderExited: Promise.resolve(), archive: async () => "a.wav",
      transcribe: async () => { entered.resolve(); return decode.promise; },
      deliver: async (text, take) => { delivered.push(`${take.target}:${text}`); },
    });
    await entered.promise;
    const b = queue.beginCapture("b", "editor B");
    expect(queue.snapshot).toEqual({ microphone: "capturing", processingCount: 1 });
    decode.resolve("first");
    await first;
    expect(queue.snapshot).toEqual({ microphone: "capturing", processingCount: 0 });
    expect(delivered).toEqual(["editor A:first"]);
    expect(() => queue.beginCapture("c", "editor C")).toThrow("Recording already");
    queue.cancel(b);
  });

  it("holds mic admission until recorder exit AND archive; queued paste is FIFO and take-targeted", async () => {
    const queue = new RecordingTakeQueue<string>();
    const exited = deferred<void>(), archived = deferred<string>(), pasted = deferred<void>();
    const events: string[] = [];
    const first = queue.finishCapture(queue.beginCapture("a", "A"), {
      recorderExited: exited.promise,
      archive: async () => { events.push("archive A"); return archived.promise; },
      transcribe: async path => { events.push(path); return "one"; },
      deliver: async (text, take) => { events.push(`${take.target}:${text}`); await pasted.promise; },
    });
    expect(queue.snapshot.microphone).toBe("draining");
    expect(() => queue.beginCapture("b", "B")).toThrow();
    exited.resolve(); await tick();
    expect(events).toEqual(["archive A"]);
    expect(() => queue.beginCapture("b", "B")).toThrow();
    archived.resolve("a.wav"); await tick();
    const second = queue.finishCapture(queue.beginCapture("b", "B"), {
      recorderExited: Promise.resolve(), archive: async () => "b.wav",
      transcribe: async path => { events.push(path); return "two"; },
      deliver: async (text, take) => { events.push(`${take.target}:${text}`); },
    });
    await tick();
    expect(events).not.toContain("b.wav");
    pasted.resolve(); await Promise.all([first, second]);
    expect(events).toEqual(["archive A", "a.wav", "A:one", "b.wav", "B:two"]);
    expect(queue.snapshot).toEqual({ microphone: "free", processingCount: 0 });
  });

  it("archives cancelled captures and cancels only the named take", async () => {
    const queue = new RecordingTakeQueue<string>();
    const firstDecode = deferred<string>(), entered = deferred<void>();
    const a = queue.beginCapture("a", "A");
    const events: string[] = [];
    const first = queue.finishCapture(a, {
      recorderExited: Promise.resolve(), archive: async () => "a.wav",
      transcribe: async () => { entered.resolve(); return firstDecode.promise; },
      deliver: async () => { events.push("paste A"); },
    });
    await entered.promise;
    const b = queue.beginCapture("b", "B");
    queue.cancel(b);
    const second = queue.finishCapture(b, {
      recorderExited: Promise.resolve(), archive: async () => { events.push("archive B"); return "b.wav"; },
      transcribe: async () => { events.push("decode B"); return "two"; },
      deliver: async () => { events.push("paste B"); },
    });
    firstDecode.resolve("one"); await Promise.all([first, second]);
    expect(events).toEqual(["archive B", "paste A"]);
    expect(queue.cancel(a)).toBe(false);
  });

  it("skips delivery after in-flight cancellation and drains after decoder failure", async () => {
    const queue = new RecordingTakeQueue<string>();
    const decode = deferred<string>(), entered = deferred<void>();
    const a = queue.beginCapture("a", "A");
    const events: string[] = [];
    const first = queue.finishCapture(a, {
      recorderExited: Promise.resolve(), archive: async () => "a.wav",
      transcribe: async () => { entered.resolve(); return decode.promise; },
      deliver: async () => { events.push("A"); },
    });
    await entered.promise;
    queue.cancel(a); decode.resolve("cancelled"); await first;
    const failed = queue.finishCapture(queue.beginCapture("b", "B"), {
      recorderExited: Promise.resolve(), archive: async () => "b.wav",
      transcribe: async () => { throw Error("decoder failed"); }, deliver: async () => {},
    });
    await expect(failed).rejects.toThrow("decoder failed");
    await queue.finishCapture(queue.beginCapture("c", "C"), {
      recorderExited: Promise.resolve(), archive: async () => "c.wav",
      transcribe: async () => "third", deliver: async text => { events.push(text); },
    });
    expect(events).toEqual(["third"]);
  });

  it("fails closed on missing exit/archive proof and rejects forged or reused identities", async () => {
    const queue = new RecordingTakeQueue<string>();
    const a = queue.beginCapture("a", "A");
    const work = {
      recorderExited: Promise.resolve(), archive: async () => { throw Error("disk full"); },
      transcribe: async () => "", deliver: async () => {},
    };
    await expect(queue.finishCapture({ ...a }, work)).rejects.toThrow("does not own");
    await expect(queue.finishCapture(a, work)).rejects.toThrow("disk full");
    expect(queue.snapshot.microphone).toBe("draining");
    expect(() => queue.beginCapture("a", "A")).toThrow("identity");
    expect(() => queue.beginCapture("b", "B")).toThrow("Recording already");
  });

  it("cancels a queued take without cancelling the decoder or the newer mic owner", async () => {
    const queue = new RecordingTakeQueue<string>();
    const decode = deferred<string>(), entered = deferred<void>();
    const a = queue.beginCapture("a", "A");
    const events: string[] = [];
    const first = queue.finishCapture(a, {
      recorderExited: Promise.resolve(), archive: async () => "a.wav",
      transcribe: async () => { entered.resolve(); return decode.promise; },
      deliver: async text => { events.push(text); },
    });
    await entered.promise;
    const b = queue.beginCapture("b", "B");
    const second = queue.finishCapture(b, {
      recorderExited: Promise.resolve(), archive: async () => "b.wav",
      transcribe: async () => { events.push("decode B"); return "two"; },
      deliver: async () => { events.push("paste B"); },
    });
    await tick();
    const c = queue.beginCapture("c", "C");
    expect(queue.cancel({ ...b })).toBe(false);
    expect(queue.cancel(b)).toBe(true);
    expect(a.signal.aborted).toBe(false);
    expect(c.signal.aborted).toBe(false);
    decode.resolve("one"); await Promise.all([first, second]);
    expect(events).toEqual(["one"]);
    expect(queue.snapshot.microphone).toBe("capturing");
  });

  it("refuses another capture if recorder exit cannot be proved and never decodes that capture", async () => {
    const queue = new RecordingTakeQueue<string>();
    const events: string[] = [];
    const take = queue.beginCapture("a", "A");
    await expect(queue.finishCapture(take, {
      recorderExited: Promise.reject(Error("exit unknown")),
      archive: async () => { events.push("archive"); return "a.wav"; },
      transcribe: async () => { events.push("decode"); return "one"; },
      deliver: async () => { events.push("paste"); },
    })).rejects.toThrow("exit unknown");
    expect(events).toEqual(["archive"]);
    expect(() => queue.beginCapture("b", "B")).toThrow("Recording already");
  });

});
