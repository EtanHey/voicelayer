import { describe, expect, it } from "bun:test";
import {
  buildInstructionExample,
  normalizeWisprTarget,
  oversampleTrainingExamples,
  parseWisprPipeExport,
  scrubTrainingText,
  splitWisprExamples,
} from "../wispr-lora-dataset";

describe("wispr-lora-dataset", () => {
  it("normalizes Wispr ordered-list HTML into markdown numbered lists", () => {
    const target = normalizeWisprTarget(
      "<ol>\n<li>I want to do X, Y, and Z.</li>\n<li>I want the other thing.</li>\n</ol>",
    );

    expect(target).toBe("1. I want to do X, Y, and Z.\n2. I want the other thing.");
  });

  it("scrubs direct PII while preserving dev vocabulary and meaning", () => {
    const scrubbed = scrubTrainingText(
      "Email etan@example.com and call +1 (415) 555-1212 from BrainLayer.",
    );

    expect(scrubbed).toBe("Email [EMAIL] and call [PHONE] from BrainLayer.");
  });

  it("parses pipe-delimited Wispr exports with multiline formatted fields", () => {
    const rows = parseWisprPipeExport(
      [
        "id-1|raw one|formatted one||com.app||2|1.2|2026-06-01",
        "id-2|raw two|<ol>",
        "<li>First item.</li>",
        "<li>Second item.</li>",
        "</ol>|edited two|com.app||4|2.3|2026-06-02",
      ].join("\n"),
    );

    expect(rows).toHaveLength(2);
    expect(rows[1]).toMatchObject({
      id: "id-2",
      asrText: "raw two",
      formattedText: "<ol>\n<li>First item.</li>\n<li>Second item.</li>\n</ol>",
      editedText: "edited two",
    });
  });

  it("builds MLX chat examples with the polish system task and cleaned target", () => {
    const example = buildInstructionExample({
      id: "sample",
      asrText:
        "Okay first of all I want X and then second of all I want Y",
      formattedText: "<ol><li>I want X.</li><li>I want Y.</li></ol>",
      editedText: null,
      timestamp: "2026-06-02",
      source: "wispr-db",
    });

    expect(example?.messages.map((message) => message.role)).toEqual([
      "system",
      "user",
      "assistant",
    ]);
    expect(example?.messages[1].content).toBe(
      "Okay first of all I want X and then second of all I want Y",
    );
    expect(example?.messages[2].content).toBe("1. I want X.\n2. I want Y.");
    expect(example?.metadata.tags).toContain("spoken-list");
  });

  it("does not tag ordinary ordinal adjectives as spoken lists", () => {
    const example = buildInstructionExample({
      id: "second-account",
      asrText: "i bought a second account because the first one hit rate limits",
      formattedText:
        "I bought a second account because the first one hit rate limits.",
      editedText: null,
      timestamp: "2026-06-02",
      source: "wispr-db",
    });

    expect(example?.metadata.tags).not.toContain("spoken-list");
  });

  it("rejects targets that look like assistant answers or error dumps", () => {
    expect(
      buildInstructionExample({
        id: "answer-dump",
        asrText: "Can you try to help me and figure out what happened here exactly?",
        formattedText:
          "Configuration Error\nThe configuration file contains invalid JSON. JSON Parse error: unexpected token.",
        editedText: null,
        timestamp: "2026-06-02",
        source: "wispr-db",
      }),
    ).toBeNull();

    expect(
      buildInstructionExample({
        id: "assistant-reply",
        asrText: "Sure.",
        formattedText: "Reply...",
        editedText: null,
        timestamp: "2026-06-02",
        source: "wispr-db",
      }),
    ).toBeNull();
  });

  it("rejects numbered-list targets without spoken-list evidence in the raw text", () => {
    const example = buildInstructionExample({
      id: "invented-list",
      asrText: "Give me a list of what Efi asked us for.",
      formattedText:
        "1. All builds\n2. Build logs for the last 30 days\n3. Environment-specific configuration",
      editedText: null,
      timestamp: "2026-06-02",
      source: "wispr-db",
    });

    expect(example).toBeNull();
  });

  it("rejects one-item numbered targets", () => {
    const example = buildInstructionExample({
      id: "single-item-list",
      asrText:
        "First of all, click into the input, and then do one more voice bar test.",
      formattedText:
        "1. First of all, click into the input, and then do one more VoiceBar test.",
      editedText: null,
      timestamp: "2026-06-02",
      source: "wispr-db",
    });

    expect(example).toBeNull();
  });

  it("deduplicates and forces hard cases into the held-out test split", () => {
    const hard = buildInstructionExample({
      id: "hard-list",
      asrText: "First of all, I want x, and second of all, I want y.",
      formattedText: "1. I want x.\n2. I want y.",
      editedText: null,
      timestamp: "2026-06-24",
      source: "hard-case",
    });
    const duplicate = buildInstructionExample({
      id: "duplicate",
      asrText: "First of all, I want x, and second of all, I want y.",
      formattedText: "1. I want x.\n2. I want y.",
      editedText: null,
      timestamp: "2026-06-24",
      source: "wispr-db",
    });
    const ordinary = buildInstructionExample({
      id: "ordinary",
      asrText: "why did it do that i am confused",
      formattedText: "Why did it do that? I am confused.",
      editedText: null,
      timestamp: "2026-06-23",
      source: "wispr-db",
    });

    const split = splitWisprExamples([hard, duplicate, ordinary].filter(Boolean), {
      hardCaseIds: new Set(["hard-list"]),
      validRatio: 0.25,
      testRatio: 0.25,
    });

    expect(split.test.map((example) => example.id)).toContain("hard-list");
    expect(split.train.concat(split.valid, split.test)).toHaveLength(2);
    expect(split.train.some((example) => example.id === "hard-list")).toBe(false);
  });

  it("oversamples request-like dictation without duplicating true numbered-list targets", () => {
    const preservedRequest = buildInstructionExample({
      id: "preserved-request",
      asrText: "Give me a list of what Efi asked us for.",
      formattedText: "Give me a list of what Efi asked us for.",
      editedText: "Give me a list of what Efi asked us for, please.",
      timestamp: "2026-06-02",
      source: "wispr-db",
    });
    const trueList = buildInstructionExample({
      id: "true-list",
      asrText: "First of all I want X and second of all I want Y.",
      formattedText: "1. I want X.\n2. I want Y.",
      editedText: null,
      timestamp: "2026-06-02",
      source: "wispr-db",
    });

    const augmented = oversampleTrainingExamples(
      [preservedRequest, trueList].filter(Boolean),
    );

    expect(
      augmented.filter((example) => example.id.startsWith("preserved-request")),
    ).toHaveLength(11);
    expect(
      augmented.filter((example) => example.id.startsWith("true-list")),
    ).toHaveLength(1);
    expect(
      augmented
        .filter((example) => example.id.startsWith("preserved-request::"))
        .every((example) => example.metadata.tags.includes("anti-instruction")),
    ).toBe(true);
  });
});
