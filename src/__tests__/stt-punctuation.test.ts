import { describe, expect, test } from "bun:test";
import { restoreSentencePunctuation } from "../stt-punctuation";
import { finalizeTranscriptionText } from "../input";

// Regression: VoiceLayer transcriptions came back with ZERO terminal punctuation
// when the LLM polish server is unavailable (Etan, 2026-06-21: "back to ZERO
// punctuation ... no commas, no periods"). The deterministic restorer guarantees
// sentence-terminal punctuation in the DEFAULT path, independent of the polish
// server, so bare whisper output is never delivered un-terminated.

describe("restoreSentencePunctuation", () => {
  test("appends a period to a bare declarative", () => {
    expect(restoreSentencePunctuation("I fixed the bug")).toBe(
      "I fixed the bug.",
    );
  });

  test("appends a question mark to a bare wh-question", () => {
    expect(restoreSentencePunctuation("Why did it do that")).toBe(
      "Why did it do that?",
    );
    expect(restoreSentencePunctuation("How are you doing today")).toBe(
      "How are you doing today?",
    );
  });

  test("leaves already-terminated text unchanged", () => {
    expect(restoreSentencePunctuation("I fixed the bug.")).toBe(
      "I fixed the bug.",
    );
    expect(restoreSentencePunctuation("Did it work?")).toBe("Did it work?");
    expect(restoreSentencePunctuation("Stop!")).toBe("Stop!");
  });

  test("preserves internal punctuation and only fixes the missing terminal", () => {
    expect(
      restoreSentencePunctuation("Look in the collab, look in the large plan"),
    ).toBe("Look in the collab, look in the large plan.");
  });

  test("converts a dangling trailing comma into a terminal period", () => {
    expect(restoreSentencePunctuation("Push the branch,")).toBe(
      "Push the branch.",
    );
  });

  test("respects terminal punctuation followed by a closing quote/paren", () => {
    expect(restoreSentencePunctuation('He said "go."')).toBe('He said "go."');
    expect(restoreSentencePunctuation("(see the notes.)")).toBe(
      "(see the notes.)",
    );
  });

  test("treats yes/no-style aux-pronoun openers as questions", () => {
    expect(restoreSentencePunctuation("do you want this")).toBe(
      "do you want this?",
    );
    expect(restoreSentencePunctuation("is this correct")).toBe(
      "is this correct?",
    );
    expect(restoreSentencePunctuation("should I merge it")).toBe(
      "should I merge it?",
    );
  });

  test("detects contracted/negated aux question openers", () => {
    expect(restoreSentencePunctuation("isn't it working")).toBe(
      "isn't it working?",
    );
    expect(restoreSentencePunctuation("don't you think")).toBe(
      "don't you think?",
    );
    // apostrophe-less form whisper sometimes emits
    expect(restoreSentencePunctuation("cant we merge it")).toBe(
      "cant we merge it?",
    );
  });

  test("does NOT statement-ize an imperative that opens with a bare aux", () => {
    // "do not ..." is an imperative, not a question — must get a period.
    expect(restoreSentencePunctuation("do not use wait_for_all")).toBe(
      "do not use wait_for_all.",
    );
    expect(restoreSentencePunctuation("have a nice day")).toBe(
      "have a nice day.",
    );
  });

  test("terminates spoken alternatives/fractions containing a single slash", () => {
    expect(restoreSentencePunctuation("yes/no")).toBe("yes/no.");
    expect(restoreSentencePunctuation("and/or")).toBe("and/or.");
  });

  test("leaves real path/identifier tokens verbatim", () => {
    expect(restoreSentencePunctuation("a/b/c")).toBe("a/b/c");
    expect(restoreSentencePunctuation("src/input.ts")).toBe("src/input.ts");
    expect(restoreSentencePunctuation("./scripts/run.sh")).toBe(
      "./scripts/run.sh",
    );
  });

  test("never appends to a bare slash command or @mention", () => {
    expect(restoreSentencePunctuation("/whats-new")).toBe("/whats-new");
    expect(restoreSentencePunctuation("@orcClaude")).toBe("@orcClaude");
  });

  test("does not append to a bare single code/path token", () => {
    expect(restoreSentencePunctuation("~/Gits/voicelayer")).toBe(
      "~/Gits/voicelayer",
    );
  });

  test("appends a terminal period after a sentence ending in a path", () => {
    expect(restoreSentencePunctuation("Look in ~/Gits/voicelayer")).toBe(
      "Look in ~/Gits/voicelayer.",
    );
  });

  test("does not append after an abbreviation already ending in a dot", () => {
    expect(restoreSentencePunctuation("Edit the CLAUDE.md")).toBe(
      "Edit the CLAUDE.md.",
    );
  });

  test("empty / whitespace input returns empty string", () => {
    expect(restoreSentencePunctuation("")).toBe("");
    expect(restoreSentencePunctuation("   ")).toBe("");
  });

  test("preserves Hebrew + code tokens, appends terminal", () => {
    expect(restoreSentencePunctuation("תרים את ה-handleSocketCommand")).toBe(
      "תרים את ה-handleSocketCommand.",
    );
  });
});

