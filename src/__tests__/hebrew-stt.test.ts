/**
 * Tests for Hebrew STT integration — language detection, initial prompts,
 * and Hebrew post-processing rules.
 */
import { describe, it, expect, beforeEach } from "bun:test";
import { applyRules, type RulesConfig } from "../rules-engine";
import {
  getLanguageConfig,
  getInitialPrompt,
  type LanguageMode,
} from "../language-config";

// --- Language Configuration ---

describe("language-config", () => {
  describe("getLanguageConfig", () => {
    it("returns 'auto' for auto mode", () => {
      const config = getLanguageConfig("auto");
      expect(config.whisperLang).toBe("auto");
      expect(config.mode).toBe("auto");
    });

    it("returns 'he' for hebrew mode", () => {
      const config = getLanguageConfig("hebrew");
      expect(config.whisperLang).toBe("he");
      expect(config.mode).toBe("hebrew");
    });

    it("returns 'en' for english mode", () => {
      const config = getLanguageConfig("english");
      expect(config.whisperLang).toBe("en");
      expect(config.mode).toBe("english");
    });

    it("defaults to auto when mode is unrecognized", () => {
      const config = getLanguageConfig("gibberish" as LanguageMode);
      expect(config.whisperLang).toBe("auto");
    });
  });

  describe("getInitialPrompt", () => {
    it("returns a prompt for auto mode with both languages", () => {
      const prompt = getInitialPrompt("auto");
      // Should contain English dev terms
      expect(prompt).toContain("TypeScript");
      // Should contain Hebrew text
      expect(prompt).toMatch(/[\u0590-\u05FF]/); // Hebrew chars
    });

    it("returns Hebrew-heavy prompt for hebrew mode", () => {
      const prompt = getInitialPrompt("hebrew");
      expect(prompt).toMatch(/[\u0590-\u05FF]/);
    });

    it("returns English-only prompt for english mode", () => {
      const prompt = getInitialPrompt("english");
      expect(prompt).toContain("TypeScript");
      // Should NOT contain Hebrew
      expect(prompt).not.toMatch(/[\u0590-\u05FF]/);
    });

    it("prompt is under 224 tokens (~900 chars)", () => {
      // whisper --initial-prompt is limited to 224 tokens
      for (const mode of ["auto", "hebrew", "english"] as LanguageMode[]) {
        const prompt = getInitialPrompt(mode);
        expect(prompt.length).toBeLessThan(900);
      }
    });
  });
});

// --- Hebrew Post-Processing Rules ---

describe("Hebrew rules in rules-engine", () => {
  describe("Hebrew filler removal", () => {
    it("removes Hebrew fillers (אמ, אה, כאילו, בעצם)", () => {
      expect(applyRules("אמ אני חושב אה שזה בעצם עובד")).toBe(
        "אני חושב שזה עובד",
      );
    });

    it("removes כאילו as filler", () => {
      expect(applyRules("זה כאילו ממש מהיר")).toBe("זה ממש מהיר");
    });
  });

  describe("Hebrew dev vocabulary", () => {
    it("corrects Hebrew dev terms with English code words", () => {
      const config: RulesConfig = {
        aliases: {
          "פול ריקווסט": "Pull Request",
          פוש: "push",
        },
      };
      expect(applyRules("תעשה פוש לברנץ'", config)).toContain("push");
    });
  });

  describe("mixed Hebrew-English", () => {
    it("preserves English code terms in Hebrew text", () => {
      // TypeScript should stay as-is in Hebrew context
      const result = applyRules("אני כותב ב type script");
      expect(result).toContain("TypeScript");
    });

    it("handles Hebrew with useEffect reference", () => {
      const result = applyRules("תשתמש ב use effect");
      expect(result).toContain("useEffect");
    });
  });
});

// --- WhisperCppBackend Language Args ---

describe("whisper language args", () => {
  it("auto mode omits -l flag for auto-detection", () => {
    const config = getLanguageConfig("auto");
    expect(config.whisperArgs).not.toContain("-l");
  });

  it("hebrew mode passes -l he", () => {
    const config = getLanguageConfig("hebrew");
    expect(config.whisperArgs).toContain("-l");
    expect(config.whisperArgs).toContain("he");
  });

  it("english mode passes -l en", () => {
    const config = getLanguageConfig("english");
    expect(config.whisperArgs).toContain("-l");
    expect(config.whisperArgs).toContain("en");
  });

  it("all modes include --initial-prompt", () => {
    for (const mode of ["auto", "hebrew", "english"] as LanguageMode[]) {
      const config = getLanguageConfig(mode);
      expect(config.whisperArgs).toContain("--initial-prompt");
    }
  });
});
