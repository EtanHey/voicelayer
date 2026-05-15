import { describe, expect, it } from "bun:test";
import {
  cleanupTranscriptionText,
  getSTTVocabularyPrompt,
} from "../stt-cleanup";

describe("stt-cleanup", () => {
  it("suppresses no-input STT hallucinations and non-speech labels", () => {
    expect(cleanupTranscriptionText("thank you")).toBe("");
    expect(cleanupTranscriptionText("Thank you.")).toBe("");
    expect(cleanupTranscriptionText("thanks for watching")).toBe("");
    expect(cleanupTranscriptionText("[BLANK_AUDIO]")).toBe("");
    expect(cleanupTranscriptionText("[Music playing]")).toBe("");
    expect(cleanupTranscriptionText("subtitle by rev dot com")).toBe("");
    expect(cleanupTranscriptionText("sad music")).toBe("");
    expect(cleanupTranscriptionText("Oh, my God.")).toBe("");
    expect(cleanupTranscriptionText("- Oh, my God.")).toBe("");
    expect(cleanupTranscriptionText("-")).toBe("");
    expect(cleanupTranscriptionText("(Music)")).toBe("");
    expect(cleanupTranscriptionText("[music]")).toBe("");
    expect(cleanupTranscriptionText("[music>")).not.toBe("");
    expect(
      cleanupTranscriptionText("thanks for watching this failing test"),
    ).not.toBe("");
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

  it("cleans YashClaude spoken forms used in agent routing", () => {
    expect(
      cleanupTranscriptionText("ask yash claude to watch the pr loop"),
    ).toBe("Ask YashClaude to watch the pr loop");
    expect(cleanupTranscriptionText("tell yash clawed to review the pr")).toBe(
      "Tell YashClaude to review the pr",
    );
  });

  it("preserves mixed Hebrew and lower-case dev dictation", () => {
    expect(cleanupTranscriptionText("use effect לא עובד")).toBe(
      "useEffect לא עובד",
    );
    expect(cleanupTranscriptionText("on click handler שבור")).toBe(
      "onClick handler שבור",
    );
    expect(cleanupTranscriptionText("bun test נכשל")).toBe("bun test נכשל");
  });

  it("cleans high-confidence Hebrew dev loanwords without romanizing normal prose", () => {
    expect(cleanupTranscriptionText("תעשה פוש לברנץ ותפתח פול ריקווסט")).toBe(
      "תעשה push ל-branch ותפתח Pull Request",
    );
    expect(cleanupTranscriptionText("צריך פונקציה חדשה עם טסטים")).toBe(
      "צריך פונקציה חדשה עם טסטים",
    );
  });

  it("keeps Hebrew discourse markers while removing acoustic fillers", () => {
    expect(cleanupTranscriptionText("אני רוצה כאילו שזה יישאר בעברית")).toBe(
      "אני רוצה כאילו שזה יישאר בעברית",
    );
    expect(cleanupTranscriptionText("אמ אני חושב אה שזה עובד")).toBe(
      "אני חושב שזה עובד",
    );
  });

  it("does not corrupt Hebrew words that start with אמ/אה (regression: אמש 'last night')", () => {
    // The filler regex must not match the prefix of legitimate words like
    // אמש (last night) or אהבה (love). Previously the lookahead
    // `(?=\s|ש|$)` allowed `אמ` in `אמש` to match, leaving a stray `ש`.
    expect(cleanupTranscriptionText("ראיתי אותו אמש")).toBe("ראיתי אותו אמש");
    expect(cleanupTranscriptionText("לפני אמש פגשתי")).toBe("לפני אמש פגשתי");
    expect(cleanupTranscriptionText("אהבה לכל")).toBe("אהבה לכל");
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

  it("cleans Codex session-mining dictation without rewriting ordinary codecs", () => {
    expect(
      cleanupTranscriptionText(
        "if it's sessions of codecs i need to save them so we can do session mining",
      ),
    ).toBe(
      "If it's sessions of Codex I need to save them so we can do session mining",
    );

    expect(cleanupTranscriptionText("audio codecs need testing")).toBe(
      "Audio codecs need testing",
    );
  });

  it("cleans BrainLayer coordination terms from long dictation", () => {
    expect(
      cleanupTranscriptionText(
        "go back to orc claud and ask whether pending cues are working",
      ),
    ).toBe("Go back to orcClaude and ask whether pending queues are working");

    expect(
      cleanupTranscriptionText(
        "go back to orcclaud and ask the skill creator claude",
      ),
    ).toBe("Go back to orcClaude and ask the SkillCreatorClaude");

    expect(
      cleanupTranscriptionText(
        "ask or claude whether pending cues are working in brain layer",
      ),
    ).toBe("Ask orcClaude whether pending queues are working in BrainLayer");

    expect(
      cleanupTranscriptionText(
        "then tell or claude whether pending cues are working",
      ),
    ).toBe("Then tell orcClaude whether pending queues are working");

    expect(cleanupTranscriptionText("ask Gemini or Claude")).toBe(
      "Ask Gemini or Claude",
    );

    expect(cleanupTranscriptionText("please ask or claude about this")).toBe(
      "Please ask orcClaude about this",
    );
  });

  it("does not rewrite ordinary audio/UI cues as queues", () => {
    expect(
      cleanupTranscriptionText("there are three pending cues for playback"),
    ).toBe("There are 3 pending cues for playback");

    expect(cleanupTranscriptionText("pending cues for the recorder")).toBe(
      "Pending cues for the recorder",
    );

    expect(
      cleanupTranscriptionText("check if pending cues are processed"),
    ).toBe("Check if pending cues are processed");
  });

  it("preserves sentence-start capitalization for converted aliases", () => {
    expect(cleanupTranscriptionText("pending cues are working")).toBe(
      "Pending queues are working",
    );

    expect(
      cleanupTranscriptionText("pending cues are working in brain layer"),
    ).toBe("Pending queues are working in BrainLayer");
  });

  it("formats certainty percentages in migration planning dictation", () => {
    expect(cleanupTranscriptionText("i'm not a hundred percent sure")).toBe(
      "I'm not 100% sure",
    );
    expect(cleanupTranscriptionText("i'm not 100 sure")).toBe(
      "I'm not 100% sure",
    );
    expect(
      cleanupTranscriptionText("there are two sure ways to fix this"),
    ).toBe("There are 2 sure ways to fix this");
  });

  it("removes article from 'a hundred percent' with trailing punctuation", () => {
    expect(cleanupTranscriptionText("i am a hundred percent.")).toBe(
      "I am 100%.",
    );
    expect(cleanupTranscriptionText("not a hundred percent!")).toBe(
      "Not 100%!",
    );
    expect(cleanupTranscriptionText("are you a hundred percent?")).toBe(
      "Are you 100%?",
    );
  });

  it("preserves article in ordinary percent adjective phrases", () => {
    expect(cleanupTranscriptionText("a hundred percent reliable fix")).toBe(
      "A 100% reliable fix",
    );
    expect(cleanupTranscriptionText("it's a hundred percent improvement")).toBe(
      "It's a 100% improvement",
    );
    expect(cleanupTranscriptionText("we need a hundred percent uptime")).toBe(
      "We need a 100% uptime",
    );
  });
});
