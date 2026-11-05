import { expect, it, spyOn } from "bun:test";
import { writeFileSync } from "node:fs";
import { SpeechWordTimeline } from "../tts/speech-words";
import { parseCommand, serializeEvent, type SocketEvent } from "../socket-protocol";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import { handleSocketCommand } from "../socket-handlers";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";

it("adds a validated word seek while preserving the legacy seek wire", () => {
  expect(parseCommand('{"cmd":"speech_seek","utteranceId":"u","wordIndex":2,"id":"retry"}'))
    .toEqual({ cmd: "speech_seek", utteranceId: "u", wordIndex: 2, id: "retry" });
  for (const wordIndex of [-1, 0.5, "1", null, 1e99])
    expect(parseCommand(JSON.stringify({ cmd: "speech_seek", utteranceId: "u", wordIndex }))).toBeNull();
  for (const utteranceId of ["", " ", null, "a".repeat(257)])
    expect(parseCommand(JSON.stringify({ cmd: "speech_seek", utteranceId, wordIndex: 0 }))).toBeNull();
  expect(parseCommand('{"cmd":"seek","offset_ms":300}')).toEqual({ cmd: "seek", offset_ms: 300 });
});

it("publishes Edge boundaries, proportional clone fallback, and later measured updates in global word order", () => {
  const timeline = new SpeechWordTimeline("utterance");
  const edge = timeline.update(0, "Hello world", 1000, [
    { text: "Hello", offset_ms: 100, duration_ms: 200 }, { text: "world", offset_ms: 600, duration_ms: 250 }]);
  expect(JSON.parse(serializeEvent(edge))).toEqual({ type: "speech_words", utteranceId: "utterance", wordOffset: 0,
    approximate: false, words: [{ text: "Hello", startMs: 100, endMs: 300 }, { text: "world", startMs: 600, endMs: 850 }] });
  expect(timeline.update(1, "שלום again", 2000)).toMatchObject({ wordOffset: 2, approximate: true,
    words: [{ text: "שלום", startMs: 1000, endMs: 2000 }, { text: "again", startMs: 2000, endMs: 3000 }] });
  const aligned = [{ word_index: 0, text: "שלום", offset_ms: 200, duration_ms: 300 },
    { word_index: 1, text: "again", offset_ms: 900, duration_ms: 400 }];
  expect(timeline.update(1, "שלום again", 2000, [], aligned)).toMatchObject({ wordOffset: 2, approximate: false,
    words: [{ startMs: 1200, endMs: 1500 }, { startMs: 1900, endMs: 2300 }] });
  expect(timeline.seek(3, offset_ms => ({ outcome: "accept", offset_ms }))).toMatchObject({ offset_ms: 1900 });
  expect(timeline.seek(4, () => { throw new Error("unsynthesized words must not seek"); })).toMatchObject({ outcome: "reject" });
});

it("marks partial/estimated/invalid timings honestly and makes retries idempotent", () => {
  const timeline = new SpeechWordTimeline("clone");
  expect(timeline.update(0, "One two", 1000, [], [{ word_index: 0, text: "One", offset_ms: null, duration_ms: null }]))
    .toMatchObject({ approximate: true, words: [{ startMs: 0 }, { startMs: 500 }] });
  expect(timeline.update(0, "One two", 1000, [{ text: "One", offset_ms: NaN, duration_ms: 2 }],
    [{ word_index: 1, text: "two", offset_ms: 400, duration_ms: 100, estimated: true }]).approximate).toBe(true);
  let calls = 0;
  const seek = (offset_ms: number) => { calls++; return { outcome: "accept", offset_ms } satisfies ReturnType<SpeechWordTimeline["seek"]>; };
  timeline.seek(1, seek, "retry"); timeline.seek(1, seek, "retry");
  expect(calls).toBe(1);
  expect(timeline.seek(0, seek, "retry")).toMatchObject({ outcome: "reject", reason: "seek id reused" });
});

