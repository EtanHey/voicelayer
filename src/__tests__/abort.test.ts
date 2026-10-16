import { describe, expect, it } from "bun:test";
import { abortErrorFor, throwIfAbortedSafe } from "../abort";

describe("safe abort errors", () => {
  for (const reason of [undefined, null, "cancel", 0, { name: "AbortError" }]) {
    it(`recreates a named AbortError for non-Error reason ${JSON.stringify(reason)}`, () => {
      const signal = { aborted: true, reason } as AbortSignal;
      const error = abortErrorFor(signal);
      expect(error).toBeInstanceOf(DOMException);
      expect(error.name).toBe("AbortError");
      expect(error.message).toBe("Aborted");
      expect(() => throwIfAbortedSafe(signal)).toThrow(error);
    });
  }

  it("preserves Error and DOMException reasons by identity", () => {
    for (const reason of [new Error("custom cancellation"), new DOMException("cancel", "AbortError"), new DOMException("deadline", "TimeoutError")]) {
      const signal = { aborted: true, reason } as AbortSignal;
      expect(abortErrorFor(signal)).toBe(reason);
      try {
        throwIfAbortedSafe(signal);
        throw new Error("expected cancellation");
      } catch (error) {
        expect(error).toBe(reason);
      }
    }
  });

  it("reads the reason once, retaining it across allocation/GC", () => {
    const expected = new Error("retained");
    let reads = 0;
    const signal = { aborted: true, get reason() { return ++reads === 1 ? expected : undefined; } } as AbortSignal;
    expect(abortErrorFor(signal)).toBe(expected);
    expect(reads).toBe(1);
  });

  it("does nothing for absent or active signals without reading their reason", () => {
    expect(() => throwIfAbortedSafe()).not.toThrow();
    const signal = { aborted: false, get reason() { throw new Error("active reason read"); } } as AbortSignal;
    expect(() => throwIfAbortedSafe(signal)).not.toThrow();
  });

  it("survives real forced GC of a default abort reason", () => {
    const controller = new AbortController();
    controller.abort();
    Bun.gc(true);
    expect(() => throwIfAbortedSafe(controller.signal)).toThrow(expect.objectContaining({ name: "AbortError" }));
  });
});
