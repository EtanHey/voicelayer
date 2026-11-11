/** c8-M3: sox's CoreAudio overrun lines are counted, never missed across pipe writes, never double counted. */
import { describe, expect, it } from "bun:test";
import { captureOverrunNote, createRecorderOverrunCounter, noteCaptureOverrun } from "../input";

const LINE = "rec WARN coreaudio: coreaudio: unhandled buffer overrun.  Data discarded.";

describe("c8-M3 recorder overrun counter", () => {
  it("counts complete lines, including one split across writes and a final line without a newline", () => {
    let count = 0;
    const counter = createRecorderOverrunCounter(() => count++);
    counter.push(`${LINE}\nrec INFO ok\n${LINE.slice(0, 20)}`);
    expect(count).toBe(1);
    counter.push(`${LINE.slice(20)}\n`);
    expect(count).toBe(2);
    counter.push(LINE);
    expect(count).toBe(2);
    counter.finish();
    expect(count).toBe(3);
    counter.finish();
    expect(count).toBe(3);
  });

  it("keeps the count exact and at most 20 offsets", () => {
    let overruns;
    for (let i = 0; i < 25; i++) overruns = noteCaptureOverrun(overruns, i * 1000);
    expect(overruns!.count).toBe(25);
    expect(overruns!.offsetsMs).toHaveLength(20);
  });

  it("says plainly that audio was dropped and where", () => {
    expect(captureOverrunNote({ count: 1, offsetsMs: [49_300] }))
      .toBe("Audio was dropped by the system during this take (once, first near 0:49). The transcript may be missing words there.");
    expect(captureOverrunNote({ count: 4, offsetsMs: [87_000] })).toContain("(4 times, first near 1:27)");
  });
});