describe("finalizeTranscriptionText restores punctuation in the default path", () => {
  test("bare whisper output gets terminal punctuation (corrector off = default)", () => {
    const env = { QA_VOICE_CORRECTOR: "off" } as Record<string, string>;
    const out = finalizeTranscriptionText(
      "hello world how are you doing today i'm fine thanks",
      env,
    );
    expect(out).toMatch(/[.?!]$/);
  });

  test("bare wh-question gets a question mark in the default path", () => {
    const env = { QA_VOICE_CORRECTOR: "off" } as Record<string, string>;
    const out = finalizeTranscriptionText("why did it do that", env);
    expect(out.endsWith("?")).toBe(true);
  });

  test("preserves every audited content-word filler candidate by default", () => {
    const env = {
      QA_VOICE_CORRECTOR: "off",
      VOICELAYER_STT_AGGRESSIVE_FILLERS: "0",
    } as Record<string, string>;
    const cases: Array<[string, string]> = [
      ["this is basically working", "This is basically working."],
      ["this is essentially working", "This is essentially working."],
      ["this is actually working", "This is actually working."],
      ["this is literally working", "This is literally working."],
      ["this is kind of working", "This is kind of working."],
      ["this is sort of working", "This is sort of working."],
      ["it's like really fast", "It's like really fast."],
      ["like this post", "Like this post."],
      ["what does it look like", "What does it look like?"],
    ];

    for (const [input, expected] of cases) {
      expect(finalizeTranscriptionText(input, env), input).toBe(expected);
    }
  });

  test("still removes genuine acoustic disfluencies by default", () => {
    expect(
      finalizeTranscriptionText("um this uh is er still ah working", {
        QA_VOICE_CORRECTOR: "off",
        VOICELAYER_STT_AGGRESSIVE_FILLERS: "0",
      }),
    ).toBe("This is still working.");
  });

  test("allows aggressive filler removal through the canonical env opt-in", () => {
    expect(
      finalizeTranscriptionText("this is basically working", {
        QA_VOICE_CORRECTOR: "off",
        VOICELAYER_STT_AGGRESSIVE_FILLERS: "1",
      }),
    ).toBe("This is working.");
  });

  test("allows aggressive filler removal through the QA env alias", () => {
    expect(
      finalizeTranscriptionText("this is basically working", {
        QA_VOICE_CORRECTOR: "off",
        QA_VOICE_STT_AGGRESSIVE_FILLERS: "1",
      }),
    ).toBe("This is working.");
  });

  test("canonical aggressive-filler config takes precedence over the QA alias", () => {
    expect(
      finalizeTranscriptionText("this is basically working", {
        QA_VOICE_CORRECTOR: "off",
        VOICELAYER_STT_AGGRESSIVE_FILLERS: "0",
        QA_VOICE_STT_AGGRESSIVE_FILLERS: "1",
      }),
    ).toBe("This is basically working.");
  });

  test("an empty canonical aggressive-filler value falls through to the QA alias", () => {
    expect(
      finalizeTranscriptionText("this is basically working", {
        QA_VOICE_CORRECTOR: "off",
        VOICELAYER_STT_AGGRESSIVE_FILLERS: "",
        QA_VOICE_STT_AGGRESSIVE_FILLERS: "1",
      }),
    ).toBe("This is working.");
  });
});
