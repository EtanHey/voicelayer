import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, symlinkSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  cleanupTranscriptionText,
  getSTTVocabularyPrompt,
} from "../stt-cleanup";
import { addAlias } from "../stt-vocabulary-store";

describe("stt-cleanup", () => {
  // Tests that assert deterministic BUILTIN_STT_ALIASES behavior call
  // cleanupTranscriptionText() with no env, so they fall back to process.env
  // and would otherwise pick up the developer's live STT vocabulary snapshot
  // at ~/.local/state/voicelayer/stt-vocabulary.json. Per the "snapshot wins"
  // alias-merge rule a stale snapshot alias (e.g. "voice layer codex" ->
  // "VoiceLayerCodex") silently overrides the canonical builtin and flips these
  // assertions on a per-machine basis. Kill-switch the snapshot for the whole
  // block (tests that exercise snapshot behavior pass their own explicit env).
  let previousVocabularyPath: string | undefined;
  beforeAll(() => {
    previousVocabularyPath = process.env.QA_VOICE_STT_VOCABULARY_PATH;
    process.env.QA_VOICE_STT_VOCABULARY_PATH = "";
  });
  afterAll(() => {
    if (previousVocabularyPath === undefined) {
      delete process.env.QA_VOICE_STT_VOCABULARY_PATH;
    } else {
      process.env.QA_VOICE_STT_VOCABULARY_PATH = previousVocabularyPath;
    }
  });

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
    expect(cleaned).toContain("voicelayerCodex");
    expect(cleaned).toContain("Wispr Flow");
    expect(cleaned).not.toContain("OrcClaude");
  });

  it("normalizes repoGolem layer aliases without splitting the entity names", () => {
    const cleaned = cleanupTranscriptionText(
      "send a new narration layer codex to compare brain layer codex, voice layer codex, and cmux layer codex",
    );

    expect(cleaned).toBe(
      "Send a new narrationlayerCodex to compare brainlayerCodex, voicelayerCodex, and cmuxlayerCodex",
    );
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

  it("normalizes the Constitution-gated Phase-0 mined aliases", () => {
    const cases: Array<[input: string, expected: string]> = [
      ["use brain lair now", "Use BrainLayer now"],
      ["use brain lear now", "Use BrainLayer now"],
      ["use bearing layer now", "Use BrainLayer now"],
      ["use narration layer now", "Use NarrationLayer now"],
      ["use tailscale now", "Use Tailscale now"],
      ["use olama now", "Use Ollama now"],
      ["use comfy ui now", "Use ComfyUI now"],
      ["use notebook lm now", "Use NotebookLM now"],
      ["use notebook l m now", "Use NotebookLM now"],
      ["use notebook-lm now", "Use NotebookLM now"],
      ["use chroma db now", "Use ChromaDB now"],
      ["use carpathy now", "Use Karpathy now"],
      ["use fts5 now", "Use FTS5 now"],
      ["use fts 5 now", "Use FTS5 now"],
      ["use rrf now", "Use RRF now"],
      ["use esculite now", "Use SQLite now"],
      ["use sq lite now", "Use SQLite now"],
      ["use quen 3 now", "Use Qwen3 now"],
      ["use qwen 3 now", "Use Qwen3 now"],
      ["use quen 3 tts now", "Use Qwen3 TTS now"],
      ["use qwen 3 tts now", "Use Qwen3 TTS now"],
      ["use gwen engine now", "Use Qwen engine now"],
      ["use claw.md now", "Use CLAUDE.md now"],
      ["use claw dot md now", "Use CLAUDE.md now"],
      ["use clawed desktop now", "Use Claude Desktop now"],
      ["use claw desktop now", "Use Claude Desktop now"],
      ["use orkclaud now", "Use orcClaude now"],
      ["use cmuxs now", "Use cmux now"],
      ["use bnaya now", "Use Benaya now"],
      ["use sagitt now", "Use Sagit now"],
      [
        "use if they eyes bg large now",
        "Use Ivrit AI's BG Large now",
      ],
    ];

    for (const [input, expected] of cases) {
      expect(cleanupTranscriptionText(input), input).toBe(expected);
    }
  });

  it("cleans YashClaude spoken forms used in agent routing", () => {
    expect(
      cleanupTranscriptionText("ask yash claude to watch the pr loop"),
    ).toBe("Ask YashClaude to watch the pr loop");
    expect(cleanupTranscriptionText("tell yash clawed to review the pr")).toBe(
      "Tell YashClaude to review the pr",
    );
  });

  it("normalizes repoGolem spawn flags glued onto an agent token", () => {
    // Whisper renders dictated "-s -c" as an upper-cased, space-less suffix
    // ("-S-C") glued to the camelCase agent identifier. Recovered verbatim from
    // ~/.local/share/voicelayer/recordings/2026-06-15 (ab7eaf75, e6aba757).
    expect(cleanupTranscriptionText("voicelayerCodex-S")).toBe(
      "voicelayerCodex -s",
    );
    expect(cleanupTranscriptionText("voicelayerCodex-S-C")).toBe(
      "voicelayerCodex -s -c",
    );
    // Recovered verbatim ends "Let's try one more. Happy Camper Orc Claude-S-C."
    expect(
      cleanupTranscriptionText("Let's try one more. happycampr orcClaude-S-C"),
    ).toBe("Let's try one more. Happycampr orcClaude -s -c");
    // The agent-name canonicalizer first folds "voice layer Codex" ->
    // "voicelayerCodex"; the glued flag suffix must still be split off.
    expect(cleanupTranscriptionText("voice layer Codex-S-C")).toBe(
      "voicelayerCodex -s -c",
    );
  });

  it("normalizes loosely-spaced repoGolem spawn flags after an agent token", () => {
    expect(cleanupTranscriptionText("voicelayerCodex - S - C")).toBe(
      "voicelayerCodex -s -c",
    );
    expect(cleanupTranscriptionText("orcClaude dash s dash c")).toBe(
      "orcClaude -s -c",
    );
    expect(cleanupTranscriptionText("brainlayerClaude -w")).toBe(
      "brainlayerClaude -w",
    );
  });

  it("does not touch dash-letter flags or letters in ordinary prose", () => {
    expect(cleanupTranscriptionText("remember to pass the -s flag")).toBe(
      "Remember to pass the -s flag",
    );
    expect(cleanupTranscriptionText("we can do plan A or plan C")).toBe(
      "We can do plan A or plan C",
    );
    expect(cleanupTranscriptionText("the build is -S today")).not.toContain(
      "-s",
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

  it("cleans path-token spacing and preserved path terms from live dictation", () => {
    expect(
      cleanupTranscriptionText(
        "Wait, what? Obsidian Vault is in -, is it ~ /.Golems - brain / zigon, what?",
      ),
    ).toBe("Wait, what? Obsidian Vault is in ~/.golems-brain/zikaron, what?");
    expect(cleanupTranscriptionText("keep the and/or wording")).toBe(
      "Keep the and/or wording",
    );
  });

  it("preserves leading-dot filename tokens as separate tokens", () => {
    expect(
      cleanupTranscriptionText("Also, if I say the .at file. Thank you."),
    ).toBe("Also, if I say the .at file. Thank you.");
    expect(cleanupTranscriptionText("Use the .env file next.")).toBe(
      "Use the .env file next.",
    );
  });

  it("seeds Hebrew script preserved terms for tax and location dictation", () => {
    expect(cleanupTranscriptionText("Osek Patur")).toBe("עוסק פטור");
    expect(cleanupTranscriptionText("Reshut HaMisim")).toBe("רשות המסים");
    expect(cleanupTranscriptionText("Rechovot")).toBe("רחובות");
    expect(cleanupTranscriptionText("Osekpatur bereshutamisin")).toBe(
      "עוסק פטור ברשות המסים",
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
    expect(prompt).toContain("zikaron");
    expect(prompt).toContain("golems-brain");
    expect(prompt).toContain("~/.golems-brain/zikaron");
    expect(prompt).toContain("עוסק פטור");
    expect(prompt).toContain("רשות המסים");
    expect(prompt).toContain("רחובות");
    expect(prompt).not.toContain("kilos");
    expect(prompt).not.toContain("nanoClawed");
    expect(prompt).not.toContain("nanoclawed");
  });

  it("caps the STT vocabulary prompt at the whisper initial-prompt budget", () => {
    // Constitution DNV#12: never exceed ~224 whisper tokens (~900 chars) in the
    // vocabulary/initial prompt. whisper silently truncates an oversized prompt
    // AND an over-stuffed prompt degrades decode quality.
    const commandsDir = mkdtempSync(
      join(tmpdir(), "voicelayer-stt-prompt-cap-"),
    );
    try {
      // Mock 60+ installed slash-commands plus a fat user vocabulary snapshot to
      // force the assembled term list far past the budget.
      for (let i = 0; i < 60; i += 1) {
        symlinkSync(
          "/dev/null",
          join(commandsDir, `installed-command-number-${i}.md`),
        );
      }
      const snapshotPath = join(commandsDir, "snapshot.json");
      // A realistic curated user vocabulary (a handful of terms) plus the full
      // builtin set plus 60 installed slash-commands still vastly exceeds the
      // budget without the cap (~4400 chars in the real environment).
      const userPromptTerms = ["Domica", "SongScript", "Mehayom", "TechGym"];
      Bun.write(
        snapshotPath,
        JSON.stringify({ prompt_terms: userPromptTerms, aliases: [] }),
      );

      const env = {
        QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
        QA_VOICE_STT_COMMANDS_DIR: commandsDir,
      } as const;

      const prompt = getSTTVocabularyPrompt(env);

      expect(prompt.length).toBeLessThanOrEqual(900);

      // ~224 token budget: estimate via the conservative whitespace/char heuristic.
      const estimatedTokens = Math.ceil(prompt.length / 4);
      expect(estimatedTokens).toBeLessThanOrEqual(224);

      // High-value proper nouns whisper mishears MUST survive the cap.
      expect(prompt).toContain("orcClaude");
      expect(prompt).toContain("voicelayerCodex");
      expect(prompt).toContain("BrainLayer");
      expect(prompt).toContain("VoiceLayer");
      expect(prompt).toContain("Tailscale");

      // Slash-command "/..." entries must NOT consume the scarce decode budget.
      expect(prompt).not.toContain("/installed-command-number");
      for (const term of prompt.split(", ")) {
        expect(term.startsWith("/")).toBe(false);
      }
    } finally {
      rmSync(commandsDir, { recursive: true, force: true });
    }
  });

  it("prioritizes user prompt_terms when capping the vocabulary prompt", () => {
    const commandsDir = mkdtempSync(
      join(tmpdir(), "voicelayer-stt-prompt-cap-priority-"),
    );
    try {
      const snapshotPath = join(commandsDir, "snapshot.json");
      Bun.write(
        snapshotPath,
        JSON.stringify({
          prompt_terms: ["Domica", "SongScript"],
          aliases: [],
        }),
      );

      const env = {
        QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
        QA_VOICE_STT_COMMANDS_DIR: commandsDir,
      } as const;

      const prompt = getSTTVocabularyPrompt(env);
      expect(prompt.length).toBeLessThanOrEqual(900);
      // User-curated terms have highest priority — always retained.
      expect(prompt).toContain("Domica");
      expect(prompt).toContain("SongScript");
    } finally {
      rmSync(commandsDir, { recursive: true, force: true });
    }
  });

  it("never throws on empty or oversized vocabulary inputs", () => {
    expect(() =>
      getSTTVocabularyPrompt({
        QA_VOICE_STT_VOCABULARY_PATH: "",
        QA_VOICE_STT_COMMANDS_DIR: "",
      }),
    ).not.toThrow();

    const commandsDir = mkdtempSync(
      join(tmpdir(), "voicelayer-stt-prompt-cap-empty-"),
    );
    try {
      const snapshotPath = join(commandsDir, "snapshot.json");
      Bun.write(
        snapshotPath,
        JSON.stringify({
          prompt_terms: Array.from(
            { length: 500 },
            (_unused, i) => `HugeTerm${i}`,
          ),
          aliases: [],
        }),
      );
      const env = {
        QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
        QA_VOICE_STT_COMMANDS_DIR: commandsDir,
      } as const;
      expect(() => getSTTVocabularyPrompt(env)).not.toThrow();
      expect(getSTTVocabularyPrompt(env).length).toBeLessThanOrEqual(900);
    } finally {
      rmSync(commandsDir, { recursive: true, force: true });
    }
  });

  it("loads prompt terms from the VoiceBar vocabulary snapshot", async () => {
    const snapshotPath = "/tmp/voicelayer-stt-vocabulary-prompt-test.json";
    await Bun.write(
      snapshotPath,
      JSON.stringify({
        entries: [
          { canonical: "Domica", variants: [] },
          { canonical: "SongScript", variants: [] },
        ],
      }),
    );

    const prompt = getSTTVocabularyPrompt({
      QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
    });

    expect(prompt).toContain("Domica");
    expect(prompt).toContain("SongScript");
    expect(prompt).toContain("cmux");
  });

  it("keeps cleanup-only phrase aliases out of the STT vocabulary prompt", () => {
    const prompt = getSTTVocabularyPrompt({
      QA_VOICE_STT_VOCABULARY_PATH: "",
    });

    expect(prompt).not.toContain("still expect VoiceLayer to keep");
    expect(prompt).not.toContain("real tail of the sentence");
    expect(prompt).toContain("VoiceLayer");
  });

  it("allows callers to disable the VoiceBar vocabulary snapshot", async () => {
    const snapshotPath = "/tmp/voicelayer-stt-vocabulary-disabled-test.json";
    await Bun.write(
      snapshotPath,
      JSON.stringify({
        entries: [{ canonical: "Domica", variants: ["domekin"] }],
      }),
    );

    expect(
      getSTTVocabularyPrompt({
        QA_VOICE_STT_VOCABULARY_PATH: "",
      }),
    ).not.toContain("Domica");
    expect(
      cleanupTranscriptionText("use domekin", {
        QA_VOICE_STT_VOCABULARY_PATH: "",
      }),
    ).toBe("Use domekin");
    expect(
      getSTTVocabularyPrompt({
        QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
      }),
    ).toContain("Domica");
  });

  it("applies aliases from the VoiceBar vocabulary snapshot", async () => {
    const snapshotPath = "/tmp/voicelayer-stt-vocabulary-alias-test.json";
    await Bun.write(
      snapshotPath,
      JSON.stringify({
        entries: [
          { canonical: "Domica", variants: ["domekin"] },
          { canonical: "SongScript", variants: ["song strip"] },
        ],
      }),
    );

    expect(
      cleanupTranscriptionText("use domekin and song strip", {
        QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
      }),
    ).toBe("Use Domica and SongScript");
  });

  it("loads an alias added after a missing snapshot on the next transcription", () => {
    const tempDir = mkdtempSync(
      join(tmpdir(), "voicelayer-stt-vocabulary-live-"),
    );
    const snapshotPath = join(tempDir, "stt-vocabulary.json");
    const env = {
      QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
      QA_VOICE_STT_COMMANDS_DIR: "",
    } as const;

    try {
      expect(cleanupTranscriptionText("use domekin", env)).toBe("Use domekin");

      addAlias({ from: "domekin", to: "Domica" }, { path: snapshotPath });

      expect(cleanupTranscriptionText("use domekin", env)).toBe("Use Domica");
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });

  it("derives spoken slash-command aliases from vocabulary prompt terms", async () => {
    const snapshotPath =
      "/tmp/voicelayer-stt-vocabulary-slash-command-test.json";
    await Bun.write(
      snapshotPath,
      JSON.stringify({
        entries: [
          { canonical: "/whats-new", variants: [] },
          { canonical: "/large-plan", variants: [] },
        ],
      }),
    );

    const env = {
      QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
      QA_VOICE_STT_COMMANDS_DIR: "",
    } as const;

    expect(
      cleanupTranscriptionText(
        "also, do / what's new and output that as your summary",
        env,
      ),
    ).toBe("Also, do /whats-new and output that as your summary");
    expect(cleanupTranscriptionText("do slash large plan next", env)).toBe(
      "Do /large-plan next",
    );
  });

  it("loads slash-command aliases from installed Claude commands when the snapshot is stale", async () => {
    const commandsDir = mkdtempSync(join(tmpdir(), "voicelayer-stt-commands-"));
    const commandTargetDir = mkdtempSync(
      join(tmpdir(), "voicelayer-stt-command-target-"),
    );
    await Bun.$`mkdir -p ${commandsDir}/frontend`;
    await Bun.$`mkdir -p ${commandsDir}/.git/hooks`;
    await Bun.$`mkdir -p ${commandsDir}/design/references`;
    await Bun.$`mkdir -p ${commandsDir}/large-plan`;
    await Bun.$`mkdir -p ${commandTargetDir}`;
    await Bun.write(join(commandsDir, "whats-new.md"), "# /whats-new");
    await Bun.write(join(commandsDir, "README.md"), "# support doc");
    await Bun.write(
      join(commandsDir, "frontend", "component.md"),
      "# /component",
    );
    await Bun.write(
      join(commandsDir, "large-plan", "SKILL.md"),
      "# /large-plan",
    );
    await Bun.write(join(commandTargetDir, "SKILL.md"), "# /skill-creator");
    await Bun.write(
      join(commandsDir, ".git", "hooks", "pre-commit.md"),
      "# internal",
    );
    await Bun.write(
      join(commandsDir, "design", "references", "icon-design.md"),
      "# support doc",
    );
    await Bun.write(join(commandsDir, "LICENSE"), "not a slash command");
    symlinkSync(commandTargetDir, join(commandsDir, "skill-creator"));

    try {
      const env = {
        QA_VOICE_STT_VOCABULARY_PATH: "",
        QA_VOICE_STT_COMMANDS_DIR: commandsDir,
      } as const;

      expect(cleanupTranscriptionText("also, do / what's new", env)).toBe(
        "Also, do /whats-new",
      );
      expect(cleanupTranscriptionText("run slash component", env)).toBe(
        "Run /component",
      );
      expect(cleanupTranscriptionText("run slash large plan", env)).toBe(
        "Run /large-plan",
      );
      expect(cleanupTranscriptionText("run slash skill creator", env)).toBe(
        "Run /skill-creator",
      );
      expect(cleanupTranscriptionText("run slash frontend", env)).toBe(
        "Run / frontend",
      );
      expect(getSTTVocabularyPrompt(env)).not.toContain("/pre-commit");
      expect(getSTTVocabularyPrompt(env)).not.toContain("/LICENSE");
      expect(getSTTVocabularyPrompt(env)).not.toContain("/README");
      expect(getSTTVocabularyPrompt(env)).not.toContain("/icon-design");
    } finally {
      rmSync(commandsDir, { recursive: true, force: true });
      rmSync(commandTargetDir, { recursive: true, force: true });
    }
  });

  it("cleans context-specific substitutions from long VoiceBar validation reads", () => {
    expect(
      cleanupTranscriptionText(
        "and then still accept VoiceLayer to keep the beginning",
      ),
    ).toBe("And then still expect VoiceLayer to keep the beginning");
    expect(
      cleanupTranscriptionText("keeps the real tale of the sentence"),
    ).toBe("Keeps the real tail of the sentence");
    expect(cleanupTranscriptionText("real tale of the sentence")).toBe(
      "Real tail of the sentence",
    );
  });

  it("collapses immediate duplicated STT function words from dictation", () => {
    expect(cleanupTranscriptionText("see the the bars")).toBe("See the bars");
    expect(cleanupTranscriptionText("I I think this should paste")).toBe(
      "I think this should paste",
    );
    expect(cleanupTranscriptionText("send to to the current input")).toBe(
      "Send to the current input",
    );
  });

  it("preserves valid repeated words, Hebrew, and identifiers", () => {
    expect(cleanupTranscriptionText("what it is is still valid")).toBe(
      "What it is is still valid",
    );
    expect(cleanupTranscriptionText("the fact that that worked matters")).toBe(
      "The fact that that worked matters",
    );
    expect(cleanupTranscriptionText("he had had enough context")).toBe(
      "He had had enough context",
    );
    expect(cleanupTranscriptionText("אני אני רוצה שזה יישאר")).toBe(
      "אני אני רוצה שזה יישאר",
    );
    expect(cleanupTranscriptionText("useEffect useEffect stays visible")).toBe(
      "useEffect useEffect stays visible",
    );
  });

  it("cleans punctuation artifacts from archived VoiceBar prose", () => {
    expect(
      cleanupTranscriptionText(
        'the last slide about the syllabus shouldn\'t be"What were we through today?"or it should be"What would we talk about today?"We\'re still missing the next visual',
      ),
    ).toBe(
      'The last slide about the syllabus shouldn\'t be "What were we through today?" or it should be "What would we talk about today?" We\'re still missing the next visual',
    );
    expect(
      cleanupTranscriptionText(
        "yeah, the language should be fixed a little bit. um, yeah.",
      ),
    ).toBe("Yeah, the language should be fixed a little bit, yeah.");
  });

  it("cleans latest STT eval phrase artifacts for PR possessives and presentation terms", () => {
    expect(
      cleanupTranscriptionText(
        "Should I mention PR222's cleanup fix, vision pro spacing, and the second - s possessive issue?",
      ),
    ).toBe(
      "Should I mention PR 222's cleanup fix, Vision Pro spacing, and the second-S possessive issue?",
    );
    expect(
      cleanupTranscriptionText(
        "Should I mention PR222's cleanup fix, vision pro spacing, and the second dash s possessive issue?",
      ),
    ).toBe(
      "Should I mention PR 222's cleanup fix, Vision Pro spacing, and the second-S possessive issue?",
    );
  });

  it("ignores unsafe broad aliases from the VoiceBar vocabulary snapshot", async () => {
    const snapshotPath =
      "/tmp/voicelayer-stt-vocabulary-unsafe-alias-test.json";
    await Bun.write(
      snapshotPath,
      JSON.stringify({
        entries: [{ canonical: "Codex", variants: ["codecs"] }],
      }),
    );

    expect(
      cleanupTranscriptionText("audio codecs need testing", {
        QA_VOICE_STT_VOCABULARY_PATH: snapshotPath,
      }),
    ).toBe("Audio codecs need testing");
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

  it("differentiates the Qelos repo from the kilos measurement unit by context", () => {
    // Repo/code context → Qelos (the repo). "kilos" alone stays a measurement,
    // but "kilos <repo-noun>" is unambiguously the repo.
    expect(cleanupTranscriptionText("check the kilos repo")).toBe(
      "Check the Qelos repo",
    );
    expect(cleanupTranscriptionText("the kilos adapter needs work")).toBe(
      "The Qelos adapter needs work",
    );
    expect(cleanupTranscriptionText("open the kilos dashboard")).toBe(
      "Open the Qelos dashboard",
    );
    expect(cleanupTranscriptionText("rebase the kilos branch")).toBe(
      "Rebase the Qelos branch",
    );
    // Bare phonetic mishears (non-words) → Qelos.
    expect(cleanupTranscriptionText("deploy kelos now")).toBe(
      "Deploy Qelos now",
    );
    // Measurement context is preserved (NOT rewritten to Qelos).
    expect(cleanupTranscriptionText("ship 10 kilos of flour")).toBe(
      "Ship 10 kilos of flour",
    );
    expect(cleanupTranscriptionText("it weighs five kilos")).toBe(
      "It weighs 5 kilos",
    );
  });

  it("keeps conversational one as a word while preserving numeric agent counts", () => {
    expect(
      cleanupTranscriptionText(
        "1 more thing. The other 1. I want 1 orcClaude and I want 1 BrainLayer clawed.",
      ),
    ).toBe(
      "One more thing. The other one. I want 1 orcClaude and I want 1 brainlayerClaude.",
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

  it("preserves spoken discourse phrases that may carry user intent", () => {
    expect(cleanupTranscriptionText("you know this should stay")).toBe(
      "You know this should stay",
    );
    expect(cleanupTranscriptionText("I mean this should stay too")).toBe(
      "I mean this should stay too",
    );
  });

  it("does not leave punctuation clusters after filler removal", () => {
    expect(
      cleanupTranscriptionText(
        "let's see if we get any of those artifacts here, basically.",
      ),
    ).toBe("Let's see if we get any of those artifacts here.");

    expect(cleanupTranscriptionText("then it does,..")).toBe("Then it does.");
  });
});
