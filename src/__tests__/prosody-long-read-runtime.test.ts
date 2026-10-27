import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import * as qwen from "../tts/qwen3";
import * as cloneTiming from "../tts/clone-timing";
import * as prosodyPolicy from "../tts/prosody";
import * as binaries from "../resolve-binary";
import * as socket from "../socket-client";
import * as recording from "../recording-state";
import { beginSpeechArchive, flushSpeechArchives } from "../speech-archive-live";
import { projectSpeakableText } from "../speakable-text";
import { awaitCurrentPlayback, chunkTextForLongRead, loadHistory, speakLongRead, stopPlayback } from "../tts";
import { TTS_HISTORY_FILE } from "../paths";
import { planProsody } from "../tts/prosody";
import { projectStructuredSpeech } from "../tts/structured-speech";

/** PROSODY (b): structured edge reads synthesize planned utterances and splice later chunks;
 * plain prose is untouched. Every child (edge synth, ffmpeg, player) is a fake. */
describe("prosody long reads (fake engine, decoder and player children)", () => {
  const originalSpawn = Bun.spawn, originalSpawnSync = Bun.spawnSync;
  let synths: { argv: string[]; media: string }[], encodes: string[], decodes: string[], players: { argv: string[]; synthCount: number; encodeCount: number; decodeCount: number }[];
  let spies: ReturnType<typeof spyOn>[], events: any[], handles: { done: Promise<void> }[];
  let holdAfter: number;
  let holdTail = false, pendingTail = 0, releaseTails: (() => void)[] = [];
  let releaseHeld: (() => void)[];

  beforeEach(() => {
    synths = []; encodes = []; decodes = []; players = []; spies = []; events = []; handles = []; holdAfter = Infinity; releaseHeld = [];
    holdTail = false; pendingTail = 0; releaseTails = [];
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
    spies.push(spyOn(socket, "broadcast").mockImplementation((event) => events.push(structuredClone(event))));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    Bun.spawnSync = ((argv: string[]) => {
      if (argv[0] === "which") return { exitCode: 0, stdout: Buffer.from(argv[1]), stderr: Buffer.alloc(0) };
      return { exitCode: ["ffprobe", "ffmpeg"].includes(argv[0]) ? 0 : 1, stdout: Buffer.from(argv[0] === "ffprobe" ? "1\n" : ""), stderr: Buffer.alloc(0) };
    }) as any;
    Bun.spawn = ((argv: string[]) => {
      if (argv[1] === "-version") return { pid: 1, exited: Promise.resolve(0), kill() {} };
      if (argv[0] === "which") return { pid: 2, exited: Promise.resolve(0), stdout: new Blob(["ffmpeg"]).stream(), kill() {} };
      if (argv.some((arg) => arg.startsWith("--text="))) {
        const media = argv.find((arg) => arg.startsWith("--write-media="))!.slice(14);
        const metadata = argv.find((arg) => arg.startsWith("--write-metadata="))!.slice(17);
        const spoken = argv.find((arg) => arg.startsWith("--text="))!.slice(7);
        writeFileSync(media, "fake audio");
        writeFileSync(metadata, spoken.split(/\s+/).map((text, i) => JSON.stringify({ text, offset: (1000 + i * 3000) * 1000, duration: 3000 * 1000 })).join("\n"));
        synths.push({ argv, media });
        let release!: () => void;
        const exited = synths.length > holdAfter ? new Promise<number>((r) => { release = () => r(143); releaseHeld.push(release); }) : Promise.resolve(0);
        return { pid: 100 + synths.length, exited, kill: () => release?.() };
      }
      if (argv.some((arg) => /ffmpeg$/.test(arg)) || argv[0] === "ffmpeg") {
        if (argv.includes("pipe:0")) {
          encodes.push(argv.at(-1)!); writeFileSync(argv.at(-1)!, "encoded mp3");
          return { pid: 300, stdin: { write(data: Uint8Array) { writeFileSync(argv.at(-1)!, data); }, end: async () => {} }, stdout: new Blob([]).stream(), exited: Promise.resolve(0), kill() {} };
        }
        if (argv.includes("pipe:1") && argv.includes("f32le")) {
          decodes.push(argv[argv.indexOf("-i") + 1]);
          // 100 ms silence, 300 ms tone per word slot (fixture metadata), 200 ms silence: about 1 s.
          const pcm = new Float32Array(24000);
          for (let i = 2400; i < 19200; i++) pcm[i] = 0.3 * Math.sin(2 * Math.PI * i / 48);
          if (holdTail) {
            pendingTail++;
            let finish!: () => void;
            const exited = new Promise<number>((r) => { finish = () => { pendingTail--; r(0); }; releaseTails.push(finish); });
            return { pid: 301, stdout: new Blob([pcm.buffer]).stream(), exited, kill: () => finish() };
          }
          return { pid: 301, stdout: new Blob([pcm.buffer]).stream(), exited: Promise.resolve(0), kill() {} };
        }
        if (argv.includes("-ss") || argv.includes("concat")) writeFileSync(argv.at(-1)!, "derived audio");
        return { pid: 302, stdout: new Blob([new Uint8Array(8)]).stream(), exited: Promise.resolve(0), kill() {} };
      }
      players.push({ argv, synthCount: synths.length, encodeCount: encodes.length, decodeCount: decodes.length });
      return { pid: 400 + players.length, exited: Promise.resolve(0), kill() {} };
    }) as any;
  });
  afterEach(async () => {
    for (const release of releaseTails.splice(0)) release();
    stopPlayback(); for (const release of releaseHeld) release();
    for (const h of handles) await h.done; await awaitCurrentPlayback(); await flushSpeechArchives();
    for (const spy of spies) spy.mockRestore(); Bun.spawn = originalSpawn; Bun.spawnSync = originalSpawnSync;
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
  });
  const start = (readText: string, structuredDisplay?: ReturnType<typeof projectStructuredSpeech>) => {
    const h = speakLongRead(readText, { engine: "edge", voice: "fixture", rate: "+0%" }, Date.now(), { structuredDisplay });
    handles.push(h); return h;
  };
  const texts = () => synths.map((s) => s.argv.find((a) => a.startsWith("--text="))!.slice(7));

  it("a structured read sends each planned utterance to the engine, emphasized ones with top-level prosody", async () => {
    const doc = "## Status\n\nThe build is green.\n\n1. Merge now\n2. Wait for the proof";
    const plan = planProsody({ readText: doc, projection: projectSpeakableText(doc, [], "edge") });
    const h = start(doc); await h.done;
    expect(texts()).toEqual(plan.segments.map((s) => s.text));
    const heading = synths[0].argv;
    expect(heading).toContain("--rate=-10%");
    expect(heading).toContain("--pitch=-8Hz");
    expect(heading).toContain("--volume=+10%");
    expect(synths[1].argv.some((a) => a.startsWith("--pitch="))).toBe(false);
    const preparing = events.find((e) => e.state === "speaking" && e.long_read?.preparing);
    expect(preparing.long_read.chunk_count).toBe(plan.chunks.length);
  });
  for (const selection of [false, true]) it(`S1 F1/F11 clone structural media, alignment and archive (selection=${selection})`, async () => {
    const source = "**What I need from you**\n1. Don't reboot yet.\n2. Open the merge page.";
    const structure = selection ? projectStructuredSpeech(source) : undefined;
    const text = structure?.speechText ?? source;
    const projection = projectSpeakableText(text, [], "clone");
    const plan = planProsody({ readText: text, projection, structure, listNumbers: "inline", concurrency: 1 });
    const clone = spyOn(qwen, "synthesizeCloned").mockResolvedValue(Buffer.from("clone audio"));
    const timingInputs: Parameters<typeof cloneTiming.startCloneTiming>[0][] = [];
    const timing = spyOn(cloneTiming, "startCloneTiming").mockImplementation(input => {
      timingInputs.push(input);
      return { cancel() {}, childReaped: Promise.resolve(), cleanupDone: Promise.resolve() };
    });
    spies.push(clone, timing);
    const archive = beginSpeechArchive(source); await archive.settled();
    const handle = speakLongRead(text, { engine: "clone", voice: "fixture", rate: "+0%" }, Date.now(),
      { archiveContext: archive.context, structuredDisplay: structure });
    handles.push(handle); await handle.done; await flushSpeechArchives();
    expect(clone.mock.calls.map(call => call[0])).toEqual(plan.segments.map(segment => segment.text));
    expect(synths).toEqual([]);
    expect(timingInputs).toHaveLength(plan.chunks.length);
    const metadata = JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
    expect(metadata.speech.state).toBe("completed");
    expect(metadata.speech.generated).toHaveLength(plan.chunks.length);
    for (const [index, generated] of metadata.speech.generated.entries()) {
      expect(generated).toMatchObject({ index, engine: "qwen3-tts", voice: "fixture" });
      expect(generated.text).toBe(plan.segments.slice(plan.chunks[index].first, plan.chunks[index].end).map(s => s.text).join(" "));
      expect(timingInputs[index].audioPath).toBe(players[index].argv.at(-1)!);
      expect(timingInputs[index].displayText).toBe(plan.chunks[index].text);
      expect(timingInputs[index].speechText.replace(/[^\p{L}\p{N}]/gu, "")).toBe(generated.text.replace(/[^\p{L}\p{N}]/gu, ""));
      if (index === 0) continue;
      const bytes = readFileSync(join(archive.context.path, generated.audio_path));
      const pcm = new Float32Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
      expect(timingInputs[index].durationMs).toBeCloseTo(pcm.length / 24, 6);
      const silentRuns: number[] = [];
      let run = 0;
      for (const sample of pcm) {
        if (Math.abs(sample) < 0.00001) run++;
        else { if (run > 100) silentRuns.push(run / 24); run = 0; }
      }
      if (index === 1) expect(silentRuns[0] + 200 + 15).toBeGreaterThanOrEqual(plan.chunks[0].trailingPauseMs);
      if (plan.chunks[index].end - plan.chunks[index].first > 1)
        expect(Math.max(...silentRuns.slice(1)) + 45).toBeGreaterThanOrEqual(plan.segments[plan.chunks[index].first].pauseMs);
      expect(timingInputs[index].chunkId).toContain(plan.renderIdentity);
    }
    expect(plan.segments.find(s => s.kind === "heading")!.pauseMs).toBeGreaterThanOrEqual(800);
    expect(plan.segments.find(s => s.kind === "item")!.pauseMs).toBeGreaterThanOrEqual(450);
    expect(prosodyPolicy.PROSODY_POLICY.cloneEmphasis).toBe("none");
    expect(loadHistory()[0].prosodyIdentity).toBe(plan.renderIdentity);
  });
  it("S1 structured clone fallback keeps actual engine provenance and Edge word timings", async () => {
    const clone = spyOn(qwen, "synthesizeCloned").mockResolvedValue(null); spies.push(clone);
    const doc = "## Choose\n1. Red apple\n2. Green pear";
    const plan = planProsody({ readText: doc, projection: projectSpeakableText(doc, [], "clone"), listNumbers: "inline" });
    const archive = beginSpeechArchive(doc); await archive.settled();
    const handle = speakLongRead(doc, { engine: "clone", voice: "fixture", fallbackVoice: "en-US-JennyNeural", rate: "+0%" },
      Date.now(), { archiveContext: archive.context }); handles.push(handle); await handle.done; await flushSpeechArchives();
    expect(texts()).toEqual(plan.segments.map(s => s.text));
    const metadata = JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
    expect(metadata.speech.generated.every((g: { engine: string; voice: string }) =>
      g.engine === "edge-tts" && g.voice === "en-US-JennyNeural")).toBe(true);
    expect(events.some(e => e.type === "subtitle" && e.words.length > 0)).toBe(true);
  });
  it("S1 a clone read without ffmpeg keeps the existing chunker", async () => {
    const clone = spyOn(qwen, "synthesizeCloned").mockResolvedValue(Buffer.from("clone audio"));
    const resolve = binaries.resolveBinary;
    spies.push(clone, spyOn(binaries, "resolveBinary").mockImplementation(name => name === "ffmpeg" ? undefined : resolve(name)));
    const doc = "## Choose\n1. Red apple\n2. Green pear";
    const handle = speakLongRead(doc, { engine: "clone", voice: "fixture", rate: "+0%" }); handles.push(handle); await handle.done;
    expect(clone.mock.calls.map(call => call[0])).toEqual(chunkTextForLongRead(doc).map(chunk => projectSpeakableText(chunk, [], "clone").speechText));
    expect(encodes).toEqual([]);
  });
  it("S1 Stop cancels in-flight clone segments without starting more", async () => {
    let calls = 0;
    const clone = spyOn(qwen, "synthesizeCloned").mockImplementation((_text, _voice, signal) => {
      if (++calls === 1) return Promise.resolve(Buffer.from("clone audio"));
      return new Promise(resolve => {
        if (signal?.aborted) resolve(null);
        else signal?.addEventListener("abort", () => resolve(null), { once: true });
      });
    }); spies.push(clone);
    const handle = speakLongRead("## Choose\n- Red apple\n- Green pear\n- Blue sky\n- White cloud\n- Orange fruit",
      { engine: "clone", voice: "fixture", rate: "+0%" }); handles.push(handle);
    for (let i = 0; i < 50 && calls < 2; i++) await new Promise(resolve => setTimeout(resolve, 5));
    expect(calls).toBe(2);
    stopPlayback(); await handle.done;
    expect(calls).toBe(2);
  });
  it("chunk 0 plays the engine's own file before anything is encoded; later chunks play encoded MP3s", async () => {
    const doc = "## Status\n\nThe build is green.\n\n- One\n- Two\n- Three";
    const h = start(doc); await h.done;
    expect(players.length).toBeGreaterThan(1);
    expect(players[0].argv.at(-1)).toBe(synths[0].media);
    // Chunk 0's audio is never re-encoded (its delivery before any decode is pinned in prosody-read.test.ts).
    expect(encodes).not.toContain(players[0].argv.at(-1)!);
    for (const player of players.slice(1)) expect(encodes).toContain(player.argv.at(-1)!);
    expect(encodes.every((file) => file.endsWith(".mp3"))).toBe(true);
    // Segment files of spliced chunks were decoded, then removed.
    for (const synth of synths.slice(1)) { expect(decodes).toContain(synth.media); expect(existsSync(synth.media)).toBe(false); }
  });
  it("B3: the first player spawns before chunk 0's tail is decoded", async () => {
    const h = start("## Status"); await h.done;
    expect(players[0].decodeCount).toBe(0);
  });
  it("B1: completion reaps chunk 0's tail decoder; none is pending after done", async () => {
    holdTail = true;
    const h = start("## Status"); await h.done;
    expect(pendingTail).toBe(0);
  });
  it("a selection read plans from its structured display", async () => {
    const structure = projectStructuredSpeech("## Choose\n- Red apple\n- Green pear");
    const h = start(structure.speechText, structure); await h.done;
    expect(texts()).toEqual(["Choose.", "Red apple.", "Green pear."]);
  });
  it("plain prose keeps the existing chunker and one request per chunk, with no splice", async () => {
    const prose = Array.from({ length: 20 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" ");
    const h = start(prose); await h.done;
    expect(texts()).toEqual(chunkTextForLongRead(prose).map((chunk) => projectSpeakableText(chunk, [], "edge").speechText));
    expect(encodes).toEqual([]);
  });
  it("stop during a structured read starts no further engine requests and leaves no segment files", async () => {
    holdAfter = 1;
    const doc = "## Status\n\nThe build is green.\n\n- One\n- Two\n- Three\n- Four\n- Five\n- Six";
    const h = start(doc);
    for (let i = 0; i < 50 && synths.length < 4; i++) await new Promise((r) => setTimeout(r, 5));
    const before = synths.length;
    expect(before).toBeLessThanOrEqual(4); // chunk 0 plus at most three concurrent requests
    stopPlayback(); for (const release of releaseHeld) release();
    await h.done;
    expect(synths.length).toBe(before);
    for (const synth of synths.slice(1)) expect(existsSync(synth.media)).toBe(false);
  });
});