it("interpolates gaps between measured neighbors without seeking backwards", () => {
  const timeline = new SpeechWordTimeline("partial");
  expect(timeline.update(0, "One two three", 1000, [], [
    { word_index: 0, text: "One", offset_ms: 700, duration_ms: 100 }]))
    .toMatchObject({ approximate: true, words: [{ startMs: 700 }, { startMs: 800, endMs: 900 }, { startMs: 900, endMs: 1000 }] });
  expect(timeline.update(0, "One two three", 1000, [], [
    { word_index: 0, text: "One", offset_ms: 0, duration_ms: 800 },
    { word_index: 2, text: "three", offset_ms: 900, duration_ms: 100 }]))
    .toMatchObject({ approximate: true, words: [{ startMs: 0 }, { startMs: 800, endMs: 900 }, { startMs: 900 }] });
});

it("fences word seek with player reap, replacement, stale identity and Stop without audio", async () => {
  const players = fixtureBarrier<{ argv: string[]; exit: ReturnType<typeof deferred<number>> }>();
  const trims = fixtureBarrier<{ argv: string[]; exit: ReturnType<typeof deferred<number>> }>();
  const events: SocketEvent[] = [];
  const broadcast = spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); });
  const decode = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
    result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
  });
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    const exit = deferred<number>();
    if (argv[0] === "which" || argv[1] === "-version") exit.resolve(0);
    else if (argv.includes("-ss")) trims.push({ argv, exit });
    else players.push({ argv, exit });
    return { pid: 95000, exited: exit.promise, kill() {}, stdout: new Blob(["/fake/ffmpeg"]).stream() };
  }) as typeof Bun.spawn);
  try {
    const source = `${TEST_TMP}/u5-silent.mp3`; writeFileSync(source, "silent fixture");
    const metadata = { text: "One two", voice: "test", durationMs: 1000,
      wordBoundaries: [{ text: "One", offset_ms: 0, duration_ms: 200 }, { text: "two", offset_ms: 500, duration_ms: 200 }] };
    const first = tts.playAudioNonBlocking(source, metadata);
    const original = await players.at(0);
    expect(events.find(event => event.type === "state" && event.state === "speaking")).toMatchObject({ utteranceId: first.id });
    expect(events.find(event => event.type === "speech_words")).toMatchObject({ utteranceId: first.id, approximate: false });
    const command = { cmd: "speech_seek", utteranceId: first.id, wordIndex: 1, id: "word-1" } satisfies Parameters<typeof handleSocketCommand>[0];
    expect(handleSocketCommand(command)).toMatchObject({ command: "speech_seek", outcome: "accept", offset_ms: 500 });
    const trim = await trims.at(0);
    handleSocketCommand(command); await fixtureCheckpoint(); expect(trims.values).toHaveLength(1);
    expect(trim.argv[trim.argv.indexOf("-ss") + 1]).toBe("0.5");
    expect(trim.argv[trim.argv.indexOf("-i") + 1]).toBe(source);
    writeFileSync(trim.argv.at(-1)!, "slice"); trim.exit.resolve(0);
    await fixtureCheckpoint(); expect(players.values).toHaveLength(1);
    original.exit.resolve(143); await players.at(1);
    tts.seekSpeechWord(first.id, 1, "late"); const late = await trims.at(1);
    const replacement = tts.playAudioNonBlocking(source, { ...metadata, priority: "critical" });
    players.values[1].exit.resolve(143);
    writeFileSync(late.argv.at(-1)!, "late"); late.exit.resolve(0); await players.at(2);
    expect(tts.seekSpeechWord(first.id, 0)).toMatchObject({ outcome: "reject", reason: "stale utterance" });
    expect(players.values).toHaveLength(3);
    tts.seekSpeechWord(replacement.id, 1); const stopped = await trims.at(2);
    tts.stopPlayback(); writeFileSync(stopped.argv.at(-1)!, "stopped"); stopped.exit.resolve(0);
    players.values[2].exit.resolve(143); await tts.awaitCurrentPlayback();
    expect(tts.seekSpeechWord(replacement.id, 0)).toMatchObject({ outcome: "reject", reason: "stale utterance" });
    expect(players.values).toHaveLength(3);
  } finally {
    tts.stopPlayback(); for (const item of [...players.values, ...trims.values]) item.exit.resolve(143);
    await tts.awaitCurrentPlayback(); spawn.mockRestore(); decode.mockRestore(); broadcast.mockRestore();
  }
});
