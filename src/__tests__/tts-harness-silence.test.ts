import { describe, it, expect } from "bun:test";
import { buildPlaybackArgv } from "../tts";

// 2026-09-08: Etan heard the Swift replay fixtures out of his speakers twice in
// one afternoon, from release runtime verification on his own Mac. The audible
// path has to be closed structurally, not by an env var a brief asks people to
// set — so the discriminator is the same one the harness already cannot fake:
// a harness always overrides the socket path, and corpus-replay-verify refuses
// to run against the live sockets at all.
describe("playback argv", () => {
  it("is silent when this process is not the resident stack", () => {
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", false)).toEqual([
      "afplay",
      "-v",
      "0",
      "/x/a.mp3",
    ]);
  });

  it("is byte-identical to today for the resident stack — his real dictation must not change", () => {
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", true)).toEqual([
      "afplay",
      "/x/a.mp3",
    ]);
  });

  it("still spawns a process named afplay when muted, so the Swift child-count assertions hold", () => {
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", false)[0]).toBe("afplay");
  });

  it("leaves non-afplay players untouched — -v 0 is not portable", () => {
    expect(buildPlaybackArgv("mpv", "/x/a.mp3", false)).toEqual([
      "mpv",
      "/x/a.mp3",
    ]);
  });
});
