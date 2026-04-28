import { describe, expect, it } from "bun:test";
import { cleanupTranscriptionText } from "../stt-cleanup";

describe("stt-cleanup", () => {
  it("suppresses no-input STT hallucinations and non-speech labels", () => {
    expect(cleanupTranscriptionText("thank you")).toBe("");
    expect(cleanupTranscriptionText("Thank you.")).toBe("");
    expect(cleanupTranscriptionText("sad music")).toBe("");
    expect(cleanupTranscriptionText("Oh, my God.")).toBe("");
    expect(cleanupTranscriptionText("- Oh, my God.")).toBe("");
    expect(cleanupTranscriptionText("-")).toBe("");
    expect(cleanupTranscriptionText("(Music)")).toBe("");
    expect(cleanupTranscriptionText("[music]")).toBe("");
    expect(cleanupTranscriptionText("[music>")).not.toBe("");
    expect(cleanupTranscriptionText("...")).toBe("");
  });

  it("preserves intentional short syntax dictation", () => {
    expect(cleanupTranscriptionText("/ foo")).toBe("/ foo");
    expect(cleanupTranscriptionText("@name")).toBe("@name");
    expect(cleanupTranscriptionText("?")).toBe("?");
    expect(cleanupTranscriptionText("- word")).toBe("- word");
    expect(cleanupTranscriptionText("yes")).not.toBe("");
  });

  it("preserves exact canonical casing for product and agent aliases", () => {
    const cleaned = cleanupTranscriptionText(
      "work claude opened voice layer codex in whisper flow",
    );

    expect(cleaned).toContain("orcClaude");
    expect(cleaned).toContain("VoiceLayerCodex");
    expect(cleaned).toContain("Wispr Flow");
    expect(cleaned).not.toContain("OrcClaude");
  });

  it("covers the strict-score spoken-form misses", () => {
    const cleaned = cleanupTranscriptionText(
      "whisperflow orc clawed orcclawed skill creator clawed seamux cee mux karabiner",
    );

    expect(cleaned).toContain("Wispr Flow");
    expect(cleaned).toContain("orcClaude");
    expect(cleaned).toContain("SkillCreatorClaude");
    expect(cleaned).toContain("cmux");
    expect(cleaned).toContain("Karabiner");
    expect(cleaned).not.toContain("Whisperflow");
    expect(cleaned).not.toContain("OrcClawed");
    expect(cleaned).not.toContain("Seamux");
  });

  it("keeps Meytal and MaiLinh as distinct contacts", () => {
    const cleaned = cleanupTranscriptionText(
      "meital maital may tall maytal mailing mylan myelin mai linh mailinh",
    );

    expect(cleaned).toBe(
      "Meytal Meytal Meytal Meytal MaiLinh MaiLinh MaiLinh MaiLinh MaiLinh",
    );
    expect(cleaned).not.toContain("Meital");
    expect(cleaned).not.toContain("Maital");
    expect(cleaned).not.toContain("mailing");
    expect(cleaned).not.toContain("Mylan");
    expect(cleaned).not.toContain("myelin");
    expect(cleaned).toContain("MaiLinh");
    expect(cleaned).not.toContain("maytal");
  });
});
