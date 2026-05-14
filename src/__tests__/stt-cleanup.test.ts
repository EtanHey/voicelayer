import { describe, expect, it } from "bun:test";
import { cleanupTranscriptionText, getSTTVocabularyPrompt } from "../stt-cleanup";

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

  it("biases STT toward project and domain vocabulary", () => {
    const prompt = getSTTVocabularyPrompt();

    expect(prompt).toContain("cmux");
    expect(prompt).toContain("BrainLayer");
    expect(prompt).toContain("VoiceLayer");
    expect(prompt).toContain("Golems");
    expect(prompt).toContain("T3 Code");
    expect(prompt).toContain("Qelos");
    expect(prompt).toContain("nanoClaw");
    expect(prompt).toContain("Apple Container");
    expect(prompt).toContain("Docker");
    expect(prompt).toContain("Telegram");
    expect(prompt).toContain("WhatsApp");
    expect(prompt).not.toContain("kilos");
    expect(prompt).not.toContain("nanoClawed");
    expect(prompt).not.toContain("nanoclawed");
  });

  it("cleans spoken project and domain aliases to canonical spelling", () => {
    const cleaned = cleanupTranscriptionText(
      "c mux brain layer voice layer golems t three code kilos project nano clawed apple container docker telegram whats app",
    );

    expect(cleaned).toBe(
      "cmux BrainLayer VoiceLayer Golems T3 Code Qelos project nanoClaw Apple Container Docker Telegram WhatsApp",
    );
    expect(cleaned).not.toContain("kilos");
    expect(cleaned).not.toContain("nanoClawed");
    expect(cleaned).not.toContain("nanoclawed");
  });

  it("does not rewrite ordinary kilos weight units as Qelos", () => {
    expect(cleanupTranscriptionText("ship 10 kilos of flour")).toBe(
      "Ship 10 kilos of flour",
    );
  });
});
