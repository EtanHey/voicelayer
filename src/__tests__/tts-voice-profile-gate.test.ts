import { afterEach, describe, expect, it, spyOn } from "bun:test";
import {
  VoiceProfileUnavailableError,
  assertRegisteredClone,
  requireClonedVoiceEnabled,
  speak,
} from "../tts";
import * as qwen3 from "../tts/qwen3";
import * as xtts from "../tts/xtts";
import * as f5tts from "../tts/f5tts";

// Voice-profile fail-closed gate (Track 5 #3). When a caller MANDATES a cloned
// voice (render/narration path), an unavailable clone must FAIL — never silently
// downgrade to a preset/system TTS voice ("cloned voice not used" regression).
// Opt-in so default voice_speak keeps its resilient fallback.

describe("requireClonedVoiceEnabled", () => {
  it("is false by default (no option, no env)", () => {
    expect(requireClonedVoiceEnabled(undefined, {})).toBe(false);
    expect(requireClonedVoiceEnabled({}, {})).toBe(false);
    expect(requireClonedVoiceEnabled({ requireClonedVoice: false }, {})).toBe(
      false,
    );
  });

  it("is true when the option is set", () => {
    expect(requireClonedVoiceEnabled({ requireClonedVoice: true }, {})).toBe(
      true,
    );
  });

  it("is true when QA_VOICE_TTS_REQUIRE_CLONE is truthy", () => {
    expect(
      requireClonedVoiceEnabled(undefined, { QA_VOICE_TTS_REQUIRE_CLONE: "1" }),
    ).toBe(true);
    expect(
      requireClonedVoiceEnabled(undefined, {
        QA_VOICE_TTS_REQUIRE_CLONE: "true",
      }),
    ).toBe(true);
    expect(
      requireClonedVoiceEnabled(undefined, { QA_VOICE_TTS_REQUIRE_CLONE: "0" }),
    ).toBe(false);
  });
});

describe("assertRegisteredClone", () => {
  it("throws VoiceProfileUnavailableError when the profile is not registered", () => {
    let thrown: unknown;
    try {
      assertRegisteredClone("theo-c4", () => false);
    } catch (err) {
      thrown = err;
    }
    expect(thrown).toBeInstanceOf(VoiceProfileUnavailableError);
    expect((thrown as VoiceProfileUnavailableError).voice).toBe("theo-c4");
    expect((thrown as VoiceProfileUnavailableError).reason).toBe(
      "missing-profile",
    );
  });

  it("does not throw when the profile is registered", () => {
    expect(() => assertRegisteredClone("theo-c4", () => true)).not.toThrow();
  });
});

describe("speak fail-closed gate", () => {
  afterEach(() => {
    delete process.env.QA_VOICE_TTS_REQUIRE_CLONE;
  });

  it("fails closed (throws) when a mandated clone has no registered profile — no silent edge-tts fallback", async () => {
    await expect(
      speak("hello there", {
        voice: "__definitely_not_a_registered_clone__",
        requireClonedVoice: true,
      }),
    ).rejects.toBeInstanceOf(VoiceProfileUnavailableError);
  });

  it("honors the QA_VOICE_TTS_REQUIRE_CLONE env as a global fail-closed switch", async () => {
    process.env.QA_VOICE_TTS_REQUIRE_CLONE = "1";
    await expect(
      speak("hello there", { voice: "__no_such_clone__" }),
    ).rejects.toBeInstanceOf(VoiceProfileUnavailableError);
  });

  it("fails closed (synthesis-failed) when a REGISTERED clone fails every synthesis tier", async () => {
    // Registered profile (so it resolves to engine "cloned"), but XTTS/F5
    // unavailable and the Qwen3 daemon returns nothing — the daemon-down
    // regression scenario. A mandate must throw, never downgrade to edge-tts.
    const spies = [
      spyOn(qwen3, "hasClonedProfile").mockReturnValue(true),
      spyOn(qwen3, "loadProfile").mockReturnValue({
        name: "theo-c4",
        engine: "qwen3-tts",
        fallback: "en-US-AndrewNeural",
      } as never),
      spyOn(qwen3, "synthesizeCloned").mockResolvedValue(null),
      spyOn(xtts, "isXTTSAvailable").mockReturnValue(false),
      spyOn(f5tts, "isF5TTSAvailable").mockReturnValue(false),
    ];
    try {
      let thrown: unknown;
      try {
        await speak("hello there", {
          voice: "theo-c4",
          requireClonedVoice: true,
        });
      } catch (err) {
        thrown = err;
      }
      expect(thrown).toBeInstanceOf(VoiceProfileUnavailableError);
      expect((thrown as VoiceProfileUnavailableError).reason).toBe(
        "synthesis-failed",
      );
    } finally {
      for (const s of spies) s.mockRestore();
    }
  });

  it("does NOT fail closed by default (resilient fallback path is preserved)", () => {
    // Without the gate, an unknown voice resolves to the default edge-tts voice;
    // the gate must not change that — only the resolution, not actual playback.
    // (Asserted via requireClonedVoiceEnabled being false; full playback is
    // covered by existing tts tests.)
    expect(
      requireClonedVoiceEnabled({ voice: "__no_such_clone__" } as never, {}),
    ).toBe(false);
  });
});
