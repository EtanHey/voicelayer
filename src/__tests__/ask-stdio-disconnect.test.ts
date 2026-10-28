import { expect, it } from "bun:test";
import { deferredFixture as deferred } from "./long-read-fixture-barriers";

it("stdio EOF during the question shuts down without opening capture", async () => {
  const child = Bun.spawn([process.execPath, "--preload", "./src/__tests__/setup/preload.ts", "-e", `
    import { spyOn } from "bun:test";
    import * as tts from "./src/tts";
    import * as amplitude from "./src/playback-amplitude";
    import * as input from "./src/input";
    import * as booking from "./src/session-booking";
    import * as socket from "./src/socket-client";
    import * as stt from "./src/stt";
    import * as archives from "./src/speech-archive-live";
    import { TEST_TMP } from "./src/__tests__/setup/test-tmp";
    spyOn(archives, "flushSpeechArchives").mockImplementation(async () => { await Bun.sleep(50); });
    spyOn(stt, "getBackend").mockRejectedValue(new Error("fixture backend"));
    spyOn(socket, "connectToBar").mockImplementation(() => {});
    spyOn(socket, "isConnected").mockReturnValue(true);
    spyOn(socket, "broadcast").mockImplementation(() => {});
    spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true });
    spyOn(input, "clearInput").mockImplementation(() => {});
    spyOn(input, "waitForInput").mockImplementation(async () => {
      console.error("UNEXPECTED_CAPTURE");
      return "fixture answer";
    });
    spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
      result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
    });
    spyOn(Bun, "spawn").mockImplementation(argv => {
      if (argv[0] === "which") return { pid: 1, exited: Promise.resolve(0), stdout: new Blob(["/fake/ffmpeg"]).stream(), kill() {} };
      let resolveExit;
      const exited = new Promise(resolve => { resolveExit = resolve; });
      console.error("PLAYER_READY");
      return { pid: 9000, exited, kill() { setTimeout(() => resolveExit(143), 10); } };
    });
    spyOn(tts, "speak").mockImplementation(async (text, options) => {
      const handle = tts.playAudioNonBlocking(TEST_TMP + "/ask.mp3", {
        text, voice: "fixture", durationMs: 600000, priority: "critical", onQueued: options?.onPlaybackQueued,
      });
      return { playbackId: handle.id, playbackOutcome: await handle.exited, displayText: text,
        engine: "edge-tts", voice: "fixture", audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" } };
    });
    await import("./src/mcp-server");
  `], { env: process.env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const ready = deferred<void>();
  let diagnostics = "";
  const stderr = (async () => {
    const reader = child.stderr.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      diagnostics += decoder.decode(value, { stream: true });
      if (diagnostics.includes("PLAYER_READY")) ready.resolve();
    }
  })();
  const stdout = new Response(child.stdout).text();
  try {
    child.stdin.write([
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "fixture", version: "1" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "voice_ask", arguments: { message: "Question?" } } },
    ].map(message => JSON.stringify(message) + "\n").join(""));
    child.stdin.flush();
    await Promise.race([ready.promise, child.exited.then(code => { throw new Error(`server exited before its player: ${code} ${diagnostics}`); })]);
    child.stdin.end();
    expect(await child.exited).toBe(0);
    await stderr;
    expect(diagnostics).not.toContain("UNEXPECTED_CAPTURE");
    expect(diagnostics).not.toContain("shutdown playback settlement incomplete");
  } finally {
    if (child.exitCode === null) child.kill("SIGKILL");
    await child.exited;
    await Promise.all([stdout, stderr]);
  }
});
