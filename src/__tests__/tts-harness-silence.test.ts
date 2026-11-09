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

  it("T9: a scaled resident speed plays through SoX's pitch-preserving WSOLA tempo with 20/5/8 ms windows", () => {
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", true, 1.5, "/opt/homebrew/bin/play")).toEqual([
      "/opt/homebrew/bin/play", "-q", "/x/a.mp3", "tempo", "-s", "1.5", "20", "5", "8",
    ]);
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", true, 0.75, "/opt/homebrew/bin/play").slice(-5)).toEqual(["-s", "0.75", "20", "5", "8"]);
  });

  it("T9: 1× stays byte-identical afplay; a missing SoX falls back to afplay's time-pitch", () => {
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", true, 1, "/opt/homebrew/bin/play")).toEqual(["afplay", "/x/a.mp3"]);
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", true, 1.5, null)).toEqual(["afplay", "-r", "1.5", "-q", "1", "/x/a.mp3"]);
  });

  it("T9: a harness (not the resident stack) stays a muted afplay at any speed", () => {
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", false, 1.5, "/opt/homebrew/bin/play")).toEqual([
      "afplay", "-v", "0", "-r", "1.5", "-q", "1", "/x/a.mp3",
    ]);
  });

  it("leaves non-afplay players untouched — -v 0 is not portable", () => {
    expect(buildPlaybackArgv("mpv", "/x/a.mp3", false)).toEqual([
      "mpv",
      "/x/a.mp3",
    ]);
  });
});
