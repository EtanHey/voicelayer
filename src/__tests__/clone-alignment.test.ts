import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { existsSync, writeFileSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import * as fsPromises from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { alignCloneAudio, type CloneAlignmentRequest } from "../tts/clone-alignment";
import { projectSpeakableText } from "../speakable-text";

// Frozen June 6 Edge harness audio, not synthesized by these tests. Generated
// base64 and its recorded decoder response are appended below; benchmark receipt
// docs.local/CLN1A/benchmark.json compares the original WordBoundary sidecar.
let root: string, serial = 0;
beforeAll(async () => { root = await mkdtemp(join(tmpdir(), "cln1a-test-")); await writeFile(join(root, "model"), "stub"); });
afterAll(async () => { await rm(root, { recursive: true, force: true }); });
const payload = (words: string[]) => ({ transcription: [{ tokens: words.map((word, i) => ({
  text: " " + word, offsets: { from: 100 + i * 200, to: 260 + i * 200 }, t_dtw: 18 + i * 20, p: .99,
})) }] });
async function request(text: string, response = payload(projectSpeakableText(text).speechText.split(/\s+/)), delay = 0) {
  const prefix = join(root, String(++serial)), binary = prefix + ".decoder", audioPath = prefix + ".mp3";
  await writeFile(audioPath, Buffer.from(EDGE_AUDIO, "base64"));
  // The unit converter copies bytes; actual ffmpeg/decoder evidence is separate.
  const ffmpeg = prefix + ".converter";
  await writeFile(ffmpeg, '#!/bin/sh\nwhile [ "$1" != "-i" ]; do shift; done\nshift\nsource_file="$1"\nfor target_file do :; done\nexec /bin/cp "$source_file" "$target_file"\n', { mode: 0o700 });
  await writeFile(binary, `#!${process.execPath}\nimport {writeFileSync,readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const args=process.argv.slice(2), out=args[args.indexOf('-of')+1], audio=args[args.indexOf('-f')+1];
writeFileSync(${JSON.stringify(prefix + ".pid")},String(process.pid));
setTimeout(()=>{writeFileSync(out+'.json',JSON.stringify(${JSON.stringify(response)}));
writeFileSync(${JSON.stringify(prefix + ".hash")},createHash('sha256').update(readFileSync(audio)).digest('hex'));},${delay});
`, { mode: 0o700 });
  const projection = projectSpeakableText(text);
  const input: CloneAlignmentRequest = { ...projection, audioPath, durationMs: 4344, language: "en",
    requestId: "request-a", chunkId: "chunk-2", playbackRate: 1, decoder: { binary, model: join(root, "model"), ffmpeg } };
  return { input, prefix };
}
const offsets = (result: Awaited<ReturnType<typeof alignCloneAudio>>) => result.words.map(w => w.offset_ms);
async function started(prefix: string) {
  for (let i = 0; i < 200; i++) { try { return Number(await readFile(prefix + ".pid", "utf8")); } catch { await Bun.sleep(5); } }
  throw new Error("decoder did not start");
}
function reaped(pid: number) { expect(() => process.kill(pid, 0)).toThrow(); }

test("frozen Edge audio retains only spans corroborated by the same token's DTW anchor", async () => {
  const { input } = await request("Should the company and the project merge, or stay separate?", EDGE_DECODE);
  const result = await alignCloneAudio(input);
  expect(result.status).toBe("partial");
  expect(offsets(result)).toEqual([240, 390, 640, 1030, 1220, 1410, 1860, null, null, null]);
  expect(result.identity).toEqual({ requestId: "request-a", chunkId: "chunk-2", playbackRate: 1, audioSha256: EDGE_SHA });
});
test("frozen audio maps a multiword SPK replacement and JSON escape without new acoustic times", async () => {
  const expanded = await request("Should the CP merge, or stay separate?", EDGE_DECODE);
  Object.assign(expanded.input, projectSpeakableText(expanded.input.displayText, [{ pattern: /\bCP\b/g, replacement: "company and the project" }]));
  expect(expanded.input.speechText).toBe("Should the company and the project merge, or stay separate?");
  expect((await alignCloneAudio(expanded.input)).words[2]).toMatchObject({ text: "CP", offset_ms: 640, duration_ms: 1220 });
  const escaped = await request('{"text":"Should the \\u0063ompany and the project merge, or stay separate?"}', EDGE_DECODE);
  expect((await alignCloneAudio(escaped.input)).words[2]).toMatchObject({ text: "\\u0063ompany", offset_ms: 640 });
  const mismatch = await request("Should the business and the project merge, or stay separate?", EDGE_DECODE);
  expect((await alignCloneAudio(mismatch.input)).words[2].offset_ms).toBeNull();
});
test("SPK expansion uses the full measured replacement span", async () => {
  const { input } = await request("Ship API now");
  const result = await alignCloneAudio(input);
  expect(offsets(result)).toEqual([100, 300, 900]);
  expect(result.words[1]).toMatchObject({ text: "API", duration_ms: 560, displayRange: { start: 5, end: 8 } });
});
test("an incompletely matched expansion remains untimed", async () => {
  const { input } = await request("Ship API now", payload(["Ship", "A", "I", "now"]));
  expect(offsets(await alignCloneAudio(input))).toEqual([100, null, 700]);
});
test("repeated words retain occurrence identity; ambiguous deletions abstain", async () => {
  const exact = await request("go go now");
  expect(offsets(await alignCloneAudio(exact.input))).toEqual([100, 300, 500]);
  const missing = await request("go go now", payload(["go", "now"]));
  expect(offsets(await alignCloneAudio(missing.input))).toEqual([null, null, 300]);
});
test("a mismatch never borrows the neighboring word's timing", async () => {
  const { input } = await request("red wrong blue", payload(["red", "green", "blue"]));
  expect(offsets(await alignCloneAudio(input))).toEqual([100, null, 500]);
});
test("JSON escape ranges preserve the exact original display token", async () => {
  const text = '{"name":"a\\nb"}', { input } = await request(text, payload(["name", "a", "b"]));
  const result = await alignCloneAudio(input);
  expect(result.words).toEqual([{ text, displayRange: { start: 0, end: text.length }, offset_ms: 100, duration_ms: 560 }]);
});
test("omitted decorations stay untimed", async () => {
  const { input } = await request("# Hello");
  expect(offsets(await alignCloneAudio(input))).toEqual([null, 100]);
});
test("playback rate scales file-relative timestamps exactly once", async () => {
  const { input } = await request("hello world"); input.playbackRate = 2;
  const result = await alignCloneAudio(input);
  expect(offsets(result)).toEqual([50, 150]);
  expect(result.words.map(w => w.duration_ms)).toEqual([80, 80]);
  expect(result.identity.playbackRate).toBe(2);
});
test("invalid projection, time, confidence, and DTW disagreement never gain offsets", async () => {
  const { input } = await request("hello"); input.ranges[0].speech.end++;
  expect((await alignCloneAudio(input)).status).toBe("untimed");
  for (const token of [
    { offsets: { from: -1, to: 260 } }, { offsets: { from: 100, to: 90 } },
    { offsets: { from: 100, to: 5000 } }, { t_dtw: -1 }, { t_dtw: 30 }, { p: .2 },
    { offsets: { from: 0, to: 160 }, t_dtw: -1 }, { offsets: { from: 4240, to: 4340 }, t_dtw: 436 },
  ]) {
    const response = payload(["hello"]); Object.assign(response.transcription[0].tokens[0], token);
    const row = await request("hello", response);
    expect(offsets(await alignCloneAudio(row.input))).toEqual([null]);
  }
});
test("request text, audio and identity are snapshotted before asynchronous decoding", async () => {
  const { input, prefix } = await request("hello", payload(["hello"]), 100);
  const pending = alignCloneAudio(input); await started(prefix);
  await writeFile(input.audioPath, "replaced"); input.displayText = "changed"; input.speechText = "changed"; input.requestId = "request-b";
  const result = await pending;
  expect(result.words[0].text).toBe("hello"); expect(result.identity.requestId).toBe("request-a");
  expect(result.identity.audioSha256).toBe(EDGE_SHA); expect(await readFile(prefix + ".hash", "utf8")).toBe(EDGE_SHA);
});
test("cancellation reaps owned decoding before returning, including pre-abort", async () => {
  const { input, prefix } = await request("hello", payload(["hello"]), 5000), controller = new AbortController();
  input.signal = controller.signal; const pending = alignCloneAudio(input), pid = await started(prefix);
  controller.abort(); expect((await pending).reason).toBe("cancelled"); reaped(pid);
  const before = await request("hello"); before.input.signal = AbortSignal.abort();
  expect((await alignCloneAudio(before.input)).reason).toBe("cancelled");
  expect(await Bun.file(before.prefix + ".pid").exists()).toBe(false);
});
test("the half-duration deadline kills and reaps a slow decoder", async () => {
  const { input, prefix } = await request("hello", payload(["hello"]), 5000);
  const pending = alignCloneAudio(input), pid = await started(prefix);
  expect((await pending).reason).toBe("deadline"); reaped(pid);
});
test("missing local decoder is a truthful untimed result", async () => {
  const { input } = await request("hello"); input.decoder.binary = join(root, "absent");
  expect((await alignCloneAudio(input)).reason).toBe("unavailable");
});
for (const phase of ["converter", "decoder"]) {
  for (const fault of ["exited", "kill", "both"]) {
    test(`cleanup ${phase} ${fault} failure resolves untimed and removes its snapshot`, async () => {
      const { input } = await request("hello");
      let directory = "", kills = 0, exitReads = 0;
      const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
        const converter = argv[0] === input.decoder.ffmpeg;
        if (converter) directory = dirname(argv[argv.indexOf("-i") + 1]);
        else writeFileSync(argv[argv.indexOf("-of") + 1] + ".json", JSON.stringify(payload(["hello"])));
        if (converter !== (phase === "converter")) return { exitCode: 0, exited: Promise.resolve(0) };
        const exited = fault === "kill" ? Promise.resolve(1) : Promise.reject(new Error("injected wait failure"));
        return {
          exitCode: fault === "exited" ? 1 : null,
          get exited() { exitReads++; return exited; },
          kill() { kills++; throw new Error("injected kill failure"); },
        };
      }) as typeof Bun.spawn);
      try {
        const settled = await Promise.allSettled([alignCloneAudio(input)]);
        if (settled[0].status === "rejected" || existsSync(directory))
          console.error({ phase, fault, promiseStatus: settled[0].status, snapshotLeaked: existsSync(directory), exitReads, kills });
        expect(directory).not.toBe("");
        expect(existsSync(directory)).toBe(false);
        expect(settled[0].status).toBe("fulfilled");
        if (settled[0].status === "fulfilled") {
          expect(settled[0].value).toMatchObject({ status: "untimed", reason: "unavailable" });
          expect(offsets(settled[0].value)).toEqual([null]);
        }
        expect(exitReads).toBe(2);
        expect(kills).toBe(fault === "exited" ? 0 : 1);
      } finally {
        spawn.mockRestore();
        if (directory) await rm(directory, { recursive: true, force: true });
      }
    });
  }
}
for (const [reason, earlyClockCheck] of [["cancelled", false], ["deadline", false], ["deadline", true]] as const) {
  test(`cleanup stop failure preserves ${reason}${earlyClockCheck ? " before the final clock deadline" : ""} and still awaits exit and removes its snapshot`, async () => {
    const { input } = await request("hello"), controller = new AbortController();
    input.signal = controller.signal;
    let directory = "", kills = 0, exitReads = 0, timer: ReturnType<typeof setTimeout> | undefined;
    let clock: ReturnType<typeof spyOn> | undefined;
    const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
      directory = dirname(argv[argv.indexOf("-i") + 1]);
      let rejectExit!: (error: Error) => void;
      const exited = new Promise<number>((_, reject) => {
        rejectExit = reject;
      });
      // Exercise the real deadline; external cancellation happens after spawn returns.
      if (reason === "cancelled") timer = setTimeout(() => controller.abort(), 0);
      return { exitCode: null, get exited() { exitReads++; return exited; },
        kill() {
          kills++;
          // Timer delivery can precede the fractional performance.now() deadline.
          if (earlyClockCheck && !clock) clock = spyOn(performance, "now").mockReturnValue(0);
          queueMicrotask(() => rejectExit(new Error("injected wait failure")));
          throw new Error("injected kill failure");
        } };
    }) as typeof Bun.spawn);
    try {
      const result = await alignCloneAudio(input);
      expect(result).toMatchObject({ status: "untimed", reason });
      expect(offsets(result)).toEqual([null]);
      expect(kills).toBe(2); expect(exitReads).toBe(2);
      expect(directory).not.toBe(""); expect(existsSync(directory)).toBe(false);
    } finally {
      clock?.mockRestore(); clearTimeout(timer); spawn.mockRestore();
      if (directory) await rm(directory, { recursive: true, force: true });
    }
  });
}
for (const fault of ["exited", "kill", "rm"]) {
  test(`cleanup ${fault} failure invalidates already computed timings`, async () => {
    const { input } = await request("hello"); let directory = "", exitReads = 0;
    const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
      if (argv[0] === input.decoder.ffmpeg) {
        directory = dirname(argv[argv.indexOf("-i") + 1]);
        return { exitCode: 0, exited: Promise.resolve(0) };
      }
      writeFileSync(argv[argv.indexOf("-of") + 1] + ".json", JSON.stringify(payload(["hello"])));
      return { exitCode: fault === "kill" ? null : 0, get exited() {
        return ++exitReads === 1 || fault !== "exited" ? Promise.resolve(0) : Promise.reject(new Error("injected cleanup wait failure"));
      }, kill() { throw new Error("injected cleanup kill failure"); } };
    }) as typeof Bun.spawn);
    const originalRemove = fsPromises.rm;
    const remove = fault === "rm" ? spyOn(fsPromises, "rm").mockImplementation((path, options) =>
      path === directory ? Promise.reject(new Error("injected removal failure")) : originalRemove(path, options)) : undefined;
    try {
      const result = await alignCloneAudio(input);
      expect(result).toMatchObject({ status: "untimed", reason: "unavailable" });
      expect(offsets(result)).toEqual([null]); expect(result.words[0].duration_ms).toBeNull();
      expect(exitReads).toBe(2); expect(existsSync(directory)).toBe(fault === "rm");
      if (remove) expect(remove).toHaveBeenCalledWith(directory, { recursive: true, force: true });
    } finally { remove?.mockRestore(); spawn.mockRestore(); if (directory) await rm(directory, { recursive: true, force: true }); }
  });
}
test("cancellation also kills and reaps preparation before decoding starts", async () => {
  const { input, prefix } = await request("hello"), controller = new AbortController(), prep = prefix + ".prep";
  await writeFile(input.decoder.ffmpeg, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs';
writeFileSync(${JSON.stringify(prep + ".pid")}, String(process.pid)); setInterval(()=>{},5000);\n`, { mode: 0o700 });
  input.signal = controller.signal; const pending = alignCloneAudio(input), pid = await started(prep);
  controller.abort(); expect((await pending).reason).toBe("cancelled"); reaped(pid);
  expect(await Bun.file(prefix + ".pid").exists()).toBe(false);
});
test("an extra repeated acoustic word is ambiguous in both optimal tracebacks", async () => {
  const { input } = await request("go now", payload(["go", "go", "now"]));
  expect(offsets(await alignCloneAudio(input))).toEqual([null, 500]);
});
test("BPE continuations keep their measured envelope without subdividing time", async () => {
  const response = payload(["se", "parate"]); response.transcription[0].tokens[1].text = "parate";
  const { input } = await request("separate", response);
  expect((await alignCloneAudio(input)).words[0]).toMatchObject({ offset_ms: 100, duration_ms: 360 });
});
test("Hebrew, emoji and SPK expansions preserve UTF-16 display identity", async () => {
  const { input } = await request("שלום API 😊"); input.language = "he";
  const result = await alignCloneAudio(input);
  expect(offsets(result)).toEqual([100, 300, null]);
  expect(result.words[2]).toMatchObject({ text: "😊", displayRange: { start: 9, end: 11 } });
});
test("unrecognized output and backward acoustic spans stay untimed", async () => {
  const unknown = await request("hello", {} as any);
  expect(offsets(await alignCloneAudio(unknown.input))).toEqual([null]);
  const response = payload(["hello", "world"]); response.transcription[0].tokens[1].offsets.from = 50;
  const backwards = await request("hello world", response);
  expect(offsets(await alignCloneAudio(backwards.input))).toEqual([null, null]);
});

for (const row of [
  { name: "straight suffix", parts: ["we", "'re"], duration: 360 },
  { name: "curly suffix", parts: ["we", "’re"], duration: 360 },
  { name: "straight apostrophe-only token", parts: ["we", "'", "re"], duration: 560 },
  { name: "curly apostrophe-only token", parts: ["we", "’", "re"], duration: 560 },
]) {
  const contraction = () => {
    const response = payload(row.parts);
    response.transcription[0].tokens.forEach((token, i) => {
      token.text = (i ? "" : " ") + row.parts[i];
      if (/^['’]$/.test(row.parts[i])) Object.assign(token, { offsets: { from: 0, to: 0 }, t_dtw: -1 });
    });
    return response;
  };
  test(`BPE ${row.name} cannot falsely time were`, async () => {
    const { input } = await request("were", contraction());
    expect(offsets(await alignCloneAudio(input))).toEqual([null]);
  });
  test(`BPE ${row.name} times the matching contraction`, async () => {
    for (const display of ["we're", "we’re"]) {
      const { input } = await request(display, contraction());
      expect((await alignCloneAudio(input)).words[0]).toMatchObject({ text: display, offset_ms: 100, duration_ms: row.duration });
    }
  });
}
test("apostrophe-only tokens preserve whitespace boundaries between different words", async () => {
  const response = payload(["we", "' ", "re"]);
  response.transcription[0].tokens[1].text = "' "; response.transcription[0].tokens[2].text = "re";
  const different = await request("were", response), separate = await request("we re", response);
  expect(offsets(await alignCloneAudio(different.input))).toEqual([null]);
  expect(offsets(await alignCloneAudio(separate.input))).toEqual([100, 500]);
});

// GENERATED_FIXTURE_DATA
const EDGE_SHA = "f997b15bc94e9a8ee35d65424e9c758c06eceb166939ece36eefeeff60426152";
const EDGE_DECODE = {"transcription":[{"timestamps":{"from":"00:00:00,000","to":"00:00:03,260"},"offsets":{"from":0,"to":3260},"text":" Should the company and the project merge or stay separate?","tokens":[{"text":"[_BEG_]","timestamps":{"from":"00:00:00,000","to":"00:00:00,000"},"offsets":{"from":0,"to":0},"id":50365,"p":0.799122,"t_dtw":-1},{"text":" Should","timestamps":{"from":"00:00:00,240","to":"00:00:00,390"},"offsets":{"from":240,"to":390},"id":6454,"p":0.910285,"t_dtw":40},{"text":" the","timestamps":{"from":"00:00:00,390","to":"00:00:00,530"},"offsets":{"from":390,"to":530},"id":264,"p":0.998016,"t_dtw":56},{"text":" company","timestamps":{"from":"00:00:00,640","to":"00:00:01,030"},"offsets":{"from":640,"to":1030},"id":2237,"p":0.992797,"t_dtw":94},{"text":" and","timestamps":{"from":"00:00:01,030","to":"00:00:01,220"},"offsets":{"from":1030,"to":1220},"id":293,"p":0.988293,"t_dtw":116},{"text":" the","timestamps":{"from":"00:00:01,220","to":"00:00:01,410"},"offsets":{"from":1220,"to":1410},"id":264,"p":0.999201,"t_dtw":128},{"text":" project","timestamps":{"from":"00:00:01,410","to":"00:00:01,860"},"offsets":{"from":1410,"to":1860},"id":1716,"p":0.999045,"t_dtw":174},{"text":" merge","timestamps":{"from":"00:00:01,860","to":"00:00:02,220"},"offsets":{"from":1860,"to":2220},"id":22183,"p":0.98349,"t_dtw":216},{"text":" or","timestamps":{"from":"00:00:02,220","to":"00:00:02,250"},"offsets":{"from":2220,"to":2250},"id":420,"p":0.927778,"t_dtw":250},{"text":" stay","timestamps":{"from":"00:00:02,420","to":"00:00:02,580"},"offsets":{"from":2420,"to":2580},"id":1754,"p":0.999068,"t_dtw":278},{"text":" separate","timestamps":{"from":"00:00:02,580","to":"00:00:03,030"},"offsets":{"from":2580,"to":3030},"id":4994,"p":0.996633,"t_dtw":324},{"text":"?","timestamps":{"from":"00:00:03,120","to":"00:00:03,260"},"offsets":{"from":3120,"to":3260},"id":30,"p":0.978972,"t_dtw":324},{"text":"[_TT_163]","timestamps":{"from":"00:00:03,260","to":"00:00:03,260"},"offsets":{"from":3260,"to":3260},"id":50528,"p":0.152743,"t_dtw":-1}]}]};
const EDGE_AUDIO = "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01K1DS1mNleYowPigBCy3ob/MpVcVYqGQWaW/6gNStE4E1AZ//NkxMIcmZbSRhPMFGb6h4uksIouJdYSFGkxzA2HTB1gsgcQ/9T/nQqdHMcHVnYACdyN5iT8kv/GPARxs7PAqid7Dfz4iElkXfleUuoGRtN3uW35DeCkdlggeaObDiGQQDt291XRvWuPgVNpAhNlf5//zGoVVNgxTU///1sia2hRJgZNWyP+qSpIW9P/Vnqr//NkxNIcMYrCFsJKWCtIpcuhWmjoSCxWd//64aC52RoALICkAVlrRt242aaXoMmKjpoeec0JBhZFwEbIUTD/q0wJADEYpD9A21/b/zvzGgOHRETNvcYUkVqvYYcxWJKpzI4sNGiQi01779sqI60KiCYwoorT//+xiCI9RhcpnnKVGar0/veOMOHO+mi5VQaw//NkxOQc4yKqfsoE2KKQ7FZqloizmRxA8XHsan///+ujrdmSOFSAEKOEApzVQArkdjsTakVr/6CGUIJClgeYJMOCTBMAmQsU4AlK0yItiYOIusUBodAoK6RTpCxaCfTngssbUKWIEji2DDONWAWwJAJQpVS/YlyhjPElbH6Hzmmzq+M6c46cVL3SfXaGQ2RS//NkxPMj696Nv1soAKXSz1gSsalbMln9LYa1MeTJHvHqxsaExo2t492uZztjWd6iyRFA80yPMtklHW5qZhWz94tFxeHqPGriAqI1pcZfNc2bxmVjlxmDCiVneWhsk7hHpvH+p7VxjbxxvW2N6iRPvGq4f3p//////////////////////ufPvvNKen0/PPWV//NkxOY5VBqpvZp4A2AAIBkWBWmRAIjXKnG0GR5jEECzAEJFykAxe5TFlAWFWoX4KB46XSaGLmOgehHOSGo44oaEAuiSmGzNowGpRHcCVJqaR/N7ZZLM9na7WVVWCxVVK4QIz3GPLBN1FOdYyjOK7i3sjYyP1klsDcGx2m8f1XHBop5RqI8nGbNf64Y4tf////NkxIMzuua+X5l4Adl////vFru2+8iwNyfGcbtuuPm2vbdd51Wv02wHtocasSJPeHmFuSDArjeN1zrGZA5YKeKKP++diu1iUZMdg7//ZxoNL6wr///jRRQNML1ElpC0qgJVpQocNWUHGjgYj5FQGXJGIE7bpRatLV/Sp4JPhHhahSAZEEbBf8BvA2CRsjKi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//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqpMQU1FMy4xMDCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NkxHwAAANIAAAAAKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq";
