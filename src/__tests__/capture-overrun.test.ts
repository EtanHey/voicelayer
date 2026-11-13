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

  it("keeps an exact count and no position (a stderr read position is not where audio was lost)", () => {
    let overruns;
    for (let i = 0; i < 25; i++) overruns = noteCaptureOverrun(overruns);
    expect(overruns).toEqual({ count: 25 });
  });

  it("says plainly that audio was dropped during the take, with the count", () => {
    expect(captureOverrunNote({ count: 1 }))
      .toBe("The system dropped audio during this take (once). The transcript may be missing words.");
    expect(captureOverrunNote({ count: 4 })).toContain("(4 times)");
  });
});
